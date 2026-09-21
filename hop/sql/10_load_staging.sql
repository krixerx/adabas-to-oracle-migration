-- STEP 1 of the staging path: land the flat files, unchanged, in the database.
--
-- No transformation happens here on purpose. This step's only job is to get the
-- bytes across the boundary as fast as Oracle can read them; everything that
-- makes the target model different from the source happens in the steps after
-- this one, where it can be expressed as sets.
--
-- Three things are doing the work:
--   TRUNCATE ... DROP STORAGE  - resets the high-water mark, so a re-run does
--                                not scan the space a previous run left behind.
--   INSERT /*+ APPEND */       - direct-path: rows are formatted into fresh
--                                blocks above the high-water mark and written
--                                straight to disk, skipping the buffer cache
--                                and (on a NOLOGGING table) most of the redo.
--   SELECT FROM ext_*          - the CSV parsed in place by ORACLE_LOADER, in
--                                the database, with no client in the middle.
--
-- Direct path into an EMPTY table also gives us table statistics for free:
-- Oracle gathers them online during the load, so the transform steps get a real
-- row count and real column distributions without a DBMS_STATS call.

TRUNCATE TABLE pocapp.stg_vehicle DROP STORAGE;
TRUNCATE TABLE pocapp.stg_traffic_fine DROP STORAGE;
TRUNCATE TABLE pocapp.stg_fine_offence DROP STORAGE;
TRUNCATE TABLE pocapp.stg_fine_payment DROP STORAGE;

INSERT /*+ APPEND */ INTO pocapp.stg_vehicle
SELECT isn, plate_no, personnel_id, make, model, color, year_built,
       vin, veh_type, fuel_desc, plate_expiry
  FROM pocapp.ext_vehicle;

COMMIT;

INSERT /*+ APPEND */ INTO pocapp.stg_traffic_fine
SELECT isn, fine_no, plate_no, offence_yyyymmdd, location, amount,
       status, offender_national_id
  FROM pocapp.ext_traffic_fine;

COMMIT;

INSERT /*+ APPEND */ INTO pocapp.stg_fine_offence
SELECT parent_key, occurrence_index, offence_code
  FROM pocapp.ext_fine_offence;

COMMIT;

INSERT /*+ APPEND */ INTO pocapp.stg_fine_payment
SELECT parent_key, occurrence_index, paid_yyyymmdd, paid_amount, payment_method
  FROM pocapp.ext_fine_payment;

COMMIT;
