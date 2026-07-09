-----------------Category 3------------------------
---------------------------------------------------
--1. Resuable function – get_cv_percent()

CREATE OR REPLACE FUNCTION clean.get_cv_percent(p_patient_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_mean   NUMERIC;
    v_stddev NUMERIC;
    v_cv     NUMERIC;
BEGIN
    -- Step 1: Get the mean and standard deviation for this patient
    SELECT
        AVG(glucose_mg_dl),
        STDDEV_POP(glucose_mg_dl)
    INTO v_mean, v_stddev
    FROM clean.dexcom
    WHERE patient_id = p_patient_id;

    -- Step 2: If no data exists for this patient return NULL
    IF v_mean IS NULL OR v_mean = 0 THEN
        RETURN NULL;
    END IF;

    -- Step 3: Compute CV% = (STDDEV / MEAN) * 100
    v_cv := ROUND((v_stddev / v_mean) * 100, 2);

    -- Step 4: Return the result
    RETURN v_cv;
END;
$$ LANGUAGE plpgsql;

--------------------------------------------------------------------------------------------

-- 2. Create a stored procedure to compute and insert daily glycemic summary statistics for all patients.

CREATE TABLE IF NOT EXISTS clean.daily_summary (
summary_id     SERIAL PRIMARY KEY,
patient_id     INTEGER REFERENCES clean.demography(patient_id),
summary_date   DATE,
mean_glucose NUMERIC(6,2),
stddev_glucose NUMERIC(6,2),
cv_percent NUMERIC(6,2),
tir_pct NUMERIC(5,2),
hypo_count     INTEGER,
hyper_count    INTEGER,
total_readings INTEGER,
    UNIQUE (patient_id, summary_date)
);

CREATE OR REPLACE PROCEDURE clean.compute_daily_summaries()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clean.daily_summary (
patient_id, summary_date, mean_glucose,
stddev_glucose, cv_percent, tir_pct,
hypo_count, hyper_count, total_readings
    )
    SELECT
patient_id,
DATE(recorded_at),
        ROUND(AVG(glucose_mg_dl), 2),
        ROUND(STDDEV_POP(glucose_mg_dl), 2),
        ROUND(STDDEV_POP(glucose_mg_dl)
            / NULLIF(AVG(glucose_mg_dl), 0) * 100, 2),
        ROUND(COUNT(*) FILTER (
            WHERE glucose_mg_dl BETWEEN 70 AND 180)
            * 100.0 / COUNT(*), 2),
COUNT(*) FILTER (WHERE glucose_mg_dl< 70),
COUNT(*) FILTER (WHERE glucose_mg_dl> 180),
COUNT(*)
    FROM clean.dexcom
    GROUP BY patient_id, DATE(recorded_at)
    ON CONFLICT (patient_id, summary_date)
    DO UPDATE SET
mean_glucose   = EXCLUDED.mean_glucose,
stddev_glucose = EXCLUDED.stddev_glucose,
cv_percent     = EXCLUDED.cv_percent,
tir_pct        = EXCLUDED.tir_pct,
hypo_count     = EXCLUDED.hypo_count,
hyper_count    = EXCLUDED.hyper_count,
total_readings = EXCLUDED.total_readings;
END;
$$;

CALL clean.compute_daily_summaries();

SELECT * FROM clean.daily_summary ORDER BY patient_id, summary_date;


-----------------------------------------------------------------------------------------------------------

-- 3. Create a trigger that automatically logs a glucose alert whenever a reading outside 54-250 mg/dL is inserted.

CREATE TABLE IF NOT EXISTS clean.glucose_alerts (
alert_id      SERIAL PRIMARY KEY,
patient_id    INTEGER,
recorded_at   TIMESTAMP WITH TIME ZONE,
glucose_mg_dl NUMERIC(6,2),
alert_type    TEXT,
created_at    TIMESTAMP DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION clean.fn_glucose_alert()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.glucose_mg_dl< 54 THEN
        INSERT INTO clean.glucose_alerts
            (patient_id, recorded_at, glucose_mg_dl, alert_type)
        VALUES (NEW.patient_id, NEW.recorded_at,
NEW.glucose_mg_dl, 'CRITICAL LOW');
    ELSIF NEW.glucose_mg_dl> 250 THEN
        INSERT INTO clean.glucose_alerts
            (patient_id, recorded_at, glucose_mg_dl, alert_type)
        VALUES (NEW.patient_id, NEW.recorded_at,
NEW.glucose_mg_dl, 'CRITICAL HIGH');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_glucose_alert
AFTER INSERT ON clean.dexcom
FOR EACH ROW EXECUTE FUNCTION clean.fn_glucose_alert();

SELECT * FROM clean.glucose_alerts ORDER BY created_at DESC;

-------------------------------------------------------------------------------------------------------

-- 4. Use a recursive CTE to number consecutive hypoglycemic streaks per patient.

WITH RECURSIVE hypo_streaks AS (
    SELECT patient_id, recorded_at, glucose_mg_dl,
recorded_at AS streak_start, 1 AS streak_len
    FROM clean.dexcom
    WHERE glucose_mg_dl< 70
      AND NOT EXISTS (
          SELECT 1 FROM clean.dexcom prev
          WHERE prev.patient_id = clean.dexcom.patient_id
            AND prev.glucose_mg_dl< 70
            AND prev.recorded_at BETWEEN
clean.dexcom.recorded_at - INTERVAL '6 minutes'
                AND clean.dexcom.recorded_at - INTERVAL '1 second'
      )
    UNION ALL
    SELECT d.patient_id, d.recorded_at, d.glucose_mg_dl,
hs.streak_start, hs.streak_len + 1
    FROM clean.dexcom d
    JOIN hypo_streaks hs
        ON d.patient_id = hs.patient_id
        AND d.glucose_mg_dl< 70
        AND d.recorded_at BETWEEN
hs.recorded_at + INTERVAL '1 second'
            AND hs.recorded_at + INTERVAL '6 minutes'
)
SELECT patient_id, streak_start,
MAX(recorded_at)   AS streak_end,
MAX(streak_len)    AS streak_length,
MIN(glucose_mg_dl) AS lowest_glucose
FROM hypo_streaks
GROUP BY patient_id, streak_start
HAVING MAX(streak_len) >= 3
ORDER BY streak_length DESC;

------------------------------------------------------------------------------------------------------
-- 5. Create a UDF that returns a complete glycemic variability report for a given patient as a table.

CREATE OR REPLACE FUNCTION clean.glycemic_report(p_patient_id INTEGER)
RETURNS TABLE(metric TEXT, value NUMERIC) AS $$
BEGIN
    RETURN QUERY
    SELECT 'Mean Glucose (mg/dL)'::TEXT,
           ROUND(AVG(glucose_mg_dl), 2)
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'STDDEV Glucose',
           ROUND(STDDEV_POP(glucose_mg_dl), 2)
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'CV Percent', clean.get_cv_percent(p_patient_id)
    UNION ALL
    SELECT 'Time In Range %',
           ROUND(COUNT(*) FILTER (
               WHERE glucose_mg_dl BETWEEN 70 AND 180)
               * 100.0 / COUNT(*), 2)
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'Hypo Count (< 70)',
COUNT(*) FILTER (WHERE glucose_mg_dl< 70)::NUMERIC
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'Hyper Count (> 180)',
COUNT(*) FILTER (WHERE glucose_mg_dl> 180)::NUMERIC
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'Max Glucose', MAX(glucose_mg_dl)
    FROM clean.dexcom WHERE patient_id = p_patient_id
    UNION ALL
    SELECT 'Min Glucose', MIN(glucose_mg_dl)
    FROM clean.dexcom WHERE patient_id = p_patient_id;
END;
$$ LANGUAGE plpgsql;

SELECT * FROM clean.glycemic_report(1);

-------------------------------------------------------------------------------------------------------

-- 6. Create a trigger that automatically updates a patient's last_active timestamp when a new glucose reading is inserted.


CREATE TABLE IF NOT EXISTS clean.patient_activity (
patient_id      INTEGER PRIMARY KEY
                    REFERENCES clean.demography(patient_id),
last_glucose_at TIMESTAMP WITH TIME ZONE,
total_readings  INTEGER DEFAULT 0
);

CREATE OR REPLACE FUNCTION clean.fn_update_activity()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO clean.patient_activity
        (patient_id, last_glucose_at, total_readings)
    VALUES (NEW.patient_id, NEW.recorded_at, 1)
    ON CONFLICT (patient_id) DO UPDATE SET
last_glucose_at = GREATEST(
clean.patient_activity.last_glucose_at,
EXCLUDED.last_glucose_at),
total_readings =
clean.patient_activity.total_readings + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_update_activity
AFTER INSERT ON clean.dexcom
FOR EACH ROW EXECUTE FUNCTION clean.fn_update_activity();

SELECT * FROM clean.patient_activity ORDER BY last_glucose_at DESC;

---------------------------------------------------------------------------------------------------------------------

-- 7 Create a stored procedure to classify all patients into glycemic risk tiers and insert them into a risk summary table.

CREATE TABLE IF NOT EXISTS clean.risk_classification (
patient_id    INTEGER PRIMARY KEY
                  REFERENCES clean.demography(patient_id),
avg_glucose NUMERIC(6,2),
cv_percent NUMERIC(6,2),
tir_pct NUMERIC(5,2),
risk_tier     TEXT,
classified_at TIMESTAMP DEFAULT NOW()
);

CREATE OR REPLACE PROCEDURE clean.classify_patient_risk()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clean.risk_classification (
patient_id, avg_glucose, cv_percent, tir_pct, risk_tier
    )
    SELECT patient_id,
        ROUND(AVG(glucose_mg_dl), 2),
        ROUND(STDDEV_POP(glucose_mg_dl)
            / NULLIF(AVG(glucose_mg_dl), 0) * 100, 2),
        ROUND(COUNT(*) FILTER (
            WHERE glucose_mg_dl BETWEEN 70 AND 180)
            * 100.0 / COUNT(*), 2),
        CASE
            WHEN AVG(glucose_mg_dl) > 140
              OR STDDEV_POP(glucose_mg_dl)
                 / NULLIF(AVG(glucose_mg_dl), 0) * 100 > 36
            THEN 'High Risk'
            WHEN AVG(glucose_mg_dl) > 120
            THEN 'Moderate Risk'
            ELSE 'Low Risk'
        END
    FROM clean.dexcom
    GROUP BY patient_id
    ON CONFLICT (patient_id) DO UPDATE SET
avg_glucose   = EXCLUDED.avg_glucose,
cv_percent    = EXCLUDED.cv_percent,
tir_pct       = EXCLUDED.tir_pct,
risk_tier     = EXCLUDED.risk_tier,
classified_at = NOW();
END;
$$;

CALL clean.classify_patient_risk();

SELECT * FROM clean.risk_classification ORDER BY risk_tier, avg_glucose DESC;

----------------------------------------------------------------------------------------------------------------------

-- 8. Show each patient's average glucose broken down by time of day — Morning, Afternoon, Evening, Night — as separate columns.

CREATE EXTENSION IF NOT EXISTS tablefunc;

SELECT * FROM CROSSTAB(
    $$
    SELECT
        patient_id,
        CASE
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 5 AND 11
                THEN 'Morning'
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 12 AND 16
                THEN 'Afternoon'
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 17 AND 21
                THEN 'Evening'
            ELSE 'Night'
        END                              AS time_of_day,
        ROUND(AVG(glucose_mg_dl), 2)     AS avg_glucose
    FROM clean.dexcom
    GROUP BY
        patient_id,
        CASE
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 5 AND 11
                THEN 'Morning'
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 12 AND 16
                THEN 'Afternoon'
            WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 17 AND 21
                THEN 'Evening'
            ELSE 'Night'
        END
    ORDER BY 1, 2
    $$,
    $$ VALUES ('Afternoon'), ('Evening'), ('Morning'), ('Night') $$
) AS ct (
    patient_id  INTEGER,
    afternoon   NUMERIC,
    evening     NUMERIC,
    morning     NUMERIC,
    night       NUMERIC
);

---------------------------------------------------------------------------------------------------
-- 9. Create a trigger to prevent insertion of physiologically impossible glucose readings.

CREATE OR REPLACE FUNCTION clean.fn_validate_glucose()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.glucose_mg_dl< 20 THEN
        RAISE EXCEPTION
            'Glucose value % is below minimum (20 mg/dL) for patient % at %',
NEW.glucose_mg_dl, NEW.patient_id, NEW.recorded_at;
    END IF;
    IF NEW.glucose_mg_dl> 600 THEN
        RAISE EXCEPTION
            'Glucose value % exceeds maximum (600 mg/dL) for patient % at %',
NEW.glucose_mg_dl, NEW.patient_id, NEW.recorded_at;
    END IF;
    IF NEW.recorded_at>NOW() THEN
        RAISE EXCEPTION
            'Future timestamp % is not allowed for patient %',
NEW.recorded_at, NEW.patient_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_validate_glucose
BEFORE INSERT ON clean.dexcom
FOR EACH ROW EXECUTE FUNCTION clean.fn_validate_glucose();

-- Test (should raise exception)
INSERT INTO clean.dexcom (patient_id, recorded_at, glucose_mg_dl)
VALUES (1, NOW(), 10);

--------------------------------------------------------------------------------------------------------------

--10. Create a recursive CTE to build a unified patient monitoring timeline of all study events.

WITH RECURSIVE study_days AS (
    SELECT MIN(DATE(recorded_at)) AS day FROM clean.dexcom
    UNION ALL
    SELECT day + 1 FROM study_days
    WHERE day < (SELECT MAX(DATE(recorded_at)) FROM clean.dexcom)
),
events AS (
    SELECT patient_id, recorded_at AS event_time,
           'Glucose Reading' AS event_type,
glucose_mg_dl::TEXT AS event_detail
    FROM clean.dexcom
    WHERE glucose_mg_dl< 70 OR glucose_mg_dl> 180
    UNION ALL
    SELECT patient_id, time_begin, 'Meal Logged',
food_item || ' (' || total_carb_g || 'g carbs)'
    FROM clean.foodlog WHERE time_begin IS NOT NULL
    UNION ALL
    SELECT patient_id, recorded_at,
           'ALERT: ' || alert_type,
glucose_mg_dl::TEXT || ' mg/dL'
    FROM clean.glucose_alerts
)
SELECT patient_id, event_time, event_type, event_detail
FROM events
ORDER BY patient_id, event_time;
-----------------------------------------------------------------------------------------------------------------

--11.Create a stored procedure that generates a full per-patient report and writes it to a reporting table.

CREATE TABLE IF NOT EXISTS clean.patient_report (
patient_id     INTEGER PRIMARY KEY
                   REFERENCES clean.demography(patient_id),
    gender         TEXT,
    hba1c          NUMERIC(4,1),
    hba1c_category TEXT,
avg_glucose NUMERIC(6,2),
cv_percent NUMERIC(6,2),
tir_pct NUMERIC(5,2),
lbgi NUMERIC(8,4),
hbgi NUMERIC(8,4),
risk_tier      TEXT,
report_date    DATE DEFAULT CURRENT_DATE
);

CREATE OR REPLACE PROCEDURE clean.generate_patient_reports()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clean.patient_report (
patient_id, gender, hba1c, hba1c_category,
avg_glucose, cv_percent, tir_pct, lbgi, hbgi, risk_tier
    )
    SELECT dem.patient_id, dem.gender, dem.hba1c,
        CASE WHEN dem.hba1c < 5.7 THEN 'Normal'
             WHEN dem.hba1c < 6.5 THEN 'Prediabetic'
             ELSE 'Diabetic' END,
        ROUND(AVG(d.glucose_mg_dl), 2),
clean.get_cv_percent(dem.patient_id),
        ROUND(COUNT(*) FILTER (
            WHERE d.glucose_mg_dl BETWEEN 70 AND 180)
            * 100.0 / COUNT(*), 2),
clean.compute_lbgi(dem.patient_id),
clean.compute_hbgi(dem.patient_id),
        CASE WHEN AVG(d.glucose_mg_dl) > 140
              OR clean.get_cv_percent(dem.patient_id) > 36
             THEN 'High Risk'
             WHEN AVG(d.glucose_mg_dl) > 120 THEN 'Moderate Risk'
             ELSE 'Low Risk' END
    FROM clean.demography dem
    JOIN clean.dexcom d ON d.patient_id = dem.patient_id
    GROUP BY dem.patient_id, dem.gender, dem.hba1c
    ON CONFLICT (patient_id) DO UPDATE SET
avg_glucose = EXCLUDED.avg_glucose,
cv_percent  =EXCLUDED.cv_percent,
tir_pct     = EXCLUDED.tir_pct,
lbgi        = EXCLUDED.lbgi,
hbgi        = EXCLUDED.hbgi,
risk_tier   = EXCLUDED.risk_tier,
report_date = CURRENT_DATE;
END;
$$;

CALL clean.generate_patient_reports();

SELECT * FROM clean.patient_report ORDER BY risk_tier, avg_glucose DESC;


------------------------------------------------------------------------------------------------------

--12. Create a trigger that maintains a running count of meals logged per patient per day.

CREATE TABLE IF NOT EXISTS clean.meal_daily_counts (
patient_id  INTEGER REFERENCES clean.demography(patient_id),
meal_date   DATE,
meal_count  INTEGER DEFAULT 0,
total_carbs NUMERIC(8,2) DEFAULT 0,
    PRIMARY KEY (patient_id, meal_date)
);

CREATE OR REPLACE FUNCTION clean.fn_update_meal_counts()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO clean.meal_daily_counts
        (patient_id, meal_date, meal_count, total_carbs)
    VALUES (
NEW.patient_id,
COALESCE(NEW.meal_date, DATE(NEW.time_begin)),
        1,
COALESCE(NEW.total_carb_g, 0))
    ON CONFLICT (patient_id, meal_date) DO UPDATE SET
meal_count  =clean.meal_daily_counts.meal_count + 1,
total_carbs = clean.meal_daily_counts.total_carbs
                    + COALESCE(EXCLUDED.total_carbs, 0);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_update_meal_counts
AFTER INSERT ON clean.foodlog
FOR EACH ROW EXECUTE FUNCTION clean.fn_update_meal_counts();

SELECT * FROM clean.meal_daily_counts ORDER BY patient_id, meal_date;

------------------------------------------------------------------------------------------------------------

--13. Use CROSSTAB to show time-in-range percentage by patient and day of week.

SELECT * FROM CROSSTAB(
    $$
    SELECT patient_id,
           TO_CHAR(recorded_at, 'Dy') AS day_of_week,
ROUND(
COUNT(*) FILTER (WHERE glucose_mg_dl BETWEEN 70 AND 180)
               * 100.0 / COUNT(*), 2
           ) AS tir_pct
    FROM clean.dexcom
    GROUP BY patient_id, TO_CHAR(recorded_at, 'Dy')
    ORDER BY 1, 2
    $$,
    $$ VALUES ('Fri'),('Mon'),('Sat'),('Sun'),
              ('Thu'),('Tue'),('Wed') $$
) AS ct(patient_id INTEGER,
fri NUMERIC, mon NUMERIC, sat NUMERIC,
        sun NUMERIC, thu NUMERIC, tue NUMERIC,
        wed NUMERIC);


-------------------------------------------------------------------------------------

--14. Get a quick patient profile by passing in a patient ID

CREATE OR REPLACE FUNCTION clean.get_patient_profile(p_patient_id INTEGER)
RETURNS TABLE (
    info    TEXT,
    detail  TEXT
) AS $$
BEGIN
    RETURN QUERY

    SELECT 'Patient ID'::TEXT,
           p_patient_id::TEXT

    UNION ALL

    SELECT 'Gender',
           gender
    FROM clean.demography
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'HbA1c',
           hba1c::TEXT
    FROM clean.demography
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'HbA1c Category',
           CASE
               WHEN hba1c < 5.7 THEN 'Normal'
               WHEN hba1c < 6.5 THEN 'Prediabetic'
               ELSE 'Diabetic'
           END
    FROM clean.demography
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Total CGM Readings',
           COUNT(*)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Days Monitored',
           (MAX(DATE(recorded_at))
               - MIN(DATE(recorded_at)) + 1)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Average Glucose',
           ROUND(AVG(glucose_mg_dl), 2)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Highest Glucose',
           MAX(glucose_mg_dl)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Lowest Glucose',
           MIN(glucose_mg_dl)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Time In Range %',
           ROUND(COUNT(*) FILTER (
               WHERE glucose_mg_dl BETWEEN 70 AND 180)
               * 100.0 / NULLIF(COUNT(*), 0), 2)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Hypo Events (< 70)',
           COUNT(*) FILTER (
               WHERE glucose_mg_dl < 70)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Hyper Events (> 180)',
           COUNT(*) FILTER (
               WHERE glucose_mg_dl > 180)::TEXT
    FROM clean.dexcom
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Total Meals Logged',
           COUNT(*)::TEXT
    FROM clean.foodlog
    WHERE patient_id = p_patient_id

    UNION ALL

    SELECT 'Average Heart Rate',
           COALESCE(
               ROUND(AVG(heart_rate), 2)::TEXT,
               'No data')
    FROM clean.hr
    WHERE patient_id = p_patient_id;

END;
$$ LANGUAGE plpgsql;

-- Call it
SELECT * FROM clean.get_patient_profile(1);

-- Call it for all patients
SELECT dem.patient_id, p.*
FROM clean.demography dem
CROSS JOIN LATERAL clean.get_patient_profile(dem.patient_id) p
ORDER BY dem.patient_id;

-------------------------------------------------------------------------------------

-- 15.Check if a glucose value is safe, warning, or dangerous

CREATE OR REPLACE FUNCTION clean.classify_glucose(p_glucose NUMERIC)
RETURNS TEXT AS $$
BEGIN
    IF p_glucose IS NULL THEN
        RETURN 'No reading';
    ELSIF p_glucose < 54 THEN
        RETURN 'Critical Low — Immediate Action Needed';
    ELSIF p_glucose < 70 THEN
        RETURN 'Low — Hypoglycemic';
    ELSIF p_glucose <= 180 THEN
        RETURN 'Normal — In Range';
    ELSIF p_glucose <= 250 THEN
        RETURN 'High — Hyperglycemic';
    ELSE
        RETURN 'Critical High — Immediate Action Needed';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Test it with a single value
SELECT clean.classify_glucose(45);

SELECT clean.classify_glucose(115);

SELECT clean.classify_glucose(280);

-- Use it on the actual dexcom data
SELECT
    patient_id,
    recorded_at,
    glucose_mg_dl,
    clean.classify_glucose(glucose_mg_dl) AS glucose_status
FROM clean.dexcom
ORDER BY patient_id, recorded_at;

-- Count how many readings fall into each zone per patient
SELECT
    patient_id,
    clean.classify_glucose(glucose_mg_dl) AS glucose_status,
    COUNT(*)                               AS reading_count
FROM clean.dexcom
GROUP BY patient_id,
         clean.classify_glucose(glucose_mg_dl)
ORDER BY patient_id, reading_count DESC;




