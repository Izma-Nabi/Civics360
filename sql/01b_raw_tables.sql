-- Phase 2 | Step 1b: copy the raw CSV tables (loaded earlier by load.py into the public schema)
-- into project_staging, so the whole pipeline runs from SQL only.
--   public.nyc_311_requests -> project_staging.raw_nyc311
--   public.hpd_311          -> project_staging.raw_hpd_311
--   public.pluto            -> project_staging.raw_pluto
-- All columns stay TEXT. Cleaning happens in 02_staging.sql.

DROP TABLE IF EXISTS project_staging.raw_nyc311;
CREATE TABLE project_staging.raw_nyc311 AS SELECT * FROM public.nyc_311_requests;
-- this 311 export has no channel column; add it empty so the staging SQL still works
ALTER TABLE project_staging.raw_nyc311 ADD COLUMN IF NOT EXISTS open_data_channel_type TEXT;

DROP TABLE IF EXISTS project_staging.raw_hpd_311;
CREATE TABLE project_staging.raw_hpd_311 AS SELECT * FROM public.hpd_311;

DROP TABLE IF EXISTS project_staging.raw_pluto;
CREATE TABLE project_staging.raw_pluto AS SELECT * FROM public.pluto;

SELECT 'raw_nyc311'  AS table_name, count(*) AS row_count FROM project_staging.raw_nyc311
UNION ALL SELECT 'raw_hpd_311', count(*) FROM project_staging.raw_hpd_311
UNION ALL SELECT 'raw_pluto',   count(*) FROM project_staging.raw_pluto;
