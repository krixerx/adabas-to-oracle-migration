-- Empty the migrated target tables.
--
-- THE ONE SOURCE OF TRUTH for what gets cleared and in what order. Three
-- callers share it: scripts\clear-tables.ps1, and the opening action of both
-- migration workflows. It used to live only in the script, which meant a
-- workflow run straight from the Hop GUI loaded into tables that still held the
-- previous run - and failed on the first insert with
--     ORA-00001: unique constraint (POCAPP.UQ_VEHICLE_ISN) violated
-- which reads like a data problem and is not one. A workflow should carry its
-- own preconditions; migrate.cmd calling the script first is then just belt and
-- braces, since a clear of empty tables costs nothing.
--
-- TRUNCATE, not DELETE, and that is a change made 2026-09-21 after a 100,000
-- vehicle reload spent TWENTY MINUTES in this step. Two reasons, both of which
-- only appear at volume:
--   * DELETE of a VEHICLE row makes Oracle prove no TRAFFIC_FINE references it.
--     An index on traffic_fine(vehicle_id) now exists (01_schema.sql), but the
--     delete was full-scanning that table once per row - 320 million block
--     reads, against a table that was ALREADY EMPTY, because
--   * DELETE leaves the high-water mark where the previous load put it. The
--     next run then re-scans all that empty space, and the run after that.
--     TRUNCATE resets it, which is also why the following load starts clean.
-- DELETE also writes every removed row to undo and redo; TRUNCATE writes almost
-- nothing, which on the lab's 10 MB redo logs is the difference between a
-- hundred log switches and none.
--
-- The FKs have to come down for it: Oracle raises ORA-02266 on TRUNCATE of a
-- table an enabled foreign key references, even when the child is empty. That
-- is the whole reason this file used DELETE before. Only the four constraints
-- that POINT AT a table being truncated are touched, and they go straight back
-- up at the end - ENABLE validates, which is instant against empty tables, so
-- the load that follows is enforced exactly as before.
--
-- ⚠️ If a statement below fails between the DISABLE and the ENABLE block, the
-- constraints are left DISABLED and the next load would not be checked. Hop
-- aborts the workflow on a failed SQL action, so the load does not silently
-- happen anyway - but if you ever see a target table accepting an orphan, this
-- is the first place to look:
--     SELECT constraint_name, status FROM user_constraints
--      WHERE constraint_type = 'R' AND status = 'DISABLED';
--
-- Nothing here is a lookup or seed table: CODE_LOOKUP, VEHICLE_TYPE,
-- VEHICLE_TYPE_MAP, POWERTRAIN_TYPE and VIN_POWERTRAIN_RULE are reference data
-- and are never cleared by a reload.
--
-- No EXIT at the end: Hop sends this file statement by statement over JDBC, and
-- EXIT is a sqlplus command, not SQL. clear-tables.ps1 appends its own. No
-- COMMIT either - every statement here is DDL and commits itself.

ALTER TABLE pocapp.vehicle_plate         DISABLE CONSTRAINT fk_vehicle_plate;
ALTER TABLE pocapp.traffic_fine          DISABLE CONSTRAINT fk_traffic_fine_veh;
ALTER TABLE pocapp.traffic_fine_offence  DISABLE CONSTRAINT fk_fine_offence;
ALTER TABLE pocapp.traffic_fine_payment  DISABLE CONSTRAINT fk_fine_payment;

TRUNCATE TABLE pocapp.traffic_fine_offence;
TRUNCATE TABLE pocapp.traffic_fine_payment;
TRUNCATE TABLE pocapp.traffic_fine;
TRUNCATE TABLE pocapp.vehicle_plate;
TRUNCATE TABLE pocapp.migration_reject;
TRUNCATE TABLE pocapp.vehicle;

ALTER TABLE pocapp.vehicle_plate         ENABLE CONSTRAINT fk_vehicle_plate;
ALTER TABLE pocapp.traffic_fine          ENABLE CONSTRAINT fk_traffic_fine_veh;
ALTER TABLE pocapp.traffic_fine_offence  ENABLE CONSTRAINT fk_fine_offence;
ALTER TABLE pocapp.traffic_fine_payment  ENABLE CONSTRAINT fk_fine_payment;
