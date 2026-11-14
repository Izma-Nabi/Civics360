-- 08_verify_all.sql : verification of every step (01 - 07)
-- Every row = one check. status must be PASS.

-- ============ 1. ARCHITECTURE (step 01) ============
SELECT '1. Schemas created' AS section,
       (SELECT string_agg(schema_name, ', ' ORDER BY schema_name) FROM information_schema.schemata
        WHERE schema_name IN ('project_staging','project_dw','project_reporting')) AS result,
       CASE WHEN (SELECT count(*) FROM information_schema.schemata
                  WHERE schema_name IN ('project_staging','project_dw','project_reporting')) = 3
            THEN 'PASS' ELSE 'FAIL' END AS status;

-- ============ 2. ROW COUNTS PER LAYER (steps 01b - 05) ============
SELECT layer, table_name, row_count, min_required,
       CASE WHEN row_count >= min_required THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 1 AS o, 'raw'     AS layer, 'raw_nyc311'         AS table_name, count(*) AS row_count, 1     AS min_required FROM project_staging.raw_nyc311
    UNION ALL SELECT 2, 'raw',     'raw_hpd_311',          count(*), 1     FROM project_staging.raw_hpd_311
    UNION ALL SELECT 3, 'raw',     'raw_pluto',            count(*), 1     FROM project_staging.raw_pluto
    UNION ALL SELECT 4, 'staging', 'stg_service_request',  count(*), 10000 FROM project_staging.stg_service_request
    UNION ALL SELECT 5, 'staging', 'stg_pluto_zip',        count(*), 1     FROM project_staging.stg_pluto_zip
    UNION ALL SELECT 6, 'dw',      'dim_date',             count(*), 100   FROM project_dw.dim_date
    UNION ALL SELECT 7, 'dw',      'dim_agency',           count(*), 1     FROM project_dw.dim_agency
    UNION ALL SELECT 8, 'dw',      'dim_complaint_type',   count(*), 100   FROM project_dw.dim_complaint_type
    UNION ALL SELECT 9, 'dw',      'dim_location',         count(*), 100   FROM project_dw.dim_location
    UNION ALL SELECT 10,'dw',      'dim_status',           count(*), 1     FROM project_dw.dim_status
    UNION ALL SELECT 11,'dw',      'dim_channel',          count(*), 1     FROM project_dw.dim_channel
    UNION ALL SELECT 12,'dw',      'fact_service_request', count(*), 10000 FROM project_dw.fact_service_request
) t ORDER BY o;

-- ============ 3. STAGING CLEANING (step 02) ============
SELECT check_name, bad_rows, CASE WHEN bad_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 1 AS o, 'Duplicate unique_key in staging' AS check_name,
           (SELECT count(*) FROM (SELECT unique_key FROM project_staging.stg_service_request GROUP BY 1 HAVING count(*) > 1) x) AS bad_rows
    UNION ALL SELECT 2, 'NULL unique_key or created_ts',
           (SELECT count(*) FROM project_staging.stg_service_request WHERE unique_key IS NULL OR created_ts IS NULL)
    UNION ALL SELECT 3, 'NULLs left in key text columns (should be "Unknown")',
           (SELECT count(*) FROM project_staging.stg_service_request
            WHERE complaint_type IS NULL OR borough IS NULL OR zip IS NULL OR city IS NULL OR status IS NULL OR agency_code IS NULL)
    UNION ALL SELECT 4, 'Text not standardized (trim / Title Case)',
           (SELECT count(*) FROM project_staging.stg_service_request
            WHERE complaint_type <> project_staging.clean_text(complaint_type)
               OR city <> project_staging.clean_text(city)
               OR borough <> project_staging.clean_text(borough))
    UNION ALL SELECT 5, 'ZIP not 5 digits or Unknown',
           (SELECT count(*) FROM project_staging.stg_service_request WHERE zip !~ '^\d{5}$' AND zip <> 'Unknown')
    UNION ALL SELECT 6, 'Coordinates outside NYC range',
           (SELECT count(*) FROM project_staging.stg_service_request
            WHERE latitude NOT BETWEEN 40.4 AND 41.0 OR longitude NOT BETWEEN -74.3 AND -73.6)
    UNION ALL SELECT 7, 'Closed date earlier than created date',
           (SELECT count(*) FROM project_staging.stg_service_request WHERE closed_ts < created_ts)
) t ORDER BY o;

-- Cleaning log written by step 02
SELECT metric, value FROM project_staging.etl_log ORDER BY log_id;

-- ============ 4. SURROGATE KEYS (steps 03 - 04) ============
SELECT dimension, min_key, max_key, members, distinct_business_keys,
       CASE WHEN min_key = 1001 AND members = distinct_business_keys THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'dim_agency' AS dimension, min(agency_key) AS min_key, max(agency_key) AS max_key, count(*) AS members, count(DISTINCT agency_code) AS distinct_business_keys FROM project_dw.dim_agency
    UNION ALL SELECT 'dim_complaint_type', min(complaint_type_key), max(complaint_type_key), count(*), count(DISTINCT (complaint_type, descriptor)) FROM project_dw.dim_complaint_type
    UNION ALL SELECT 'dim_location', min(location_key), max(location_key), count(*), count(DISTINCT (zip, borough, city)) FROM project_dw.dim_location
    UNION ALL SELECT 'dim_status', min(status_key), max(status_key), count(*), count(DISTINCT status) FROM project_dw.dim_status
    UNION ALL SELECT 'dim_channel', min(channel_key), max(channel_key), count(*), count(DISTINCT channel) FROM project_dw.dim_channel
) t;

-- Business key -> surrogate key examples (like C101 -> 1001)
SELECT agency_code AS business_key, agency_key AS surrogate_key FROM project_dw.dim_agency ORDER BY agency_key LIMIT 5;

-- Date dimension covers every date used by the fact table
SELECT 'dim_date range' AS check_name, min(full_date) AS first_date, max(full_date) AS last_date,
       (SELECT count(*) FROM project_dw.fact_service_request f
        LEFT JOIN project_dw.dim_date d ON d.date_key = f.created_date_key WHERE d.date_key IS NULL) AS fact_rows_without_date,
       CASE WHEN (SELECT count(*) FROM project_dw.fact_service_request f
                  LEFT JOIN project_dw.dim_date d ON d.date_key = f.created_date_key WHERE d.date_key IS NULL) = 0
            THEN 'PASS' ELSE 'FAIL' END AS status
FROM project_dw.dim_date;

-- ============ 5. FACT LOAD AND RECONCILIATION (step 05) ============
SELECT check_name, difference, CASE WHEN difference = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 1 AS o, 'Row count staging - fact' AS check_name,
           (SELECT count(*) FROM project_staging.stg_service_request) - (SELECT count(*) FROM project_dw.fact_service_request) AS difference
    UNION ALL SELECT 2, 'Sum resolution_hours staging - fact',
           coalesce((SELECT sum(resolution_hours) FROM project_staging.stg_service_request), 0)
         - coalesce((SELECT sum(resolution_hours) FROM project_dw.fact_service_request), 0)
    UNION ALL SELECT 3, 'Fact rows without dim_agency',
           (SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_agency d USING (agency_key) WHERE d.agency_key IS NULL)
    UNION ALL SELECT 4, 'Fact rows without dim_complaint_type',
           (SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_complaint_type d USING (complaint_type_key) WHERE d.complaint_type_key IS NULL)
    UNION ALL SELECT 5, 'Fact rows without dim_location',
           (SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_location d USING (location_key) WHERE d.location_key IS NULL)
    UNION ALL SELECT 6, 'Fact rows without dim_status',
           (SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_status d USING (status_key) WHERE d.status_key IS NULL)
    UNION ALL SELECT 7, 'Fact rows without dim_channel',
           (SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_channel d USING (channel_key) WHERE d.channel_key IS NULL)
    UNION ALL SELECT 8, 'Duplicate unique_key in fact',
           (SELECT count(*) FROM (SELECT unique_key FROM project_dw.fact_service_request GROUP BY 1 HAVING count(*) > 1) x)
) t ORDER BY o;

-- Sample of the star schema joined back together
SELECT f.request_key, f.unique_key, d.full_date, a.agency_code, c.complaint_type, l.borough, l.zip, s.status, f.resolution_hours
FROM project_dw.fact_service_request f
JOIN project_dw.dim_date d ON d.date_key = f.created_date_key
JOIN project_dw.dim_agency a ON a.agency_key = f.agency_key
JOIN project_dw.dim_complaint_type c ON c.complaint_type_key = f.complaint_type_key
JOIN project_dw.dim_location l ON l.location_key = f.location_key
JOIN project_dw.dim_status s ON s.status_key = f.status_key
ORDER BY f.request_key LIMIT 5;

-- ============ 6. REPORTING VIEWS (step 06) ============
SELECT view_name, row_count, CASE WHEN row_count > 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (
    SELECT 'vw_requests_by_borough_month' AS view_name, count(*) AS row_count FROM project_reporting.vw_requests_by_borough_month
    UNION ALL SELECT 'vw_top_complaint_types', count(*) FROM project_reporting.vw_top_complaint_types
    UNION ALL SELECT 'vw_agency_performance',  count(*) FROM project_reporting.vw_agency_performance
    UNION ALL SELECT 'vw_zip_request_density', count(*) FROM project_reporting.vw_zip_request_density
) t;

SELECT * FROM project_reporting.vw_top_complaint_types LIMIT 5;

-- ============ 7. DATA QUALITY RESULTS (step 07) ============
SELECT category, count(*) AS checks, count(*) FILTER (WHERE status = 'PASS') AS passed,
       count(*) FILTER (WHERE status = 'FAIL') AS failed
FROM project_reporting.dq_results GROUP BY category ORDER BY category;

-- failed checks only (no rows = everything passed)
SELECT category, check_name, expected, actual, status
FROM project_reporting.dq_results WHERE status = 'FAIL' ORDER BY check_id;

-- ============ OVERALL ============
SELECT CASE WHEN (SELECT count(*) FROM project_reporting.dq_results WHERE status = 'FAIL') = 0
            THEN 'ALL DATA QUALITY CHECKS PASSED' ELSE 'SOME DATA QUALITY CHECKS FAILED' END AS overall_result;