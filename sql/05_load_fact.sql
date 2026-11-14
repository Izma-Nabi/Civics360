-- Phase 2 | Step 5: fact load - business key -> surrogate key mapping
TRUNCATE project_dw.fact_service_request RESTART IDENTITY;

INSERT INTO project_dw.fact_service_request
    (unique_key, created_date_key, closed_date_key, agency_key, complaint_type_key, location_key,
     status_key, channel_key, latitude, longitude, resolution_hours, is_closed)
SELECT s.unique_key,
       to_char(s.created_ts,'YYYYMMDD')::int,
       to_char(s.closed_ts,'YYYYMMDD')::int,          -- NULL stays NULL
       a.agency_key, c.complaint_type_key, l.location_key, st.status_key, ch.channel_key,
       s.latitude, s.longitude, s.resolution_hours, s.closed_ts IS NOT NULL
FROM project_staging.stg_service_request s
JOIN project_dw.dim_agency          a  ON a.agency_code = s.agency_code
JOIN project_dw.dim_complaint_type  c  ON c.complaint_type = s.complaint_type AND c.descriptor = s.descriptor
JOIN project_dw.dim_location        l  ON l.zip = s.zip AND l.borough = s.borough AND l.city = s.city
JOIN project_dw.dim_status          st ON st.status = s.status
JOIN project_dw.dim_channel         ch ON ch.channel = s.channel;

ANALYZE project_dw.fact_service_request;
