-- Staging layer: the flat files land here UNCHANGED, and the redesign happens
-- afterwards in set-based SQL (sql/*.sql).
--
-- WHY THIS EXISTS. The Hop pipelines (10..50) reshape row by row, in a JVM, one
-- record at a time: readable, debuggable, and exactly right for a lab. It is the
-- wrong engine at real volume, because every move the redesign actually
-- makes is a SET operation:
--     one row per plate -> one vehicle    = ROW_NUMBER() OVER (PARTITION BY ...)
--     fine names a plate -> find the car  = a join
--     house codes -> standard codes       = a join
--     one file -> six tables              = six INSERT ... SELECT
-- Landing raw and reshaping in the database lets Oracle do those as sets, next
-- to the data, instead of dragging every row through a network socket twice.
--
-- Two rules for this file:
--   1. STAGING MIRRORS THE FILE, not the target. Same columns, same order, same
--      names as FLAT_FILE_CONTRACT.md. No conversion, no cleverness.
--   2. Everything the contract writes as text stays VARCHAR2 here - dates as
--      YYYYMMDD strings, amounts as text. Converting on the way IN would put a
--      transformation into the load step, which is the thing this design exists
--      to stop doing. TO_DATE and TO_NUMBER happen in the transform.
--
-- Idempotent: runs automatically on a fresh container (oracle-init) and can be
-- re-applied to an existing lab with scripts\setup-staging.ps1.

ALTER SESSION SET CONTAINER = FREEPDB1;

-- The contract CSVs, bind-mounted read-only into the container by
-- docker-compose (./data -> /opt/oracle/a2o-data). Oracle reads them in place;
-- nothing copies the files anywhere first.
CREATE OR REPLACE DIRECTORY a2o_data AS '/opt/oracle/a2o-data';
GRANT READ ON DIRECTORY a2o_data TO pocapp;

-- Re-runnable: drop whatever a previous run left. Nothing references staging -
-- it carries no keys, no FKs and no opinions - so order does not matter.
BEGIN
  FOR t IN (SELECT table_name FROM all_tables
             WHERE owner = 'POCAPP'
               AND SUBSTR(table_name, 1, 4) IN ('STG_', 'EXT_'))
  LOOP
    EXECUTE IMMEDIATE 'DROP TABLE pocapp.' || t.table_name || ' PURGE';
  END LOOP;
END;
/

-- ---------------------------------------------------------------------------
-- External tables: the CSV read as a table. No load step of its own, no
-- SQL*Loader control file, no copy - a SELECT against these parses the file
-- where it lies.
--
-- REJECT LIMIT 0 on purpose: a row the definition cannot parse stops the load
-- instead of quietly disappearing into a .bad file nobody reads. NOBADFILE and
-- NOLOGFILE because the mount is read-only, and because a silent side file is
-- the wrong failure mode for a migration.
--
-- LIMITATION worth knowing: this parser handles quoted commas but NOT a newline
-- inside a quoted field. The contract permits one (RFC 4180) and the extract has
-- never produced one. If that ever changes, this is where it breaks - loudly.
-- ---------------------------------------------------------------------------
CREATE TABLE pocapp.ext_vehicle (
  isn           NUMBER,
  plate_no      VARCHAR2(15),
  personnel_id  VARCHAR2(8),
  make          VARCHAR2(30),
  model         VARCHAR2(30),
  color         VARCHAR2(15),
  year_built    VARCHAR2(4),
  vin           VARCHAR2(30),
  veh_type      VARCHAR2(8),
  fuel_desc     VARCHAR2(20),
  plate_expiry  VARCHAR2(8)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY a2o_data
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY NEWLINE
    CHARACTERSET AL32UTF8
    SKIP 1
    NOLOGFILE
    NOBADFILE
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
    ( isn, plate_no, personnel_id, make, model, color, year_built,
      vin, veh_type, fuel_desc, plate_expiry )
  )
  LOCATION ('vehicles.csv')
)
REJECT LIMIT 0;

CREATE TABLE pocapp.ext_traffic_fine (
  isn                   NUMBER,
  fine_no               VARCHAR2(10),
  plate_no              VARCHAR2(15),
  offence_yyyymmdd      VARCHAR2(8),
  location              VARCHAR2(30),
  amount                VARCHAR2(15),
  status                VARCHAR2(1),
  offender_national_id  VARCHAR2(8)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY a2o_data
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY NEWLINE
    CHARACTERSET AL32UTF8
    SKIP 1
    NOLOGFILE
    NOBADFILE
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
    ( isn, fine_no, plate_no, offence_yyyymmdd, location, amount,
      status, offender_national_id )
  )
  LOCATION ('traffic_fines.csv')
)
REJECT LIMIT 0;

CREATE TABLE pocapp.ext_fine_offence (
  parent_key        NUMBER,
  occurrence_index  NUMBER,
  offence_code      VARCHAR2(4)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY a2o_data
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY NEWLINE
    CHARACTERSET AL32UTF8
    SKIP 1
    NOLOGFILE
    NOBADFILE
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
    ( parent_key, occurrence_index, offence_code )
  )
  LOCATION ('traffic_fine_offences.csv')
)
REJECT LIMIT 0;

CREATE TABLE pocapp.ext_fine_payment (
  parent_key        NUMBER,
  occurrence_index  NUMBER,
  paid_yyyymmdd     VARCHAR2(8),
  paid_amount       VARCHAR2(15),
  payment_method    VARCHAR2(2)
)
ORGANIZATION EXTERNAL (
  TYPE ORACLE_LOADER
  DEFAULT DIRECTORY a2o_data
  ACCESS PARAMETERS (
    RECORDS DELIMITED BY NEWLINE
    CHARACTERSET AL32UTF8
    SKIP 1
    NOLOGFILE
    NOBADFILE
    FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
    MISSING FIELD VALUES ARE NULL
    ( parent_key, occurrence_index, paid_yyyymmdd, paid_amount, payment_method )
  )
  LOCATION ('traffic_fine_payments.csv')
)
REJECT LIMIT 0;

-- ---------------------------------------------------------------------------
-- Staging tables: heap copies of the external tables.
--
-- Why copy at all rather than transform straight off the external table: the
-- vehicle transform reads the source three times (rank, load, reject), and an
-- external table re-parses the entire CSV on every scan. Landing once with a
-- direct-path insert and then scanning a heap table is what makes the rest of
-- this cheap. It is also the restart point - if a transform step fails, the
-- extract does not have to be repeated.
--
-- NOLOGGING because staging is disposable: it can always be rebuilt from the
-- file, so paying redo to protect it is paying for nothing.
-- ---------------------------------------------------------------------------
CREATE TABLE pocapp.stg_vehicle (
  isn           NUMBER,
  plate_no      VARCHAR2(15),
  personnel_id  VARCHAR2(8),
  make          VARCHAR2(30),
  model         VARCHAR2(30),
  color         VARCHAR2(15),
  year_built    VARCHAR2(4),
  vin           VARCHAR2(30),
  veh_type      VARCHAR2(8),
  fuel_desc     VARCHAR2(20),
  plate_expiry  VARCHAR2(8)
) NOLOGGING;

CREATE TABLE pocapp.stg_traffic_fine (
  isn                   NUMBER,
  fine_no               VARCHAR2(10),
  plate_no              VARCHAR2(15),
  offence_yyyymmdd      VARCHAR2(8),
  location              VARCHAR2(30),
  amount                VARCHAR2(15),
  status                VARCHAR2(1),
  offender_national_id  VARCHAR2(8)
) NOLOGGING;

CREATE TABLE pocapp.stg_fine_offence (
  parent_key        NUMBER,
  occurrence_index  NUMBER,
  offence_code      VARCHAR2(4)
) NOLOGGING;

CREATE TABLE pocapp.stg_fine_payment (
  parent_key        NUMBER,
  occurrence_index  NUMBER,
  paid_yyyymmdd     VARCHAR2(8),
  paid_amount       VARCHAR2(15),
  payment_method    VARCHAR2(2)
) NOLOGGING;

EXIT;
