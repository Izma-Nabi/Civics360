-- Phase 2 | Step 3: star schema in project_dw
-- Surrogate keys are IDENTITY columns starting at 1001 (e.g. agency_code 'NYPD' -> agency_key 1001)
DROP TABLE IF EXISTS project_dw.fact_service_request CASCADE;
DROP TABLE IF EXISTS project_dw.dim_date, project_dw.dim_agency, project_dw.dim_complaint_type,
                     project_dw.dim_location, project_dw.dim_status, project_dw.dim_channel CASCADE;

CREATE TABLE project_dw.dim_date (
    date_key    INT PRIMARY KEY,               -- YYYYMMDD smart key
    full_date   DATE NOT NULL UNIQUE,
    day_of_month INT, month_num INT, month_name TEXT, quarter INT, year INT,
    day_of_week INT, day_name TEXT, is_weekend BOOLEAN
);

CREATE TABLE project_dw.dim_agency (
    agency_key  INT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    agency_code TEXT NOT NULL UNIQUE,          -- business key
    agency_name TEXT NOT NULL
);

CREATE TABLE project_dw.dim_complaint_type (
    complaint_type_key INT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    complaint_type TEXT NOT NULL,              -- business key (part 1)
    descriptor     TEXT NOT NULL,              -- business key (part 2)
    UNIQUE (complaint_type, descriptor)
);

CREATE TABLE project_dw.dim_location (
    location_key INT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    zip     TEXT NOT NULL,                     -- business key (zip, borough, city)
    borough TEXT NOT NULL,
    city    TEXT NOT NULL,
    lot_count INT, total_res_units INT, avg_year_built INT,   -- from PLUTO
    UNIQUE (zip, borough, city)
);

CREATE TABLE project_dw.dim_status (
    status_key INT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    status TEXT NOT NULL UNIQUE
);

CREATE TABLE project_dw.dim_channel (
    channel_key INT GENERATED ALWAYS AS IDENTITY (START WITH 1001) PRIMARY KEY,
    channel TEXT NOT NULL UNIQUE
);

CREATE TABLE project_dw.fact_service_request (
    request_key        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unique_key         BIGINT NOT NULL UNIQUE,              -- degenerate dimension (311 id)
    created_date_key   INT NOT NULL REFERENCES project_dw.dim_date(date_key),
    closed_date_key    INT REFERENCES project_dw.dim_date(date_key),
    agency_key         INT NOT NULL REFERENCES project_dw.dim_agency(agency_key),
    complaint_type_key INT NOT NULL REFERENCES project_dw.dim_complaint_type(complaint_type_key),
    location_key       INT NOT NULL REFERENCES project_dw.dim_location(location_key),
    status_key         INT NOT NULL REFERENCES project_dw.dim_status(status_key),
    channel_key        INT NOT NULL REFERENCES project_dw.dim_channel(channel_key),
    latitude  NUMERIC(9,6),
    longitude NUMERIC(9,6),
    resolution_hours NUMERIC(12,2),                         -- measure
    is_closed  BOOLEAN NOT NULL,
    request_count INT NOT NULL DEFAULT 1                    -- additive measure
);
CREATE INDEX ON project_dw.fact_service_request (created_date_key);
CREATE INDEX ON project_dw.fact_service_request (agency_key);
CREATE INDEX ON project_dw.fact_service_request (complaint_type_key);
CREATE INDEX ON project_dw.fact_service_request (location_key);
