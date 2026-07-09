# Glycemic-Variability-SQL-Hackathon
SQL Hackathon — Glycemic Variability Analysis using BIG IDEAs Lab Dataset v1.1.2


**Team:** Select Star From Warriors (Team 2)
**Dataset:** BIG IDEAs Lab Glycemic Variability and Wearable Device Data v1.1.2
**Source:** PhysioNet — https://doi.org/10.13026/zthx-5212

## About the Project
Analysis of continuous glucose monitoring, wearable sensor data, and dietary
logs from 16 participants over 8–10 days using PostgreSQL.

## Dataset
- 16 patients monitored with a Dexcom G6 CGM and Empatica E4 wristband
- 7 raw tables — demography, dexcom, hr, eda, ibi, temperature, foodlog
- 36,886 glucose readings · 8.6M heart rate readings after downsampling

## What We Built
- Full ETL pipeline cleaning all 7 raw tables into a structured clean schema
- 65 SQL queries across 3 categories (Simple, Intermediate, Advanced)
- Stored procedures, UDFs, triggers, and recursive CTEs

## Key Findings
- Patients below 70% Time-in-Range showed highest glucose variability (CV%)
- High-carb meals above 60g consistently caused 30+ mg/dL glucose spikes
- Stress signals (EDA + HR) correlated with elevated glucose levels

## Files
| File | Description |
|------|-------------|
| ETL/ETL_Script.sql | Complete data cleaning script |
| Queries/Category1_Simple.sql | 20 simple SELECT queries |
| Queries/Category2_Intermediate.sql | 30 intermediate queries |
| Queries/Category3_Advanced.sql | 15 advanced queries |
| Docs/ | Word documents with reasoning and optimization |
| Presentation/ | PowerPoint slides |

## Team Members
- Sandhya Lomety
- Vishakha Pawar
- Kavita Pakhale
- Lakshmi D Kalavakolanu
- Jidhiya Vijayan

  ## Tools
PostgreSQL · pgAdmin · BIG IDEAs Lab Dataset v1.1.2
