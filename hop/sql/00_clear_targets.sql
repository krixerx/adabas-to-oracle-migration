-- Empty the migrated target tables, child-first.
--
-- THE ONE SOURCE OF TRUTH for what gets cleared and in what order. Three
-- callers share it: scripts\clear-tables.ps1, and the opening action of both
-- migration workflows. It used to live only in the script, which meant a
-- workflow run straight from the Hop GUI loaded into tables that still held the
-- previous run - and failed on the first insert with
--     ORA-00001: unique constraint (POCAPP.UQ_VEHICLE_ISN) violated
-- which reads like a data problem and is not one. A workflow should carry its
-- own preconditions; migrate.cmd calling the script first is then just belt and
-- braces, since a DELETE against empty tables costs nothing.
--
-- DELETE, not TRUNCATE. Oracle raises ORA-02266 on TRUNCATE of a table that an
-- enabled foreign key references, even when the child tables are empty.
--
-- Child-first, so the FKs stay enabled throughout. Nothing here is a lookup or
-- seed table: CODE_LOOKUP, VEHICLE_TYPE, VEHICLE_TYPE_MAP, POWERTRAIN_TYPE and
-- VIN_POWERTRAIN_RULE are reference data and are never cleared by a reload.
--
-- No EXIT at the end: Hop sends this file statement by statement over JDBC, and
-- EXIT is a sqlplus command, not SQL. clear-tables.ps1 appends its own.

DELETE FROM pocapp.traffic_fine_offence;
DELETE FROM pocapp.traffic_fine_payment;
DELETE FROM pocapp.traffic_fine;
DELETE FROM pocapp.vehicle_plate;
DELETE FROM pocapp.migration_reject;
DELETE FROM pocapp.vehicle;

COMMIT;
