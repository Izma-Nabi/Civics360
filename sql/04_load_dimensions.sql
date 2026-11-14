-- Phase 2 | Step 4: dimension loads (Type 1, idempotent: new members inserted, attributes updated)
INSERT INTO project_dw.dim_date
SELECT to_char(d,'YYYYMMDD')::int, d, extract(day FROM d)::int, extract(month FROM d)::int,
       trim(to_char(d,'Month')), extract(quarter FROM d)::int, extract(year FROM d)::int,
       extract(isodow FROM d)::int, trim(to_char(d,'Day')), extract(isodow FROM d) IN (6,7)
FROM (
    -- every date used by the data ...
    SELECT created_ts::date AS d FROM project_staging.stg_service_request
    UNION
    SELECT closed_ts::date FROM project_staging.stg_service_request WHERE closed_ts IS NOT NULL
    UNION
    -- ... plus the gaps between them, so the calendar is continuous
    SELECT g::date
    FROM generate_series(
            (SELECT min(created_ts)::date FROM project_staging.stg_service_request)::timestamp,
            (SELECT greatest(max(created_ts), max(closed_ts))::date FROM project_staging.stg_service_request)::timestamp,
            interval '1 day') AS g
) dates
ON CONFLICT (date_key) DO NOTHING;

INSERT INTO project_dw.dim_agency (agency_code, agency_name)
SELECT agency_code, max(agency_name) FROM project_staging.stg_service_request GROUP BY agency_code
ON CONFLICT (agency_code) DO UPDATE SET agency_name = EXCLUDED.agency_name;

INSERT INTO project_dw.dim_complaint_type (complaint_type, descriptor)
SELECT DISTINCT complaint_type, descriptor FROM project_staging.stg_service_request
ON CONFLICT (complaint_type, descriptor) DO NOTHING;

INSERT INTO project_dw.dim_location (zip, borough, city, lot_count, total_res_units, avg_year_built)
SELECT s.zip, s.borough, s.city, p.lot_count, p.total_res_units, p.avg_year_built
FROM (SELECT DISTINCT zip, borough, city FROM project_staging.stg_service_request) s
LEFT JOIN project_staging.stg_pluto_zip p ON p.zip = s.zip
ON CONFLICT (zip, borough, city) DO UPDATE
   SET lot_count = EXCLUDED.lot_count, total_res_units = EXCLUDED.total_res_units,
       avg_year_built = EXCLUDED.avg_year_built;

INSERT INTO project_dw.dim_status (status)
SELECT DISTINCT status FROM project_staging.stg_service_request ON CONFLICT (status) DO NOTHING;

INSERT INTO project_dw.dim_channel (channel)
SELECT DISTINCT channel FROM project_staging.stg_service_request ON CONFLICT (channel) DO NOTHING;

ANALYZE project_dw.dim_date; ANALYZE project_dw.dim_agency; ANALYZE project_dw.dim_complaint_type;
ANALYZE project_dw.dim_location; ANALYZE project_dw.dim_status; ANALYZE project_dw.dim_channel;
