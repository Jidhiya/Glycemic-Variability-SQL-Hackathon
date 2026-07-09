-- ------------------------------------------------------------
-- STEP 1: Create a clean schema to separate raw vs clean data
-- ------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS clean;

-- ------------------------------------------------------------
-- STEP 2: Clean demography table
-- ------------------------------------------------------------
DROP TABLE IF EXISTS clean.demography;

CREATE TABLE clean.demography AS
SELECT
    patientid::INTEGER                          AS patient_id,
    INITCAP(gender)                             AS gender,
    hba1c::NUMERIC(4,1)                         AS hba1c
FROM demography
WHERE patientid IS NOT NULL
  AND hba1c IS NOT NULL
  AND gender IS NOT NULL;

-- Verify
SELECT COUNT(*) FROM clean.demography;

select * from clean.demography


-- ------------------------------------------------------------
-- STEP 3: Clean dexcom (CGM readings) table
-- ------------------------------------------------------------
-- Final clean.dexcom definition (no insulin, no carbs if both = 0)

DROP TABLE IF EXISTS clean.dexcom;

CREATE TABLE clean.dexcom AS
SELECT
    patientid::INTEGER AS patient_id,
    DATE_TRUNC('minute', TO_TIMESTAMP(timeof, 'MM/DD/YYYY HH24:MI:SS')) AS recorded_at,
    ROUND(AVG(glucosevaluemgdl::NUMERIC), 2) AS glucose_mg_dl
FROM dexcom
WHERE eventtype = 'EGV'
  AND glucosevaluemgdl IS NOT NULL
  AND glucosevaluemgdl != ''
  AND glucosevaluemgdl::NUMERIC BETWEEN 20 AND 600
  AND timeof IS NOT NULL
  AND timeof != ''
GROUP BY
    patientid,
    DATE_TRUNC('minute', TO_TIMESTAMP(timeof, 'MM/DD/YYYY HH24:MI:SS'));


-- Verify
SELECT COUNT(*) FROM clean.dexcom;

select * from clean.dexcom


-- ------------------------------------------------------------
-- STEP 4: Clean heart rate (rebuild with all 3 formats)
-- ------------------------------------------------------------
-- Reusable timestamp parser (handles all 3 formats found in dataset)
-- Format 1: 2020-02-21 11:27:31  (YYYY-MM-DD HH24:MI:SS)
-- Format 2: 2/13/20 15:29        (M/DD/YY HH24:MI)
-- Format 3: 2/14/20 0:00         (M/DD/YY H:MI - single digit hour)
-- Downsampling via averaging (this doesn't reduce unique timestamps, but it does collapse multiple raw rows into one)
-- DATE_TRUNC('second', ...) + AVG() step merged multiple raw rows sharing the same patient + second into a single averaged row. 

DROP TABLE IF EXISTS clean.hr;

CREATE TABLE clean.hr AS
SELECT
    patientid::INTEGER AS patient_id,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END AS recorded_at,
    ROUND(AVG(hr::NUMERIC), 2) AS heart_rate
FROM hr
WHERE hr IS NOT NULL AND hr != ''
  AND hr::NUMERIC BETWEEN 30 AND 220
GROUP BY patientid,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END;

-- Check how many rows got NULL recorded_at (unmatched formats)
SELECT 
    COUNT(*) AS total,
    COUNT(recorded_at) AS parsed_ok,
    COUNT(*) - COUNT(recorded_at) AS failed_to_parse
FROM clean.hr;
	
-- ------------------------------------------------------------
-- STEP 5: Clean EDA
-- ------------------------------------------------------------
-- EDA rebuild
-- The same three-format timestamp router and DATE_TRUNC('second') averaging were applied to both EDA and IBI tables.

DROP TABLE IF EXISTS clean.eda;

CREATE TABLE clean.eda AS
SELECT
    patientid::INTEGER AS patient_id,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END AS recorded_at,
    ROUND(AVG(eda::NUMERIC), 4) AS eda_value
FROM eda
WHERE eda IS NOT NULL AND eda != ''
GROUP BY patientid,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END;

-- ------------------------------------------------------------
-- STEP 6: Clean IBI
-- ------------------------------------------------------------
DROP TABLE IF EXISTS clean.ibi;


CREATE TABLE clean.ibi AS
SELECT
    patientid::INTEGER AS patient_id,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END AS recorded_at,
    ROUND(AVG(ibi::NUMERIC), 4) AS ibi_value
FROM ibi
WHERE ibi IS NOT NULL AND ibi != ''
GROUP BY patientid,
    CASE
        WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
        WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
            THEN DATE_TRUNC('second', TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
        ELSE NULL
    END;

-- ============================================================
-- STEP 6: Clean temperature table
-- REBUILD clean.temperature
-- Empatica E4 has one skin temperature sensor only. 
-- 4Hz sampling (4 readings/sec)
-- averaged to 1Hz using DATE_TRUNC + AVG.
-- ============================================================
DROP TABLE IF EXISTS clean.temperature;

CREATE TABLE clean.temperature AS
WITH parsed AS (
    SELECT
        patientid::INTEGER AS patient_id,
        CASE
            WHEN timeof ~ '^\d{4}-\d{2}-\d{2}'
                THEN DATE_TRUNC('second',
                     TO_TIMESTAMP(timeof, 'YYYY-MM-DD HH24:MI:SS'))
            WHEN timeof ~ '^\d{1,2}/\d{2}/\d{2}'
                THEN DATE_TRUNC('second',
                     TO_TIMESTAMP(timeof, 'MM/DD/YY HH24:MI'))
            ELSE NULL
        END AS recorded_at,
        temparature::NUMERIC AS temp_raw
    FROM temperature
    WHERE temparature IS NOT NULL
      AND temparature != ''
)
SELECT
    patient_id,
    recorded_at,
    ROUND(AVG(temp_raw), 2) AS temperature_c
FROM parsed
WHERE recorded_at IS NOT NULL
GROUP BY patient_id, recorded_at;



-- ------------------------------------------------------------
-- STEP 8: Clean foodlog table
-- ------------------------------------------------------------
-- ============================================================
-- REBUILD clean.foodlog
-- Changes: dropped time_end, dropped unit, retained NULL for
--          dietary_fiber_g, total_fat_g, amount
-- ============================================================
DROP TABLE IF EXISTS clean.foodlog;

CREATE TABLE clean.foodlog AS
WITH parsed AS (
    SELECT
        patientid::INTEGER                                          AS patient_id,
        TO_DATE(dateof, 'MM/DD/YYYY')                              AS meal_date,
        CASE
            WHEN time_begin IS NOT NULL AND time_begin != ''
                THEN TO_TIMESTAMP(time_begin, 'MM/DD/YYYY HH24:MI')
            ELSE NULL
        END                                                        AS time_begin,
        logged_food                                                AS food_item,
        CASE WHEN amount ~ '^-?\d+\.?\d*$'
             THEN amount::NUMERIC(8,2) ELSE NULL END               AS amount,
        CASE WHEN calorie ~ '^-?\d+\.?\d*$'
             THEN calorie::NUMERIC(8,2) ELSE NULL END              AS calories,
        CASE WHEN total_carb ~ '^-?\d+\.?\d*$'
             THEN total_carb::NUMERIC(8,2) ELSE NULL END           AS total_carb_g,
        CASE WHEN dietary_fiber ~ '^-?\d+\.?\d*$'
             THEN dietary_fiber::NUMERIC(8,2) ELSE NULL END        AS dietary_fiber_g,
        CASE WHEN sugar ~ '^-?\d+\.?\d*$'
             THEN sugar::NUMERIC(8,2) ELSE NULL END                AS sugar_g,
        CASE WHEN protein ~ '^-?\d+\.?\d*$'
             THEN protein::NUMERIC(8,2) ELSE NULL END              AS protein_g,
        CASE WHEN total_fat ~ '^-?\d+\.?\d*$'
             THEN total_fat::NUMERIC(8,2) ELSE NULL END            AS total_fat_g
    FROM foodlog
    WHERE patientid IS NOT NULL
      AND dateof IS NOT NULL
      AND dateof != ''
)
SELECT DISTINCT ON (patient_id, time_begin, food_item)
    patient_id,
    meal_date,
    time_begin,
    food_item,
    amount,
    calories,
    total_carb_g,
    dietary_fiber_g,
    sugar_g,
    protein_g,
    total_fat_g
FROM parsed
ORDER BY patient_id, time_begin, food_item;

-- ------------------------------------------------------------
-- STEP 9: Add primary keys, foreign keys and indexes for query performance
-- ------------------------------------------------------------
-- ============================================================
-- PRIMARY KEYS FOR ALL 7 TABLES
-- ============================================================

-- demography (natural PK — patient_id is already unique)
ALTER TABLE clean.demography ADD PRIMARY KEY (patient_id);
 
-- dexcom: surrogate serial PK
ALTER TABLE clean.dexcom ADD COLUMN reading_id SERIAL PRIMARY KEY;
 
-- hr
ALTER TABLE clean.hr ADD COLUMN hr_id SERIAL PRIMARY KEY;
 
-- eda
ALTER TABLE clean.eda ADD COLUMN eda_id SERIAL PRIMARY KEY;
 
-- ibi
ALTER TABLE clean.ibi ADD COLUMN ibi_id SERIAL PRIMARY KEY;
 
-- temperature
ALTER TABLE clean.temperature ADD COLUMN temp_id SERIAL PRIMARY KEY;
 
-- foodlog
ALTER TABLE clean.foodlog ADD COLUMN meal_id SERIAL PRIMARY KEY;


-- ============================================================
-- FOREIGN KEYS
-- ============================================================
ALTER TABLE clean.dexcom
    ADD CONSTRAINT fk_dexcom_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);
 
ALTER TABLE clean.hr
    ADD CONSTRAINT fk_hr_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);
 
ALTER TABLE clean.eda
    ADD CONSTRAINT fk_eda_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);
 
ALTER TABLE clean.ibi
    ADD CONSTRAINT fk_ibi_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);
 
ALTER TABLE clean.temperature
    ADD CONSTRAINT fk_temp_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);


ALTER TABLE clean.foodlog
    ADD CONSTRAINT fk_foodlog_patient
    FOREIGN KEY (patient_id) REFERENCES clean.demography(patient_id);


-- ============================================================
-- INDEXES FOR ALL 7 TABLES
-- ============================================================

-- dexcom — most queried table, needs both
CREATE INDEX idx_dexcom_patient  ON clean.dexcom(patient_id);
CREATE INDEX idx_dexcom_time     ON clean.dexcom(recorded_at);

-- hr
CREATE INDEX idx_hr_patient      ON clean.hr(patient_id);
CREATE INDEX idx_hr_time         ON clean.hr(recorded_at);

-- eda
CREATE INDEX idx_eda_patient     ON clean.eda(patient_id);
CREATE INDEX idx_eda_time        ON clean.eda(recorded_at);

-- ibi
CREATE INDEX idx_ibi_patient     ON clean.ibi(patient_id);
CREATE INDEX idx_ibi_time        ON clean.ibi(recorded_at);

-- temperature
CREATE INDEX idx_temp_patient    ON clean.temperature(patient_id);
CREATE INDEX idx_temp_time       ON clean.temperature(recorded_at);

-- foodlog
CREATE INDEX idx_food_patient    ON clean.foodlog(patient_id);
CREATE INDEX idx_food_date       ON clean.foodlog(meal_date);
CREATE INDEX idx_food_begin      ON clean.foodlog(time_begin);

-- demography — small table (16 rows), no index needed

-- ============================================================
-- VERIFY
-- ============================================================
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'clean'
ORDER BY tablename, indexname;

-- ------------------------------------------------------------
-- STEP 10: Validation summary
-- ------------------------------------------------------------
SELECT 'demography'  AS tbl, COUNT(*) AS rows FROM clean.demography
UNION ALL
SELECT 'dexcom',               COUNT(*) FROM clean.dexcom
UNION ALL
SELECT 'hr',                   COUNT(*) FROM clean.hr
UNION ALL
SELECT 'eda',                  COUNT(*) FROM clean.eda
UNION ALL
SELECT 'ibi',                  COUNT(*) FROM clean.ibi
UNION ALL
SELECT 'temperature',          COUNT(*) FROM clean.temperature
UNION ALL
SELECT 'foodlog',              COUNT(*) FROM clean.foodlog
ORDER BY tbl;





-- Check constraints — physiologically valid ranges
ALTER TABLE clean.dexcom
    ADD CONSTRAINT chk_glucose_range
    CHECK (glucose_mg_dl BETWEEN 20 AND 600);
 
ALTER TABLE clean.hr
    ADD CONSTRAINT chk_hr_range
    CHECK (heart_rate BETWEEN 30 AND 220);
 
ALTER TABLE clean.demography
    ADD CONSTRAINT chk_hba1c_range
    CHECK (hba1c BETWEEN 4.0 AND 15.0);
 
ALTER TABLE clean.foodlog
    ADD CONSTRAINT chk_calories
    CHECK (calories IS NULL OR calories >= 0);
 
ALTER TABLE clean.foodlog
    ADD CONSTRAINT chk_meal_times
    CHECK (time_end IS NULL OR time_begin IS NULL
           OR time_end >= time_begin);
 
-- Unique constraints — prevent duplicate readings
ALTER TABLE clean.dexcom
    ADD CONSTRAINT uq_dexcom_patient_time
    UNIQUE (patient_id, recorded_at);
 
ALTER TABLE clean.hr
    ADD CONSTRAINT uq_hr_patient_time
    UNIQUE (patient_id, recorded_at);
 
ALTER TABLE clean.eda
    ADD CONSTRAINT uq_eda_patient_time
    UNIQUE (patient_id, recorded_at);
 
ALTER TABLE clean.ibi
    ADD CONSTRAINT uq_ibi_patient_time
    UNIQUE (patient_id, recorded_at);
 

ALTER TABLE clean.temperature
    ADD CONSTRAINT uq_temp_patient_time
    UNIQUE (patient_id, recorded_at);

-------------------------------------------------------------------------------------------------

-- Query to verify 0 duplicates across all 7 tables.

SELECT 'demography' AS tbl,
       COUNT(*)                          AS total_rows,
       COUNT(DISTINCT patient_id)         AS unique_keys,
       COUNT(*) - COUNT(DISTINCT patient_id) AS dupes
FROM clean.demography
UNION ALL
SELECT 'dexcom', COUNT(*),
       COUNT(DISTINCT (patient_id, recorded_at)),
       COUNT(*) - COUNT(DISTINCT (patient_id, recorded_at))
FROM clean.dexcom
UNION ALL
SELECT 'eda', COUNT(*),
       COUNT(DISTINCT (patient_id, recorded_at)),
       COUNT(*) - COUNT(DISTINCT (patient_id, recorded_at))
FROM clean.eda
UNION ALL
SELECT 'foodlog', COUNT(*),
       COUNT(DISTINCT (patient_id, time_begin, food_item)),
       COUNT(*) - COUNT(DISTINCT (patient_id, time_begin, food_item))
FROM clean.foodlog
UNION ALL
SELECT 'hr', COUNT(*),
       COUNT(DISTINCT (patient_id, recorded_at)),
       COUNT(*) - COUNT(DISTINCT (patient_id, recorded_at))
FROM clean.hr
UNION ALL
SELECT 'ibi', COUNT(*),
       COUNT(DISTINCT (patient_id, recorded_at)),
       COUNT(*) - COUNT(DISTINCT (patient_id, recorded_at))
FROM clean.ibi
UNION ALL
SELECT 'temperature', COUNT(*),
       COUNT(DISTINCT (patient_id, recorded_at)),
       COUNT(*) - COUNT(DISTINCT (patient_id, recorded_at))
FROM clean.temperature
ORDER BY tbl;





