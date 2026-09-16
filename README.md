# Vayu Air - Warehouse Design Challenge

Data Engineering Bootcamp (Codebasics) — Session 3: Data Modeling & Warehouse Engineering

## Background

Vayu Air is a fast-growing airline whose analytics requests were hitting its live transactional
database directly, producing slow, inconsistent reports. This project models the raw bronze
source tables into a proper `dw` star schema on SQL Server — designed and built end-to-end in
T-SQL, using SSMS.

## What's in this repo

| File | Description |
|---|---|
| `VayuAir_DWH_scripts.sql` | Full T-SQL script — schema, DDL, loads, SCD2, snowflake, partitioning |
| `VayuAir_DWH_Report.docx` | Written submission — medallion mapping, data contract, execution plan evidence |
| `query_a_partition_prune.png` | Execution plan: query filtered on the partition key |
| `query_b_full_scan.png` | Execution plan: query filtered on a non-partition column |

## Tasks completed

1. **Grain & column classification** — declared `FactTicketSales`'s grain as one row per
   ticket booked; classified every candidate column as a dimension key or measure; confirmed
   `fare_amount`, `tax_amount`, and `miles_earned` as additive measures.
2. **Star schema DDL** — built the `dw` schema with `FactTicketSales` plus `dim_aircraft`,
   `dim_airport`, `dim_flight`, `dim_date`, and `dim_passenger`, each with a surrogate primary
   key and its business key retained.
3. **Load the warehouse** — populated every dimension and the fact table from the bronze
   sources via lookup joins; verified the fact row count matched `bronze_bookings` exactly with
   zero orphaned foreign keys.
4. **Snowflake the geography** — normalized `dim_airport` into `dim_airport` → `dim_city` →
   `dim_country`, verified an airport resolves all the way up to its country.
5. **SCD Type 2 on `dim_passenger`** — rebuilt the dimension with `effective_from`,
   `effective_to`, and `is_current`; applied `stg_passenger_updates` using the expire-then-insert
   pattern, correctly producing two versions for changed passengers and a single current row for
   new ones.
6. **Partition `FactTicketSales`** — created a partition function and scheme on
   `travel_date_key` (monthly boundaries), rebuilt the clustered index on the scheme, and proved
   partition elimination with actual execution plans:

   | Metric | Filter on partition key | Filter on non-partition column |
   |---|---|---|
   | Actual Partition Count | **1** | **28** |
   | Rows read | 2,745 | 40,000 |

   Filtering on `travel_date_key` lets SQL Server prune to the single relevant partition;
   filtering on `fare_class` has no relationship to the partitioning scheme, forcing a full
   scan across all 28 partitions.
7. **Curate** — mapped every table in the pipeline to a medallion layer (bronze/silver/gold)
   with a one-line reason each, and wrote a data contract for the `bronze_bookings` feed
   (schema, allowed values, freshness SLA, owner, and breaking vs. non-breaking change examples).

See `VayuAir_DWH_Report.docx` for the full write-up, including both execution plan
screenshots and complete reasoning for every design decision.
