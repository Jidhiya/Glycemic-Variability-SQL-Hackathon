 								---CATEGORY 2---
----- 1. Compute the rate of change of glucose between consecutive readings using LAG.
SELECT patient_id,
recorded_at,
glucose_mg_dl,
LAG(glucose_mg_dl) OVER
(PARTITION BY patient_id ORDER BY recorded_at) AS prev_glucose,
ROUND(
(glucose_mg_dl - LAG(glucose_mg_dl) OVER
(PARTITION BY patient_id ORDER BY recorded_at))
/ NULLIF(EXTRACT(EPOCH FROM (
recorded_at - LAG(recorded_at) OVER
(PARTITION BY patient_id ORDER BY recorded_at)
)) / 60.0, 0)
, 4) AS rate_of_change_mg_per_min
FROM clean.dexcom
ORDER BY patient_id, recorded_at;

--2. Calculate rolling 2-hour standard deviation of glucose per patient to measure short-term glycemic variability.
SELECT patient_id,
recorded_at,
glucose_mg_dl,
ROUND(STDDEV_POP(glucose_mg_dl)
      OVER (PARTITION BY patient_id
                 ORDER BY recorded_at
                 ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 2)
           AS rolling_2hr_stddev
FROM clean.dexcom
ORDER BY patient_id, recorded_at;

--3. Rank patients by their average glucose using DENSE_RANK() window function. 
SELECT patient_id,
       gender,
       hba1c,
	   avg_glucose,
       DENSE_RANK() OVER (ORDER BY avg_glucose DESC) AS glucose_rank
FROM (
    SELECT d.patient_id,
			dem.gender,
			dem.hba1c,
           ROUND(AVG(d.glucose_mg_dl), 2) AS avg_glucose
    FROM clean.dexcom d
    JOIN clean.demography dem ON d.patient_id = dem.patient_id
    GROUP BY d.patient_id, dem.gender, dem.hba1c
) ranked
ORDER BY glucose_rank;

--4. Detect glucose sensor gaps (missing readings > 15 minutes) per patient using LAG.
WITH gaps AS (
    SELECT patient_id,
		   recorded_at,
			LAG(recorded_at) OVER
               (PARTITION BY patient_id ORDER BY recorded_at) AS prev_at,
			EXTRACT(EPOCH FROM (
			recorded_at - LAG(recorded_at) OVER
               (PARTITION BY patient_id ORDER BY recorded_at)
           )) / 60.0 AS gap_minutes
    FROM clean.dexcom
)
SELECT patient_id,
prev_at           AS gap_start,
recorded_at       AS gap_end,
ROUND(gap_minutes::NUMERIC, 1) AS gap_minutes
FROM gaps
WHERE gap_minutes> 15
ORDER BY gap_minutes DESC;

--5. Calculate the coefficient of variation (CV%) of glucose per patient — a key glycemic variability metric.
SELECT patient_id,
       ROUND(AVG(glucose_mg_dl), 2) AS mean_glucose,
       ROUND(STDDEV_POP(glucose_mg_dl), 2) AS stddev_glucose,
       ROUND(STDDEV_POP(glucose_mg_dl)
           / NULLIF(AVG(glucose_mg_dl), 0) * 100, 2) AS cv_percent,
       CASE
           WHEN STDDEV_POP(glucose_mg_dl)
               / NULLIF(AVG(glucose_mg_dl), 0) * 100 > 36
           THEN 'High Variability'
           ELSE 'Acceptable Variability'
       END AS variability_status
FROM clean.dexcom
GROUP BY patient_id
HAVING COUNT(*) > 10
ORDER BY cv_percent DESC;

--6. Verify every patient in demography has corresponding records in all sensor tables.
SELECT dem.patient_id,
       CASE WHEN d.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS dexcom,
       CASE WHEN h.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS hr,
       CASE WHEN e.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS eda,
       CASE WHEN i.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS ibi,
       CASE WHEN t.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS temperature,
       CASE WHEN f.patient_id IS NULL THEN 'MISSING' ELSE 'OK' END AS foodlog
FROM clean.demography dem
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.dexcom)      d ON d.patient_id = dem.patient_id
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.hr)          h ON h.patient_id = dem.patient_id
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.eda)         e ON e.patient_id = dem.patient_id
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.ibi)   i ON i.patient_id = dem.patient_id
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.temperature) t ON t.patient_id = dem.patient_id
LEFT JOIN (SELECT DISTINCT patient_id FROM clean.foodlog)     f ON f.patient_id = dem.patient_id
WHERE d.patient_id IS NULL OR h.patient_id IS NULL
   OR e.patient_id IS NULL OR i.patient_id IS NULL
   OR t.patient_id IS NULL OR f.patient_id IS NULL
ORDER BY dem.patient_id;

--7. Use LEAD to identify upcoming glucose drops and flag potential hypoglycemic risk.
SELECT patient_id,
recorded_at,
glucose_mg_dl AS current_glucose,
LEAD(glucose_mg_dl) OVER
           (PARTITION BY patient_id ORDER BY recorded_at) AS next_glucose,
       CASE
           WHEN LEAD(glucose_mg_dl) OVER
               (PARTITION BY patient_id ORDER BY recorded_at) < 70
           AND glucose_mg_dl>= 70
           THEN 'Hypoglycemia Warning'
           ELSE 'Normal'
       END AS alert
FROM clean.dexcom
ORDER BY patient_id, recorded_at;

--8. Correlate average glucose with average EDA per patient per hour using a time-window JOIN.
SELECT d.patient_id,
       DATE_TRUNC('hour', d.recorded_at)    AS hour_bucket,
       ROUND(AVG(d.glucose_mg_dl), 2)       AS avg_glucose,
       ROUND(AVG(e.eda_value), 4)            AS avg_eda
FROM clean.dexcom d
JOIN clean.eda e
    ON e.patient_id = d.patient_id
    AND DATE_TRUNC('hour', e.recorded_at)
      = DATE_TRUNC('hour', d.recorded_at)
GROUP BY d.patient_id, DATE_TRUNC('hour', d.recorded_at)
ORDER BY d.patient_id, hour_bucket;

--9.Find patients whose glucose exceeded 180 mg/dL for 3 or more consecutive readings.
WITH numbered AS (
    SELECT patient_id, recorded_at, glucose_mg_dl,
           ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY recorded_at) AS rn,
           ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY recorded_at)
           - ROW_NUMBER() OVER (
               PARTITION BY patient_id,
               CASE WHEN glucose_mg_dl> 180 THEN 1 ELSE 0 END
               ORDER BY recorded_at) AS grp
    FROM clean.dexcom
    WHERE glucose_mg_dl> 180
)
SELECT patient_id,
MIN(recorded_at)  ASstreak_start,
MAX(recorded_at)  ASstreak_end,
COUNT(*)          AS consecutive_readings
FROM numbered
GROUP BY patient_id, grp
HAVING COUNT(*) >= 3
ORDER BY consecutive_readings DESC;

--10. Use pg_size_pretty() to report the size of each clean schema table on disk.
SELECT table_name,
pg_size_pretty(pg_relation_size(
           'clean.' || table_name))            AS table_size,
pg_size_pretty(pg_total_relation_size(
           'clean.' || table_name))            AS total_with_indexes
FROM information_schema.tables
WHERE table_schema = 'clean'
ORDER BY pg_total_relation_size(
    'clean.' || table_name) DESC;

--11. — Identify foodlog entries with future timestamps or where meal_date contradicts the date from time_begin.
SELECT patient_id,
meal_date,
time_begin,
DATE(time_begin) AS extracted_date,
food_item,
       CASE
           WHEN time_begin>NOW()
               THEN 'Future timestamp'
           WHEN DATE(time_begin) != meal_date
               THEN 'Date contradiction'
           ELSE 'Unknown anomaly'
       END AS anomaly_type
FROM clean.foodlog
WHERE time_begin>NOW()
   OR (time_begin IS NOT NULL
       AND DATE(time_begin) != meal_date)
ORDER BY patient_id, time_begin;

--12.Ranking Top 3 highest records per patient from eda table.
WITH ranked_data AS (
    SELECT
        dg.patient_id,
        dg.hba1c,
        dg.gender,
        date_trunc('hour', e.recorded_at) AS hourly_bucket,
        ROUND(AVG(e.eda_value), 2) AS average_eda,
        ROUND(MAX(e.eda_value), 2) AS peak_eda,
        COUNT(*) AS total_readings,
        -- Ranks highest hourly peaks independently for each unique patient
        DENSE_RANK() OVER(
            PARTITION BY dg.patient_id
            ORDER BY MAX(e.eda_value) DESC
        ) AS glucose_stress_rank
    FROM clean.demography dg
    INNER JOIN clean.eda e ON dg.patient_id = e.patient_id
    GROUP BY dg.patient_id, dg.hba1c, dg.gender, hourly_bucket
    HAVING COUNT(*) >= 3500
)
SELECT *
FROM ranked_data
WHERE glucose_stress_rank <= 3
ORDER BY patient_id ASC, glucose_stress_rank ASC;

--13.Identify episodes of elevated sympathetic nervous system response (HR > 95 BPM and EDA > 2.0 μS) and compute average skin temperature during these episodes.
SELECT h.patient_id,
COUNT(*)                        AS stress_episodes,
       ROUND(AVG(h.heart_rate), 2)     AS avg_hr_during_stress,
       ROUND(AVG(e.eda_value), 4)      AS avg_eda_during_stress,
       ROUND(AVG(t.temperature_c), 2)  AS avg_skin_temp_during_stress
FROM clean.hr h
JOIN clean.eda e
    ON e.patient_id = h.patient_id
    AND e.recorded_at BETWEEN
h.recorded_at - INTERVAL '30 seconds'
        AND h.recorded_at + INTERVAL '30 seconds'
JOIN clean.temperature t
    ON t.patient_id = h.patient_id
    AND t.recorded_at BETWEEN
h.recorded_at - INTERVAL '30 seconds'
        AND h.recorded_at + INTERVAL '30 seconds'
WHERE h.heart_rate> 95
  AND e.eda_value> 2.0
GROUP BY h.patient_id

ORDER BY stress_episodes DESC;

--14. Compute NTILE(4) to divide patients into quartiles based on their average glucose.
SELECT patient_id,
avg_glucose,
glucose_quartile,
       CASE glucose_quartile
           WHEN 1 THEN 'Low Risk'
           WHEN 2 THEN 'Moderate Risk'
           WHEN 3 THEN 'Elevated Risk'
           WHEN 4 THEN 'High Risk'
       END AS risk_tier
FROM (
    SELECT patient_id,
           ROUND(AVG(glucose_mg_dl), 2) AS avg_glucose,
NTILE(4) OVER (
               ORDER BY AVG(glucose_mg_dl)
           ) AS glucose_quartile
    FROM clean.dexcom
    GROUP BY patient_id
) q
ORDER BY avg_glucose;

--15. Calculate the average heart rate during hyperglycemic vs normal glucose periods per patient.
SELECT d.patient_id,
       CASE
           WHEN d.glucose_mg_dl> 180 THEN 'Hyperglycemic'
           WHEN d.glucose_mg_dl< 70  THEN 'Hypoglycemic'
           ELSE 'Normal'
       END                                AS glucose_state,
       ROUND(AVG(h.heart_rate), 2)        AS avg_hr_in_state,
COUNT(DISTINCT d.recorded_at)      AS reading_count
FROM clean.dexcom d
JOIN clean.hr h
    ON h.patient_id = d.patient_id
    AND h.recorded_at BETWEEN d.recorded_at
                         AND d.recorded_at + INTERVAL '5 minutes'
GROUP BY d.patient_id,
    CASE
        WHEN d.glucose_mg_dl> 180 THEN 'Hyperglycemic'
        WHEN d.glucose_mg_dl< 70  THEN 'Hypoglycemic'
        ELSE 'Normal'
    END
ORDER BY d.patient_id, glucose_state;

-- 16.Use FIRST_VALUE and LAST_VALUE to compare each patient's first and last glucose reading.
SELECT DISTINCT patient_id,
       FIRST_VALUE(glucose_mg_dl) OVER (
           PARTITION BY patient_id ORDER BY recorded_at
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS first_glucose,
       LAST_VALUE(glucose_mg_dl) OVER (
           PARTITION BY patient_id ORDER BY recorded_at
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS last_glucose,
       LAST_VALUE(glucose_mg_dl) OVER (
           PARTITION BY patient_id ORDER BY recorded_at
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) - FIRST_VALUE(glucose_mg_dl) OVER (
           PARTITION BY patient_id ORDER BY recorded_at
           ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
       ) AS glucose_trend
FROM clean.dexcom
ORDER BY patient_id;

--17. Compute hourly average temperature and correlate with hourly average glucose.

SELECT d.patient_id,
       DATE_TRUNC('hour', d.recorded_at)   AS hour_bucket,
       ROUND(AVG(d.glucose_mg_dl), 2)      AS avg_glucose,
       ROUND(AVG(t.temperature_c), 2)      AS avg_temp_c
FROM clean.dexcom d
JOIN clean.temperature t
    ON t.patient_id = d.patient_id
    AND DATE_TRUNC('hour', t.recorded_at)
     = DATE_TRUNC('hour', d.recorded_at)
GROUP BY d.patient_id, DATE_TRUNC('hour', d.recorded_at)
ORDER BY d.patient_id, hour_bucket;

--18. Calculate running total of carbohydrates consumed per patient using a cumulative window.
SELECT patient_id,
meal_date,
food_item,
total_carb_g,
SUM(total_carb_g) OVER (
           PARTITION BY patient_id
           ORDER BY time_begin
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_carbs
FROM clean.foodlog
WHERE total_carb_g IS NOT NULL
ORDER BY patient_id, time_begin;

--19. Use pg_indexes to list all indexes created in the clean schema.
SELECT tablename,
indexname,
indexdef
FROM pg_indexes
WHERE schemaname = 'clean'
ORDER BY tablename, indexname;

--20. Identify patients with consistently high glucose variability across all days using daily STDDEV.
SELECT patient_id,
       ROUND(AVG(daily_stddev), 2)    AS avg_daily_stddev,
       ROUND(MAX(daily_stddev), 2)    AS max_daily_stddev,
COUNT(*)                        AS days_monitored
FROM (
    SELECT patient_id,
DATE(recorded_at)           AS reading_date,
           ROUND(STDDEV_POP(glucose_mg_dl), 2) AS daily_stddev
    FROM clean.dexcom
    GROUP BY patient_id, DATE(recorded_at)
    HAVING COUNT(*) >= 12
) daily
GROUP BY patient_id
ORDER BY avg_daily_stddev DESC;

-- 21.Calculate the average glucose during nighttime (00:00-06:00) vs daytime (06:00-22:00) per patient.

SELECT patient_id,
       CASE
           WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 0 AND 5
               THEN 'Nighttime (00-06)'
           WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 6 AND 21
               THEN 'Daytime (06-22)'
           ELSE 'Evening (22-24)'
       END                                   AS time_period,
       ROUND(AVG(glucose_mg_dl), 2)          AS avg_glucose,
COUNT(*)                               AS reading_count
FROM clean.dexcom
GROUP BY patient_id,
    CASE
        WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 0 AND 5
            THEN 'Nighttime (00-06)'
        WHEN EXTRACT(HOUR FROM recorded_at) BETWEEN 6 AND 21
            THEN 'Daytime (06-22)'
        ELSE 'Evening (22-24)'
    END
ORDER BY patient_id, time_period;

--22. Use a range window to calculate average EDA in the 10 minutes surrounding each glucose reading.
SELECT d.patient_id,
d.recorded_at,
d.glucose_mg_dl,
       ROUND(AVG(e.eda_value)
           OVER (
               PARTITION BY d.patient_id
               ORDER BY d.recorded_at
               RANGE BETWEEN INTERVAL '10 minutes' PRECEDING
                         AND INTERVAL '10 minutes' FOLLOWING
           ), 4) AS avg_eda_10min_window
FROM clean.dexcom d
JOIN clean.eda e
    ON e.patient_id = d.patient_id
    AND e.recorded_at BETWEEN
d.recorded_at - INTERVAL '10 minutes'
        AND d.recorded_at + INTERVAL '10 minutes'
ORDER BY d.patient_id, d.recorded_at
LIMIT 500;

--23. What are the average daily meal counts per patient, and how can we categorize their eating behaviors (e.g., Frequent Eater vs. Occasional Skipper)?
WITH  daily_meal_counts AS (
SELECT patient_id, date_trunc('day',time_begin)::date AS day_recorded , Count(DISTINCT time_begin) AS  meals_logged
FROM clean.foodlog
GROUP BY patient_id,  date_trunc('day',time_begin)::date
)
SELECT
dmc.patient_id,
ROUND(AVG(dmc.meals_logged),1) AS avg_daily_meals,
COUNT(dmc.day_recorded) AS total_tracked_days,
CASE
WHEN AVG(dmc.meals_logged) >= 5 THEN  'Frequent Eater'
WHEN AVG(dmc.meals_logged) >= 3 THEN  'Regular Eater'
WHEN AVG(dmc.meals_logged) >=1 THEN 'Occasional Skipper'
ELSE ' Several meal skipper'
END AS tracking_behaviour
FROM daily_meal_countsdmc
GROUP BY dmc.patient_id
ORDER BY avg_daily_meals  DESC;

--24. Generate a continuous 30-minute moving average of heart rate for every patient to identify sustained cardiovascular trends and reduce the impact of short-term fluctuations.

SELECT
patient_id,
recorded_at,
heart_rate,
ROUND(
AVG(heart_rate) OVER (
            PARTITION BY patient_id
            ORDER BY recorded_at
            ROWS BETWEEN 1799 PRECEDING AND CURRENT ROW
        ), 2
    ) AS rolling_30min_avg_hr
FROM clean.hr
ORDER BY patient_id, recorded_at;

--25.Which participant had the most repeated high-heart-rate episodes?

WITH personal_hr AS (
    SELECT
patient_id,
recorded_at,
        heart_rate,
AVG(heart_rate) OVER (
            PARTITION BY patient_id
        ) AS avg_hr,
STDDEV(heart_rate) OVER (
            PARTITION BY patient_id
        ) AS std_hr
    FROM clean.hr
)
SELECT
patient_id,
COUNT(*) AS high_hr_episode_count
FROM personal_hr
WHERE heart_rate >avg_hr + std_hr
GROUP BY patient_id
ORDER BY high_hr_episode_count DESC;

--26  For each patient, what is the difference between their average glucose on days they ate high-sugar meals (total daily sugar > 30g) versus low-sugar days?

 WITH daily_sugar AS (
    SELECT
        patient_id,
        meal_date,
        SUM(sugar_g)  AS total_daily_sugar,
        CASE
            WHEN SUM(sugar_g) > 30 THEN 'High Sugar Day'
            ELSE 'Low Sugar Day'
        END           AS day_type
    FROM clean.foodlog
    WHERE sugar_g IS NOT NULL
    GROUP BY patient_id, meal_date
),
glucose_by_day_type AS (
    SELECT
        d.patient_id,
        ds.day_type,
        ROUND(AVG(d.glucose_mg_dl), 2) AS avg_glucose
    FROM clean.dexcom d
    JOIN daily_sugar ds
        ON ds.patient_id = d.patient_id
        AND ds.meal_date = DATE(d.recorded_at)
    GROUP BY d.patient_id, ds.day_type
)
SELECT
    g.patient_id,
    dem.hba1c,
    ROUND(MAX(avg_glucose) FILTER (
        WHERE day_type = 'High Sugar Day'), 2)  AS avg_glucose_high_sugar_days,
    ROUND(MAX(avg_glucose) FILTER (
        WHERE day_type = 'Low Sugar Day'), 2)   AS avg_glucose_low_sugar_days,
    ROUND(
        MAX(avg_glucose) FILTER (WHERE day_type = 'High Sugar Day')
        - MAX(avg_glucose) FILTER (WHERE day_type = 'Low Sugar Day')
    , 2)                                        AS glucose_difference
FROM glucose_by_day_type g
JOIN clean.demography dem ON dem.patient_id = g.patient_id
GROUP BY g.patient_id, dem.hba1c
ORDER BY glucose_difference DESC NULLS LAST;

--27. What is the average heart rate for each patient during the first half of the study versus the second half?
WITH study_bounds AS (
    SELECT
        patient_id,
        MIN(recorded_at)                              AS study_start,
        MAX(recorded_at)                              AS study_end,
        MIN(recorded_at) + (
            MAX(recorded_at) - MIN(recorded_at)
        ) / 2                                         AS study_midpoint
    FROM clean.hr
    GROUP BY patient_id
),
hr_classified AS (
    SELECT
        h.patient_id,
        h.recorded_at,
        h.heart_rate,
        CASE
            WHEN h.recorded_at<sb.study_midpoint
                THEN 'First Half'
            ELSE 'Second Half'
        END                                           AS study_half,
        sb.study_start,
        sb.study_midpoint,
        sb.study_end
    FROM clean.hr h
    JOIN study_bounds sb ON sb.patient_id = h.patient_id
)
SELECT
    hc.patient_id,
    dem.hba1c,
    dem.gender,
    TO_CHAR(MIN(study_start), 'YYYY-MM-DD')          AS study_start,
    TO_CHAR(MIN(study_midpoint), 'YYYY-MM-DD')       AS midpoint,
    TO_CHAR(MIN(study_end), 'YYYY-MM-DD')            AS study_end,
    ROUND(AVG(heart_rate) FILTER (
        WHERE study_half = 'First Half'), 2)          AS avg_hr_first_half,
    ROUND(AVG(heart_rate) FILTER (
        WHERE study_half = 'Second Half'), 2)         AS avg_hr_second_half,
    ROUND(
        AVG(heart_rate) FILTER (WHERE study_half = 'Second Half')
        - AVG(heart_rate) FILTER (WHERE study_half = 'First Half')
    , 2)                                              AS hr_change,
    CASE
        WHEN AVG(heart_rate) FILTER (WHERE study_half = 'Second Half')
           > AVG(heart_rate) FILTER (WHERE study_half = 'First Half')
        THEN 'HR Increased'
        WHEN AVG(heart_rate) FILTER (WHERE study_half = 'Second Half')
           < AVG(heart_rate) FILTER (WHERE study_half = 'First Half')
        THEN 'HR Decreased'
        ELSE 'No Change'
    END                                               AS trend
FROM hr_classified hc
JOIN clean.demography dem ON dem.patient_id = hc.patient_id
GROUP BY hc.patient_id, dem.hba1c, dem.gender
ORDER BY hr_change DESC;

-- 28. For each patient, what was their average glucose on days they logged meals versus days they did not log any meals?

WITH logged_days AS (
    SELECT DISTINCT
        patient_id,
        meal_date AS logged_date
    FROM clean.foodlog
),
glucose_classified AS (
    SELECT
        d.patient_id,
        d.glucose_mg_dl,
        DATE(d.recorded_at)            AS reading_date,
        CASE
            WHEN ld.logged_date IS NOT NULL
                THEN 'Meal Logged'
            ELSE 'No Meal Logged'
        END                            AS day_type
    FROM clean.dexcom d
    LEFT JOIN logged_days ld
        ON ld.patient_id  = d.patient_id
        AND ld.logged_date = DATE(d.recorded_at)
)
SELECT
    gc.patient_id,
    dem.gender,
    dem.hba1c,
    COUNT(DISTINCT reading_date)
        FILTER (WHERE day_type = 'Meal Logged')     AS days_with_meals,
    COUNT(DISTINCT reading_date)
        FILTER (WHERE day_type = 'No Meal Logged')  AS days_without_meals,
    ROUND(AVG(glucose_mg_dl)
        FILTER (WHERE day_type = 'Meal Logged'),
    2)                                              AS avg_glucose_logged_days,
    ROUND(AVG(glucose_mg_dl)
        FILTER (WHERE day_type = 'No Meal Logged'),
    2)                                              AS avg_glucose_unlogged_days,
    ROUND(
        AVG(glucose_mg_dl)
            FILTER (WHERE day_type = 'Meal Logged')
        - AVG(glucose_mg_dl)
            FILTER (WHERE day_type = 'No Meal Logged')
    , 2)                                            AS glucose_difference,
    CASE
        WHEN AVG(glucose_mg_dl)
                FILTER (WHERE day_type = 'Meal Logged')
           > AVG(glucose_mg_dl)
                FILTER (WHERE day_type = 'No Meal Logged')
        THEN 'Higher on meal days'
        WHEN AVG(glucose_mg_dl)
                FILTER (WHERE day_type = 'Meal Logged')
           < AVG(glucose_mg_dl)
                FILTER (WHERE day_type = 'No Meal Logged')
        THEN 'Lower on meal days'
        ELSE 'No difference'
    END                                             AS interpretation
FROM glucose_classified gc
JOIN clean.demography dem ON dem.patient_id = gc.patient_id
GROUP BY gc.patient_id, dem.gender, dem.hba1c
ORDER BY glucose_difference DESC NULLS LAST;

--29. How many times did each patient's glucose drop below 70 mg/dL within 2 hours of logging a high-carb meal (more than 60g carbs)?
WITH high_carb_meals AS (
    SELECT
        patient_id,
        time_begin          AS meal_time,
        food_item,
        total_carb_g
    FROM clean.foodlog
    WHERE total_carb_g> 60
      AND time_begin IS NOT NULL
),
hypo_after_high_carb AS (
    SELECT
        hcm.patient_id,
        hcm.meal_time,
        hcm.food_item,
        hcm.total_carb_g,
        d.recorded_at       AS hypo_time,
        d.glucose_mg_dl
    FROM high_carb_meals hcm
    JOIN clean.dexcom d
        ON d.patient_id   = hcm.patient_id
        AND d.recorded_at BETWEEN hcm.meal_time
                              AND hcm.meal_time + INTERVAL '2 hours'
    WHERE d.glucose_mg_dl< 70
)
SELECT
    dem.patient_id,
    dem.gender,
    dem.hba1c,
    COUNT(hahc.hypo_time)               AS reactive_hypo_events,
    COUNT(DISTINCT hahc.meal_time)       AS high_carb_meals_that_caused_hypo,
    ROUND(AVG(hahc.glucose_mg_dl), 2)   AS avg_glucose_during_hypo,
    ROUND(MIN(hahc.glucose_mg_dl), 2)   AS lowest_glucose_after_high_carb,
    ROUND(AVG(hahc.total_carb_g), 2)    AS avg_carbs_of_triggering_meals
FROM clean.demography dem
LEFT JOIN hypo_after_high_carb hahc
    ON hahc.patient_id = dem.patient_id
GROUP BY dem.patient_id, dem.gender, dem.hba1c
ORDER BY reactive_hypo_events DESC;

--30. Calculate the daily time-in-range percentage per patient using a date-range grouping.
SELECT patient_id,
       DATE_TRUNC('day', recorded_at)   AS day,
COUNT(*) AS total_readings,
COUNT(*) FILTER (WHERE glucose_mg_dl BETWEEN 70 AND 180) AS in_range,
ROUND(
COUNT(*) FILTER (WHERE glucose_mg_dl BETWEEN 70 AND 180)
           * 100.0 / NULLIF(COUNT(*), 0), 2
)     AS tir_pct
FROM clean.dexcom
GROUP BY patient_id, DATE_TRUNC('day', recorded_at)
ORDER BY patient_id, day;
























