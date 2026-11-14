-- Phase 2 | Step 6: reporting layer (views over the star schema)
CREATE OR REPLACE VIEW project_reporting.vw_requests_by_borough_month AS
SELECT d.year, d.month_num, d.month_name, l.borough, count(*) AS requests,
       round(avg(f.resolution_hours), 1) AS avg_resolution_hours
FROM project_dw.fact_service_request f
JOIN project_dw.dim_date d ON d.date_key = f.created_date_key
JOIN project_dw.dim_location l ON l.location_key = f.location_key
GROUP BY d.year, d.month_num, d.month_name, l.borough;

CREATE OR REPLACE VIEW project_reporting.vw_top_complaint_types AS
SELECT c.complaint_type, count(*) AS requests,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_total
FROM project_dw.fact_service_request f
JOIN project_dw.dim_complaint_type c ON c.complaint_type_key = f.complaint_type_key
GROUP BY c.complaint_type ORDER BY requests DESC;

CREATE OR REPLACE VIEW project_reporting.vw_agency_performance AS
SELECT a.agency_code, a.agency_name, count(*) AS requests,
       round(100.0 * count(*) FILTER (WHERE f.is_closed) / count(*), 1) AS pct_closed,
       round(avg(f.resolution_hours), 1) AS avg_resolution_hours
FROM project_dw.fact_service_request f
JOIN project_dw.dim_agency a ON a.agency_key = f.agency_key
GROUP BY a.agency_code, a.agency_name;

CREATE OR REPLACE VIEW project_reporting.vw_zip_request_density AS
SELECT l.zip, l.borough, max(l.total_res_units) AS residential_units, count(*) AS requests,
       round(1000.0 * count(*) / nullif(max(l.total_res_units), 0), 2) AS requests_per_1000_units
FROM project_dw.fact_service_request f
JOIN project_dw.dim_location l ON l.location_key = f.location_key
WHERE l.zip <> 'Unknown'
GROUP BY l.zip, l.borough;
