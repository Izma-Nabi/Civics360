-- Phase 2 | Step 7: data quality validation (Completeness / Accuracy / Integrity)
DROP TABLE IF EXISTS project_reporting.dq_results;
CREATE TABLE project_reporting.dq_results (
    check_id SERIAL PRIMARY KEY, category TEXT, check_name TEXT,
    expected NUMERIC, actual NUMERIC, rule TEXT, status TEXT, checked_at TIMESTAMP DEFAULT now()
);

CREATE OR REPLACE FUNCTION project_reporting.add_check(cat text, nm text, exp numeric, act numeric, rl text)
RETURNS void AS $$
    INSERT INTO project_reporting.dq_results (category, check_name, expected, actual, rule, status)
    VALUES (cat, nm, exp, act, rl,
            CASE WHEN rl = 'eq'  AND act = exp THEN 'PASS'
                 WHEN rl = 'lte' AND act <= exp THEN 'PASS'
                 ELSE 'FAIL' END);
$$ LANGUAGE sql;

-- COMPLETENESS (rule 'eq' expects 0; 'lte' = allowed maximum percentage)
SELECT project_reporting.add_check('Completeness','Fact rows with NULL created_date_key',0,(SELECT count(*) FROM project_dw.fact_service_request WHERE created_date_key IS NULL),'eq');
SELECT project_reporting.add_check('Completeness','Fact rows with NULL dimension key',0,(SELECT count(*) FROM project_dw.fact_service_request WHERE agency_key IS NULL OR complaint_type_key IS NULL OR location_key IS NULL OR status_key IS NULL OR channel_key IS NULL),'eq');
SELECT project_reporting.add_check('Completeness','Staging rows with NULL unique_key',0,(SELECT count(*) FROM project_staging.stg_service_request WHERE unique_key IS NULL),'eq');
SELECT project_reporting.add_check('Completeness','% fact rows with Unknown complaint type (max 1%)',1,(SELECT round(100.0*count(*) FILTER (WHERE c.complaint_type='Unknown')/greatest(count(*),1),2) FROM project_dw.fact_service_request f JOIN project_dw.dim_complaint_type c USING (complaint_type_key)),'lte');
SELECT project_reporting.add_check('Completeness','% fact rows with Unknown borough (max 10%)',10,(SELECT round(100.0*count(*) FILTER (WHERE l.borough='Unknown')/greatest(count(*),1),2) FROM project_dw.fact_service_request f JOIN project_dw.dim_location l USING (location_key)),'lte');
SELECT project_reporting.add_check('Completeness','% fact rows with missing coordinates (max 20%)',20,(SELECT round(100.0*count(*) FILTER (WHERE latitude IS NULL)/greatest(count(*),1),2) FROM project_dw.fact_service_request),'lte');

-- ACCURACY (reconciliation staging vs warehouse; resolution_hours plays the role of "revenue")
SELECT project_reporting.add_check('Accuracy','Row count: staging vs fact (difference)',0,(SELECT (SELECT count(*) FROM project_staging.stg_service_request)-(SELECT count(*) FROM project_dw.fact_service_request)),'eq');
SELECT project_reporting.add_check('Accuracy','Total resolution_hours: staging vs fact (difference)',0,(SELECT coalesce((SELECT sum(resolution_hours) FROM project_staging.stg_service_request),0)-coalesce((SELECT sum(resolution_hours) FROM project_dw.fact_service_request),0)),'eq');
SELECT project_reporting.add_check('Accuracy','Per-borough row counts: staging vs DW (mismatching boroughs)',0,
  (SELECT count(*) FROM (SELECT borough, count(*) n FROM project_staging.stg_service_request GROUP BY 1) s
   FULL JOIN (SELECT l.borough, count(*) n FROM project_dw.fact_service_request f JOIN project_dw.dim_location l USING (location_key) GROUP BY 1) w USING (borough)
   WHERE s.n IS DISTINCT FROM w.n),'eq');
SELECT project_reporting.add_check('Accuracy','Closed date earlier than created date',0,(SELECT count(*) FROM project_staging.stg_service_request WHERE closed_ts < created_ts),'eq');
SELECT project_reporting.add_check('Accuracy','Negative resolution_hours in fact',0,(SELECT count(*) FROM project_dw.fact_service_request WHERE resolution_hours < 0),'eq');

-- INTEGRITY (fact rows without matching dimension = 0)
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_date (created)',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_date d ON d.date_key=f.created_date_key WHERE d.date_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_date (closed)',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_date d ON d.date_key=f.closed_date_key WHERE f.closed_date_key IS NOT NULL AND d.date_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_agency',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_agency d USING (agency_key) WHERE d.agency_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_complaint_type',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_complaint_type d USING (complaint_type_key) WHERE d.complaint_type_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_location',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_location d USING (location_key) WHERE d.location_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_status',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_status d USING (status_key) WHERE d.status_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Fact rows without matching dim_channel',0,(SELECT count(*) FROM project_dw.fact_service_request f LEFT JOIN project_dw.dim_channel d USING (channel_key) WHERE d.channel_key IS NULL),'eq');
SELECT project_reporting.add_check('Integrity','Duplicate unique_key in fact',0,(SELECT count(*) FROM (SELECT unique_key FROM project_dw.fact_service_request GROUP BY 1 HAVING count(*)>1) x),'eq');
SELECT project_reporting.add_check('Integrity','Duplicate business keys in dim_agency',0,(SELECT count(*) FROM (SELECT agency_code FROM project_dw.dim_agency GROUP BY 1 HAVING count(*)>1) x),'eq');
SELECT project_reporting.add_check('Integrity','Duplicate business keys in dim_location',0,(SELECT count(*) FROM (SELECT zip,borough,city FROM project_dw.dim_location GROUP BY 1,2,3 HAVING count(*)>1) x),'eq');
SELECT project_reporting.add_check('Integrity','Duplicate business keys in dim_complaint_type',0,(SELECT count(*) FROM (SELECT complaint_type,descriptor FROM project_dw.dim_complaint_type GROUP BY 1,2 HAVING count(*)>1) x),'eq');
SELECT project_reporting.add_check('Integrity','Fact table has at least 10,000 rows (0 = ok)',0,(SELECT CASE WHEN count(*)>=10000 THEN 0 ELSE 1 END FROM project_dw.fact_service_request),'eq');
SELECT project_reporting.add_check('Integrity','dim_complaint_type has at least 100 rows (0 = ok)',0,(SELECT CASE WHEN count(*)>=100 THEN 0 ELSE 1 END FROM project_dw.dim_complaint_type),'eq');
