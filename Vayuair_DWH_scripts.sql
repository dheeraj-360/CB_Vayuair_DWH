-- ============================================================
-- CREATING NEW DATABASE
-- ============================================================
CREATE DATABASE VayuAir;
USE VayuAir;

SELECT 'bronze_airports' AS table_name, COUNT(*) AS rows FROM bronze_airports
UNION ALL SELECT 'bronze_aircraft', COUNT(*) FROM bronze_aircraft
UNION ALL SELECT 'bronze_passengers', COUNT(*) FROM bronze_passengers
UNION ALL SELECT 'bronze_flights', COUNT(*) FROM bronze_flights
UNION ALL SELECT 'bronze_bookings', COUNT(*) FROM bronze_bookings
UNION ALL SELECT 'stg_passenger_updates', COUNT(*) FROM stg_passenger_updates;

-- ============================================================
-- TASK 1: Grain statement + column classification (fact_bookings)
-- ============================================================
-- GRAIN:
-- One row in fact_bookings represents one ticket booked (one row per booking_id
-- in bronze_bookings). Each row is a single passenger's single booking on a
-- single flight. booking_id is unique per row - no fan-out.

-- COLUMN CLASSIFICATION (bronze_bookings joined to bronze_flights)
-- booking_id              | bronze_bookings   | Dimension key (grain key / degenerate dimension)
-- passenger_id            | bronze_bookings   | Dimension key -> dim_passenger
-- flight_id               | bronze_bookings   | Dimension key -> dim_flight
-- booking_date            | bronze_bookings   | Dimension key -> dim_date (role: booked)
-- travel_date             | bronze_bookings   | Dimension key -> dim_date (role: travelled)
-- fare_class              | bronze_bookings   | Dimension key (degenerate dimension)
-- booking_status          | bronze_bookings   | Dimension key (degenerate dimension)
-- fare_amount             | bronze_bookings   | Measure
-- tax_amount              | bronze_bookings   | Measure
-- miles_earned            | bronze_bookings   | Measure
-- flight_number           | bronze_flights    | Dimension attribute (belongs to dim_flight)
-- origin_airport_code     | bronze_flights    | Dimension key -> dim_airport (role: origin)
-- dest_airport_code       | bronze_flights    | Dimension key -> dim_airport (role: destination)
-- aircraft_code           | bronze_flights    | Dimension key -> dim_aircraft
-- flight_date             | bronze_flights    | Dimension attribute (redundant with travel_date --
--                                               travel_date drives the fact's date key)

-- ADDITIVITY NOTE:
-- fare_amount, tax_amount, and miles_earned are additive -- safe to SUM across
-- any dimension (passenger, route, fare class, time). A non-additive example:
-- load factor (seats sold / seat capacity) -- summing this ratio across flights
-- or time produces a meaningless number and must instead be recalculated from
-- its components.

-- ============================================================
-- TASK 2: dw schema + star schema DDL
-- ============================================================
GO
-- CREATE SCHEMA vayuair_dw;

CREATE TABLE vayuair_dw.dim_aircraft (
    aircraft_key    INT IDENTITY(1,1) PRIMARY KEY,
    aircraft_code   VARCHAR(20) NOT NULL UNIQUE,
    model           VARCHAR(50) NOT NULL,
    manufacturer    VARCHAR(50) NOT NULL,
    seat_capacity   INT NOT NULL
);

CREATE TABLE vayuair_dw.dim_airport (
    airport_key    INT IDENTITY(1,1) PRIMARY KEY,
    airport_code   CHAR(3) NOT NULL UNIQUE,
    airport_name   VARCHAR(100) NOT NULL,
    city           VARCHAR(50) NOT NULL,
    country        VARCHAR(50) NOT NULL,
    region         VARCHAR(50) NOT NULL
);

CREATE TABLE vayuair_dw.dim_flight (
    flight_key            INT IDENTITY(1,1) PRIMARY KEY,
    flight_id             INT NOT NULL UNIQUE,
    flight_number         VARCHAR(20) NOT NULL,
    origin_airport_key    INT NOT NULL,
    dest_airport_key      INT NOT NULL,
    aircraft_key          INT NOT NULL,
    flight_date           DATE NOT NULL,
    CONSTRAINT FK_flight_origin FOREIGN KEY (origin_airport_key)
        REFERENCES vayuair_dw.dim_airport(airport_key),
    CONSTRAINT FK_flight_dest FOREIGN KEY (dest_airport_key)
        REFERENCES vayuair_dw.dim_airport(airport_key),
    CONSTRAINT FK_flight_aircraft FOREIGN KEY (aircraft_key)
        REFERENCES vayuair_dw.dim_aircraft(aircraft_key)
);

CREATE TABLE vayuair_dw.dim_passenger (
    passenger_key         INT IDENTITY(1,1) PRIMARY KEY,
    passenger_id          INT NOT NULL,
    passenger_name        VARCHAR(100) NOT NULL,
    home_airport_key      INT NOT NULL,
    frequent_flyer_tier   VARCHAR(20) NOT NULL,
    signup_date           DATE NOT NULL,
    effective_from        DATE NOT NULL,
    effective_to          DATE NULL,
    is_current            BIT NOT NULL,
    CONSTRAINT FK_passenger_airport FOREIGN KEY (home_airport_key)
        REFERENCES vayuair_dw.dim_airport(airport_key)
);

CREATE TABLE vayuair_dw.dim_date (
    date_key      INT PRIMARY KEY,
    full_date     DATE NOT NULL UNIQUE,
    year          INT NOT NULL,
    month         INT NOT NULL,
    quarter       INT NOT NULL,
    day_name      VARCHAR(10) NOT NULL,
    is_weekday    BIT NOT NULL
);

CREATE TABLE vayuair_dw.FactTicketSales (
    booking_id           INT NOT NULL PRIMARY KEY,
    passenger_key        INT NOT NULL,
    flight_key           INT NOT NULL,
    booking_date_key     INT NOT NULL,
    travel_date_key      INT NOT NULL,
    fare_class           VARCHAR(20) NOT NULL,
    booking_status       VARCHAR(20) NOT NULL,
    fare_amount          DECIMAL(10,2) NOT NULL,
    tax_amount           DECIMAL(10,2) NOT NULL,
    miles_earned         INT NOT NULL,
    CONSTRAINT FK_fact_passenger FOREIGN KEY (passenger_key)
        REFERENCES vayuair_dw.dim_passenger(passenger_key),
    CONSTRAINT FK_fact_flight FOREIGN KEY (flight_key)
        REFERENCES vayuair_dw.dim_flight(flight_key),
    CONSTRAINT FK_fact_booking_date FOREIGN KEY (booking_date_key)
        REFERENCES vayuair_dw.dim_date(date_key),
    CONSTRAINT FK_fact_travel_date FOREIGN KEY (travel_date_key)
        REFERENCES vayuair_dw.dim_date(date_key)
);

-- ============================================================
-- TASK 3: Load dimensions and fact
-- ============================================================

INSERT INTO vayuair_dw.dim_aircraft (aircraft_code, model, manufacturer, seat_capacity)
SELECT aircraft_code, model, manufacturer, seat_capacity
FROM bronze_aircraft;

INSERT INTO vayuair_dw.dim_airport (airport_code, airport_name, city, country, region)
SELECT airport_code, airport_name, city, country, region
FROM bronze_airports;

INSERT INTO vayuair_dw.dim_flight (flight_id, flight_number, origin_airport_key, dest_airport_key, aircraft_key, flight_date)
SELECT
    bf.flight_id,
    bf.flight_number,
    origin.airport_key,
    dest.airport_key,
    ac.aircraft_key,
    bf.flight_date
FROM bronze_flights bf
JOIN vayuair_dw.dim_airport origin ON bf.origin_airport_code = origin.airport_code
JOIN vayuair_dw.dim_airport dest   ON bf.dest_airport_code = dest.airport_code
JOIN vayuair_dw.dim_aircraft ac    ON bf.aircraft_code = ac.aircraft_code;

-- Checking range for date dimension
SELECT MIN(booking_date) AS min_booking, MAX(booking_date) AS max_booking,
       MIN(travel_date) AS min_travel, MAX(travel_date) AS max_travel
FROM bronze_bookings;

-- Loading dim_date
DECLARE @StartDate DATE = '2024-01-01';
DECLARE @EndDate DATE = '2026-12-31';

;WITH DateSequence AS (
    SELECT @StartDate AS full_date
    UNION ALL
    SELECT DATEADD(DAY, 1, full_date)
    FROM DateSequence
    WHERE full_date < @EndDate
)
INSERT INTO vayuair_dw.dim_date (date_key, full_date, year, month, quarter, day_name, is_weekday)
SELECT
    CAST(FORMAT(full_date, 'yyyyMMdd') AS INT),
    full_date,
    YEAR(full_date),
    MONTH(full_date),
    DATEPART(QUARTER, full_date),
    DATENAME(WEEKDAY, full_date),
    CASE WHEN DATEPART(WEEKDAY, full_date) IN (1, 7) THEN 0 ELSE 1 END
FROM DateSequence
OPTION (MAXRECURSION 1100);

INSERT INTO vayuair_dw.dim_passenger (passenger_id, passenger_name, home_airport_key, frequent_flyer_tier, signup_date, effective_from, effective_to, is_current)
SELECT
    bp.passenger_id,
    bp.passenger_name,
    da.airport_key,
    bp.frequent_flyer_tier,
    bp.signup_date,
    bp.signup_date AS effective_from,
    NULL AS effective_to,
    1 AS is_current
FROM bronze_passengers bp
JOIN vayuair_dw.dim_airport da ON bp.home_airport_code = da.airport_code;

-- ============================================================
-- TASK 4: Snowflake the geography
-- ============================================================

CREATE TABLE vayuair_dw.dim_country (
    country_key   INT IDENTITY(1,1) PRIMARY KEY,
    country_name  VARCHAR(50) NOT NULL UNIQUE,
    region        VARCHAR(50) NOT NULL
);

CREATE TABLE vayuair_dw.dim_city (
    city_key     INT IDENTITY(1,1) PRIMARY KEY,
    city_name    VARCHAR(50) NOT NULL,
    country_key  INT NOT NULL,
    CONSTRAINT FK_city_country FOREIGN KEY (country_key)
        REFERENCES vayuair_dw.dim_country(country_key)
);

INSERT INTO vayuair_dw.dim_country (country_name, region)
SELECT DISTINCT country, region
FROM vayuair_dw.dim_airport;

INSERT INTO vayuair_dw.dim_city (city_name, country_key)
SELECT DISTINCT a.city, dc.country_key
FROM vayuair_dw.dim_airport a
JOIN vayuair_dw.dim_country dc ON a.country = dc.country_name;

CREATE TABLE vayuair_dw.dim_airport_sf (
    airport_key   INT IDENTITY(1,1) PRIMARY KEY,
    airport_code  CHAR(3) NOT NULL UNIQUE,
    airport_name  VARCHAR(100) NOT NULL,
    city_key      INT NOT NULL,
    CONSTRAINT FK_city_airport FOREIGN KEY (city_key)
        REFERENCES vayuair_dw.dim_city(city_key)
);

INSERT INTO vayuair_dw.dim_airport_sf (airport_code, airport_name, city_key)
SELECT
    ba.airport_code,
    ba.airport_name,
    dc.city_key
FROM bronze_airports ba
JOIN vayuair_dw.dim_city dc ON ba.city = dc.city_name;

-- Validation: resolve airport all the way up to country
SELECT
    a.airport_code,
    a.airport_name,
    c.city_name,
    co.country_name,
    co.region
FROM vayuair_dw.dim_airport_sf a
JOIN vayuair_dw.dim_city c ON a.city_key = c.city_key
JOIN vayuair_dw.dim_country co ON c.country_key = co.country_key;

-- TRADE-OFF NOTE:
-- Snowflaking geography into dim_airport -> dim_city -> dim_country removes
-- data redundancy and keeps country/region facts consistent in one place, at
-- the cost of needing two extra joins (instead of reading flat columns
-- directly) whenever a report wants an airport's city or country.

-- ============================================================
-- Loading the fact table
-- ============================================================

INSERT INTO vayuair_dw.FactTicketSales (booking_id, passenger_key, flight_key, booking_date_key, travel_date_key, fare_class, booking_status, fare_amount, tax_amount, miles_earned)
SELECT
    bb.booking_id,
    dp.passenger_key,
    df.flight_key,
    bd.date_key AS booking_dt_key,
    td.date_key AS travel_dt_key,
    bb.fare_class,
    bb.booking_status,
    bb.fare_amount,
    bb.tax_amount,
    bb.miles_earned
FROM bronze_bookings bb
JOIN vayuair_dw.dim_passenger dp ON bb.passenger_id = dp.passenger_id
JOIN vayuair_dw.dim_flight df    ON bb.flight_id = df.flight_id
JOIN vayuair_dw.dim_date bd      ON bb.booking_date = bd.full_date
JOIN vayuair_dw.dim_date td      ON bb.travel_date = td.full_date;

-- ============================================================
-- TASK 5: SCD Type 2 for dim_passenger
-- ============================================================

SELECT
    s.passenger_id,
    s.passenger_name,
    s.home_airport_code,
    a.airport_key AS home_airport_key,
    TRIM(s.frequent_flyer_tier) AS frequent_flyer_tier
INTO vayuair_dw.staging_passenger_upd
FROM stg_passenger_updates s
INNER JOIN vayuair_dw.dim_airport a ON s.home_airport_code = a.airport_code;

SELECT * INTO vayuair_dw.dim_passenger_scd_typ2 FROM vayuair_dw.dim_passenger;

-- STEP 1 -- MERGE: expire the row whose attribute changed
MERGE INTO vayuair_dw.dim_passenger_scd_typ2 AS tgt
USING vayuair_dw.staging_passenger_upd AS src
    ON tgt.passenger_id = src.passenger_id AND tgt.is_current = 1
WHEN MATCHED AND (tgt.home_airport_key <> src.home_airport_key
                   OR tgt.frequent_flyer_tier <> src.frequent_flyer_tier) THEN
    UPDATE SET tgt.is_current = 0, tgt.effective_to = CAST(GETDATE() AS DATE)
WHEN NOT MATCHED BY TARGET THEN
    INSERT (passenger_id, passenger_name, home_airport_key, frequent_flyer_tier, signup_date, effective_from, effective_to, is_current)
    VALUES (src.passenger_id, src.passenger_name, src.home_airport_key, src.frequent_flyer_tier,
            CAST(GETDATE() AS DATE), CAST(GETDATE() AS DATE), NULL, 1);
GO

-- STEP 2 -- INSERT the new current version for every passenger just expired above
INSERT INTO vayuair_dw.dim_passenger_scd_typ2
    (passenger_id, passenger_name, home_airport_key, frequent_flyer_tier, signup_date, effective_from, effective_to, is_current)
SELECT
    src.passenger_id, src.passenger_name, src.home_airport_key, src.frequent_flyer_tier,
    CAST(GETDATE() AS DATE), CAST(GETDATE() AS DATE), NULL, 1
FROM vayuair_dw.staging_passenger_upd AS src
JOIN vayuair_dw.dim_passenger_scd_typ2 AS expired
    ON expired.passenger_id = src.passenger_id
    AND expired.is_current = 0
    AND expired.effective_to = CAST(GETDATE() AS DATE)
WHERE NOT EXISTS (
    SELECT 1 FROM vayuair_dw.dim_passenger_scd_typ2 cur
    WHERE cur.passenger_id = src.passenger_id AND cur.is_current = 1
);
GO

SELECT * FROM vayuair_dw.dim_passenger_scd_typ2 ORDER BY passenger_id;

-- ============================================================
-- TASK 6: Partitioning FactTicketSales
-- ============================================================

CREATE PARTITION FUNCTION PF_TravelDate (INT)
AS RANGE LEFT FOR VALUES (
    20240131, 20240229, 20240331, 20240430, 20240531, 20240630,
    20240731, 20240831, 20240930, 20241031, 20241130, 20241231,
    20250131, 20250228, 20250331, 20250430, 20250531, 20250630,
    20250731, 20250831, 20250930, 20251031, 20251130, 20251231,
    20260131, 20260229, 20260331
);

CREATE PARTITION SCHEME PS_TravelDate
AS PARTITION PF_TravelDate
ALL TO ([PRIMARY]);

-- Confirm existing PK is the clustered index before rebuilding
SELECT i.name AS IndexName, i.type_desc AS IndexType, i.is_primary_key
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID('vayuair_dw.FactTicketSales');

-- Drop the non-partitioned clustered PK, rebuild it on the partition scheme
ALTER TABLE vayuair_dw.FactTicketSales DROP CONSTRAINT PK__FactTick__5DE3A5B1C1404803;

ALTER TABLE vayuair_dw.FactTicketSales
ADD CONSTRAINT PK_FactTicketSales PRIMARY KEY CLUSTERED (booking_id, travel_date_key)
ON PS_TravelDate(travel_date_key);

-- Confirm the fact table is now on the scheme, with rows distributed by month
SELECT
    t.name AS TableName,
    ps.name AS PartitionScheme,
    p.partition_number,
    p.rows
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id <= 1
JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
WHERE t.name = 'FactTicketSales'
ORDER BY p.partition_number;

-- Query A: filters on the partition key
SELECT SUM(fare_amount)
FROM vayuair_dw.FactTicketSales
WHERE travel_date_key BETWEEN 20250301 AND 20250331;

-- Query B: filters on a non-partition column
SELECT SUM(fare_amount)
FROM vayuair_dw.FactTicketSales
WHERE fare_class = 'Business';