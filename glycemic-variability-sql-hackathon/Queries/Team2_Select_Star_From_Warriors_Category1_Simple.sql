----------------------------------------------------------------------
--1. What is the average glucose level for each patient?
---------------------------------------------------------------------
SELECT d.patient_id,
       dem.gender,
       dem.hba1c,
       ROUND(AVG(d.glucose_mg_dl), 2) AS avg_glucose,
       COUNT(*)                        AS total_readings	
FROM clean.dexcom d
JOIN clean.demography dem ON d.patient_id = dem.patient_id
GROUP BY d.patient_id, dem.gender, dem.hba1c
ORDER BY avg_glucose DESC;


------------------------------------------------------------------
--2. How many glucose readings does each patient have, and what date range do they cover?
--------------------------------------------------------------------------
SELECT patient_id,
       COUNT(*)                           AS total_readings,
       MIN(DATE(recorded_at))             AS first_reading,
       MAX(DATE(recorded_at))             AS last_reading,
       MAX(DATE(recorded_at))
           - MIN(DATE(recorded_at)) + 1   AS days_monitored
FROM clean.dexcom
GROUP BY patient_id
ORDER BY days_monitored DESC;


------------------------------------------------------------------------
--3. Classify each glucose reading as Hypoglycemic, Normal, or Hyperglycemic using clinical thresholds.
----------------------------------------------------------------------------------------

SELECT patient_id,
       recorded_at,
       glucose_mg_dl,
       CASE
           WHEN glucose_mg_dl < 70   THEN 'Hypoglycemic'
           WHEN glucose_mg_dl <= 180  THEN 'Normal'
           ELSE 'Hyperglycemic'
       END AS glucose_category
FROM clean.dexcom
ORDER BY patient_id, recorded_at;
----------------------------------------------------------------------------------
--4. What percentage of male and female patients are categorized as normal versus prediabetic based on their HbA1c levels,
--along with the total patient count for each gender?
---------------------------------------------------------------------------
SELECT gender,
COUNT(*) as Total_Patients,
ROUND(100.0 * COUNT(CASE WHEN hba1c <5.7 THEN 1 END )/COUNT(*),1)::text || '%' AS Normal_Percent,
ROUND(100.0 * COUNT(CASE WHEN hba1c >=5.7 AND hba1c <= 6.4 THEN 1 END )/COUNT(*),1)::text || '%' AS Prediabetic_Percent
FROM clean.demography
GROUP BY gender;

--------------------------------------------------------------------------------
--5. What is the gender distribution of patients and their average HbA1c by gender?
---------------------------------------------------------------------------------
SELECT gender,
       COUNT(*)              AS patient_count,
       ROUND(AVG(hba1c), 2)  AS avg_hba1c,
       MIN(hba1c)            AS min_hba1c,
       MAX(hba1c)            AS max_hba1c
FROM clean.demography
GROUP BY gender
ORDER BY avg_hba1c DESC;

-------------------------------------------------------------------------
--6. Classify each patient by HbA1c into Normal, Prediabetic, or Diabetic and show their average glucose. 
---------------------------------------------------------------------------------------
SELECT dem.patient_id,
       dem.gender,
       dem.hba1c,
       CASE
           WHEN dem.hba1c < 5.7  THEN 'Normal'
           WHEN dem.hba1c < 6.5  THEN 'Prediabetic'
           ELSE 'Diabetic'
       END                              AS hba1c_category,
       ROUND(AVG(d.glucose_mg_dl), 2)  AS avg_glucose
FROM clean.demography dem
JOIN clean.dexcom d ON dem.patient_id = d.patient_id
GROUP BY dem.patient_id, dem.gender, dem.hba1c
ORDER BY dem.hba1c DESC;

-------------------------------------------------------------------------------
--7. What is the total calorie and carbohydrate intake per patient across all logged meals?
---------------------------------------------------------------------------------
SELECT patient_id,
       COUNT(*)                          AS total_meals_logged,
       ROUND(SUM(calories), 2)           AS total_calories,
       ROUND(AVG(calories), 2)           AS avg_calories_per_meal,
       ROUND(SUM(total_carb_g), 2)       AS total_carbs_g,
       ROUND(AVG(total_carb_g), 2)       AS avg_carbs_per_meal
FROM clean.foodlog
WHERE calories IS NOT NULL
GROUP BY patient_id
ORDER BY total_carbs_g DESC;

--------------------------------------------------------------------------
--8. What is the average heart rate per patient and how does it compare to clinical norms?
----------------------------------------------------------------------------
SELECT patient_id,
       ROUND(AVG(heart_rate), 2)   AS avg_hr,
       MAX(heart_rate)             AS max_hr,
       MIN(heart_rate)             AS min_hr,
       CASE
           WHEN AVG(heart_rate) < 60   THEN 'Bradycardia'
           WHEN AVG(heart_rate) <= 100  THEN 'Normal'
           ELSE 'Tachycardia'
       END                         AS hr_zone
FROM clean.hr
GROUP BY patient_id
ORDER BY avg_hr DESC;

------------------------------------------------------------------------------------
--9 . Find all unique high-sugar food items (sugar > 20g) where the amount was explicitly recorded, 
--showing total calories and maximum sugar value.
--------------------------------------------------------------------------------------
SELECT food_item,
       COUNT(*)                     AS times_logged,
       ROUND(SUM(calories), 2)      AS total_calories_consumed,
       ROUND(MAX(sugar_g), 2)       AS max_sugar_recorded_g,
       ROUND(AVG(sugar_g), 2)       AS avg_sugar_g,
       ROUND(AVG(total_carb_g), 2)  AS avg_carbs_g
FROM clean.foodlog
WHERE sugar_g > 20
  AND amount IS NOT NULL
GROUP BY food_item
ORDER BY max_sugar_recorded_g DESC;


---------------------------------------------------------------------
--10. Calculate average EDA and average IBI grouped by patient gender,
---excluding baseline low-stress readings (EDA < 0.05 μS).
------------------------------------------------------------------------------
SELECT dem.gender,
       COUNT(DISTINCT dem.patient_id)      AS patient_count,
       ROUND(AVG(e.eda_value), 4)          AS avg_eda_microsiemens,
       ROUND(AVG(i.ibi_value), 4)          AS avg_ibi_seconds,
       ROUND(1.0 / NULLIF(AVG(i.ibi_value), 0) * 60, 2)
                                           AS estimated_hr_bpm
FROM clean.demography dem
JOIN clean.eda e ON e.patient_id = dem.patient_id
JOIN clean.ibi i
    ON i.patient_id = dem.patient_id
    AND DATE_TRUNC('second', i.recorded_at)
      = DATE_TRUNC('second', e.recorded_at)
WHERE e.eda_value >= 0.05
GROUP BY dem.gender
ORDER BY avg_eda_microsiemens DESC;

--------------------------------------------------------------------------
--11. Find high-calorie food items (> 200 calories) where macronutrient breakdown was not recorded,
--flagging data quality gaps.
-----------------------------------------------------------------------

SELECT food_item,
       ROUND(AVG(calories), 2)   AS avg_calories,
       COUNT(*)                   AS gap_count,
       COUNT(*) FILTER (
           WHERE total_carb_g IS NULL) AS missing_carbs,
       COUNT(*) FILTER (
           WHERE protein_g IS NULL)    AS missing_protein,
       COUNT(*) FILTER (
           WHERE total_fat_g IS NULL)  AS missing_fat
FROM clean.foodlog
WHERE calories > 200
  AND (total_carb_g IS NULL
    OR protein_g    IS NULL
    OR total_fat_g  IS NULL)
GROUP BY food_item
ORDER BY gap_count DESC;

------------------------------------------------------------------------
--12. Which patients have readings above 180 mg/dL (hyperglycemia) and how many such readings do they have?
----------------------------------------------------------------------------------------------
SELECT patient_id,
       COUNT(*)                      AS hyper_count,
       ROUND(AVG(glucose_mg_dl), 2)  AS avg_glucose_when_high
FROM clean.dexcom
WHERE glucose_mg_dl > 180
GROUP BY patient_id
HAVING COUNT(*) > 0
ORDER BY hyper_count DESC;

-----------------------------------------------------------------------
--13. Classify all meal items as 'High Sugar Focus' or 'Complex/Other Carbs' 
--and show total calories and maximum portion per category.
------------------------------------------------------------------------
SELECT
    CASE
        WHEN sugar_g / NULLIF(total_carb_g, 0) > 0.5
            THEN 'High Sugar Focus'
        ELSE 'Complex / Other Carbs'
    END                              AS carb_category,
    COUNT(*)                          AS meal_count,
    ROUND(SUM(calories), 2)           AS total_calories_consumed,
    ROUND(MAX(amount), 2)             AS max_single_meal_amount,
    ROUND(AVG(sugar_g), 2)            AS avg_sugar_g,
    ROUND(AVG(total_carb_g), 2)       AS avg_carbs_g
FROM clean.foodlog
WHERE sugar_g IS NOT NULL
  AND total_carb_g IS NOT NULL
  AND total_carb_g > 0
GROUP BY
    CASE
        WHEN sugar_g / NULLIF(total_carb_g, 0) > 0.5
            THEN 'High Sugar Focus'
        ELSE 'Complex / Other Carbs'
    END
ORDER BY total_calories_consumed DESC;


---------------------------------------------------------------
--14. Show all patients who had both hypoglycemic and hyperglycemic events using UNION.
-----------------------------------------------------------------------------------------
SELECT DISTINCT patient_id, 'Has Hypoglycemia' AS condition
FROM clean.dexcom
WHERE glucose_mg_dl < 70
UNION
SELECT DISTINCT patient_id, 'Has Hyperglycemia'
FROM clean.dexcom
WHERE glucose_mg_dl > 180
ORDER BY patient_id, condition;


------------------------------------------------------------------------------
--15. What is the average skin temperature per patient across the monitoring period?
----------------------------------------------------------------------------------
SELECT patient_id,
       ROUND(AVG(temperature_c), 2)  AS avg_temp_c,
       MIN(temperature_c)             AS min_temp_c,
       MAX(temperature_c)             AS max_temp_c
FROM clean.temperature
GROUP BY patient_id
ORDER BY avg_temp_c DESC;

-----------------------------------------------------------------------------
--16. What is the average sugar and protein intake per patient per day?
---------------------------------------------------------------------------
SELECT f.patient_id,
       DATE(f.time_begin)            AS meal_date,
       ROUND(SUM(f.sugar_g), 2)      AS daily_sugar_g,
       ROUND(SUM(f.protein_g), 2)    AS daily_protein_g,
       ROUND(SUM(f.total_carb_g), 2) AS daily_carbs_g,
       COUNT(*)                       AS meals_logged
FROM clean.foodlog f
JOIN clean.demography d ON f.patient_id = d.patient_id
WHERE f.sugar_g IS NOT NULL
GROUP BY f.patient_id, DATE(f.time_begin)
ORDER BY f.patient_id, meal_date;

-----------------------------------------------------------------------------
---17. What is the peak temperature recorded and the total number of 
--temperature readings taken for each patient per day?
-----------------------------------------------------------------
SELECT
    patient_id,
    date_trunc('day', recorded_at)::date AS daily_reading,
    MAX(temperature_c) AS peak_temperature,
    COUNT(*) as Total_Temp_readings
 FROM clean.temperature
 GROUP BY
    patient_id ,
    daily_reading
 ORDER BY
    patient_id ,
    daily_reading;

-------------------------------------------------------------------
--18. What is the daily cardiovascular risk category (Tachycardia, Elevated, Bradycardia, or Normal) 
--for high-risk patients with an HbA1c of 6.4%?
-----------------------------------------------------------------------------------
SELECT
    dg.patient_id,
    dg.hba1c,
    dg.gender,
    date_trunc('day', h.recorded_at)::date AS day_recorded,
CASE
WHEN MAX(h.heart_rate) > 140  THEN 'Tachycardia (Above 140 BPM)'
    WHEN AVG(h.heart_rate) >100 THEN 'Elevated '
        WHEN AVG(h.heart_rate) <60  THEN 'Bradycardia (Below 60 BPM)'
        ELSE  'Normal'
    END AS Heart_Category
FROM clean.demography dg
INNER JOIN clean.hr h ON dg.patient_id = h.patient_id
WHERE dg.hba1c >= 6.4
GROUP BY dg.patient_id, dg.hba1c, dg.gender, day_recorded
ORDER BY dg.hba1c DESC, dg.patient_id, day_recorded;


---------------------------------------------------------------------------------------
--19.A data validation query to detect sensor malfunctions or detachment events. Identify all rows in the temperature and hr tables where a patient's skin temperature dropped below 32 degree Celsius while their heart rate simultaneously registered above 100 BPM. 
--Return the patient ID, timestamp, and the anomalous values.
------------------------------------------------------------------------------------
SELECT
t.patient_id,
t.recorded_at,
t.temperature_c,
h.heart_rate
FROM clean.temperature t
INNER JOIN clean.hr h
ON t.patient_id = h.patient_id
AND t.recorded_at = h.recorded_at
WHERE t.temperature_c < 32.0
AND h.heart_rate > 100
ORDER BY t.patient_id, t.recorded_at;


--------------------------------------------------------------------------------------------------------------
--20. Which patients logged the most meals and how does their 
--average glucose compare to patients who logged fewer meals?
-----------------------------------------------------------------------------------

SELECT f.patient_id,
COUNT(f.meal_id) AS total_meals_logged,
ROUND(AVG(d.glucose_mg_dl), 2) AS avg_glucose,
ROUND(SUM(f.total_carb_g), 2) AS total_carbs_consumed
FROM clean.foodlog f
JOIN clean.dexcom d ON d.patient_id = f.patient_id
GROUP BY f.patient_id
ORDER BY total_meals_logged DESC;

-----------------------------------------------------------------------











