-- Phase 2 | Step 2: staging layer
-- Input : project_staging.raw_nyc311, raw_hpd_311, raw_pluto (all TEXT, loaded by run_etl.py)
-- Output: stg_service_request, stg_pluto_zip, etl_log

-- ---------- helper functions ----------
CREATE OR REPLACE FUNCTION project_staging.clean_text(t text) RETURNS text AS $$
    SELECT NULLIF(initcap(btrim(regexp_replace(lower(t), '\s+', ' ', 'g'))), '');
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.try_num(t text) RETURNS numeric AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+(\.\d+)?$' THEN btrim(t)::numeric END;
$$ LANGUAGE sql IMMUTABLE;

CREATE OR REPLACE FUNCTION project_staging.try_ts(t text) RETURNS timestamp AS $$
BEGIN
    IF t IS NULL OR btrim(t) = '' THEN RETURN NULL; END IF;
    BEGIN RETURN to_timestamp(t, 'MM/DD/YYYY HH12:MI:SS AM')::timestamp;
    EXCEPTION WHEN others THEN NULL; END;
    BEGIN RETURN t::timestamp;
    EXCEPTION WHEN others THEN RETURN NULL; END;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- ---------- cleaning log (feeds the Data Cleaning Report) ----------
DROP TABLE IF EXISTS project_staging.etl_log;
CREATE TABLE project_staging.etl_log (
    log_id    SERIAL PRIMARY KEY,
    metric    TEXT NOT NULL,
    value     BIGINT,
    logged_at TIMESTAMP DEFAULT now()
);

INSERT INTO project_staging.etl_log (metric, value)
SELECT 'Raw rows: NYC311data.csv', count(*) FROM project_staging.raw_nyc311
UNION ALL SELECT 'Raw rows: fhrw-4uyv.csv (HPD/311 extract)', count(*) FROM project_staging.raw_hpd_311
UNION ALL SELECT 'Raw rows: PLUTO (5 boroughs)', count(*) FROM project_staging.raw_pluto
UNION ALL SELECT 'NULL/blank complaint_type (raw 311)', count(*) FROM project_staging.raw_nyc311 WHERE btrim(coalesce(complaint_type,'')) = ''
UNION ALL SELECT 'NULL/blank borough (raw 311)', count(*) FROM project_staging.raw_nyc311 WHERE btrim(coalesce(borough,'')) = ''
UNION ALL SELECT 'NULL/blank incident_zip (raw 311)', count(*) FROM project_staging.raw_nyc311 WHERE btrim(coalesce(incident_zip,'')) = ''
UNION ALL SELECT 'NULL/blank latitude (raw 311)', count(*) FROM project_staging.raw_nyc311 WHERE btrim(coalesce(latitude,'')) = ''
UNION ALL SELECT 'NULL/blank status (raw 311)', count(*) FROM project_staging.raw_nyc311 WHERE btrim(coalesce(status,'')) = '';

-- ---------- stg_service_request ----------
DROP TABLE IF EXISTS project_staging.stg_service_request;
CREATE TABLE project_staging.stg_service_request AS
WITH unioned AS (
    SELECT 'NYC311'::text AS source_system, 1 AS pri,
           unique_key, created_date, closed_date, agency, agency_name, complaint_type, descriptor,
           location_type, incident_zip, city, status, borough, open_data_channel_type, latitude, longitude
    FROM project_staging.raw_nyc311
    UNION ALL
    SELECT 'HPD_311', 2,
           unique_key, created_date, NULL, NULL, NULL, complaint_type, NULL,
           NULL, incident_zip, city, NULL, borough, NULL, latitude, longitude
    FROM project_staging.raw_hpd_311
),
typed AS (
    SELECT source_system, pri,
           CASE WHEN btrim(unique_key) ~ '^\d+$' THEN btrim(unique_key)::bigint END AS unique_key,
           project_staging.try_ts(created_date) AS created_ts,
           project_staging.try_ts(closed_date)  AS closed_ts,
           agency, agency_name, complaint_type, descriptor, location_type, incident_zip, city,
           status, borough, open_data_channel_type, latitude, longitude
    FROM unioned
),
dedup AS (                       -- REMOVE DUPLICATES: one row per unique_key, NYC311 preferred
    SELECT *, row_number() OVER (PARTITION BY unique_key ORDER BY pri, created_ts) AS rn
    FROM typed
    WHERE unique_key IS NOT NULL AND created_ts IS NOT NULL
)
SELECT
    unique_key,
    source_system,
    created_ts,
    CASE WHEN closed_ts >= created_ts THEN closed_ts END AS closed_ts,        -- closed before created -> NULL
    coalesce(upper(btrim(agency)), 'UNKNOWN')                    AS agency_code,       -- NULL handling
    coalesce(project_staging.clean_text(agency_name), 'Unknown') AS agency_name,
    coalesce(project_staging.clean_text(complaint_type), 'Unknown') AS complaint_type, -- standardize text
    coalesce(project_staging.clean_text(descriptor), 'Unknown')  AS descriptor,
    coalesce(project_staging.clean_text(location_type), 'Unknown') AS location_type,
    coalesce(substring(btrim(incident_zip) from '^\d{5}'), 'Unknown') AS zip,
    coalesce(project_staging.clean_text(city), 'Unknown')        AS city,
    coalesce(project_staging.clean_text(status), 'Unknown')      AS status,
    CASE WHEN upper(btrim(coalesce(borough,''))) IN ('', 'UNSPECIFIED') THEN 'Unknown'
         ELSE project_staging.clean_text(borough) END            AS borough,
    coalesce(upper(btrim(open_data_channel_type)), 'UNKNOWN')    AS channel,
    CASE WHEN project_staging.try_num(latitude)  BETWEEN 40.4  AND 41.0  THEN project_staging.try_num(latitude)::numeric(9,6) END  AS latitude,   -- convert types + validate range
    CASE WHEN project_staging.try_num(longitude) BETWEEN -74.3 AND -73.6 THEN project_staging.try_num(longitude)::numeric(9,6) END AS longitude,
    CASE WHEN closed_ts >= created_ts
         THEN round((extract(epoch FROM closed_ts - created_ts) / 3600.0)::numeric, 2) END AS resolution_hours
FROM dedup
WHERE rn = 1;

CREATE UNIQUE INDEX ON project_staging.stg_service_request (unique_key);

-- ---------- stg_pluto_zip : property context aggregated per ZIP ----------
DROP TABLE IF EXISTS project_staging.stg_pluto_zip;
CREATE TABLE project_staging.stg_pluto_zip AS
SELECT substring(btrim(zipcode) from '^\d{5}') AS zip,
       count(*)::int AS lot_count,
       sum(coalesce(project_staging.try_num(unitsres), 0))::int AS total_res_units,
       round(avg(project_staging.try_num(yearbuilt)) FILTER (WHERE project_staging.try_num(yearbuilt) > 1800))::int AS avg_year_built
FROM project_staging.raw_pluto
WHERE btrim(zipcode) ~ '^\d{5}'
GROUP BY 1;

-- ---------- log results ----------
INSERT INTO project_staging.etl_log (metric, value)
SELECT 'Rows after cleaning: stg_service_request', count(*) FROM project_staging.stg_service_request
UNION ALL SELECT 'Duplicate / invalid rows removed',
       (SELECT count(*) FROM project_staging.raw_nyc311) + (SELECT count(*) FROM project_staging.raw_hpd_311)
       - (SELECT count(*) FROM project_staging.stg_service_request)
UNION ALL SELECT 'Rows from HPD extract kept (not in NYC311)', count(*) FROM project_staging.stg_service_request WHERE source_system = 'HPD_311'
UNION ALL SELECT 'Unknown complaint_type after cleaning', count(*) FROM project_staging.stg_service_request WHERE complaint_type = 'Unknown'
UNION ALL SELECT 'Unknown borough after cleaning', count(*) FROM project_staging.stg_service_request WHERE borough = 'Unknown'
UNION ALL SELECT 'Unknown ZIP after cleaning', count(*) FROM project_staging.stg_service_request WHERE zip = 'Unknown'
UNION ALL SELECT 'Missing/invalid coordinates after cleaning', count(*) FROM project_staging.stg_service_request WHERE latitude IS NULL
UNION ALL SELECT 'Requests still open (no valid closed date)', count(*) FROM project_staging.stg_service_request WHERE closed_ts IS NULL
UNION ALL SELECT 'Rows in stg_pluto_zip', count(*) FROM project_staging.stg_pluto_zip;
