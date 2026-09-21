-- STEP 6: record the fines whose plate resolved to no vehicle.
--
-- Two very different situations land here and the row has to say which: a
-- foreign or long-deregistered plate that was never in the vehicle file, and a
-- plate this migration itself refused to load as a surplus fourth registration.
-- That second one is a CASCADE - the plate was rejected in step 4, so the fine
-- written against it cannot resolve either - and whoever reads MIGRATION_REJECT
-- cannot tell the two apart from the plate number alone.
--
-- Read from TRAFFIC_FINE rather than from staging: the authority on "did it
-- resolve" is the row that was actually loaded, not a second evaluation of the
-- same condition. Re-deciding it here would be a second implementation to keep
-- in step with the first.

INSERT INTO pocapp.migration_reject (source_file, source_isn, reason, detail)
SELECT 'traffic_fines.csv',
       f.source_isn,
       'plate matches no registered vehicle',
       'fine ' || f.fine_no || ' on plate ' || f.plate_no
  FROM pocapp.traffic_fine f
 WHERE f.vehicle_id IS NULL;

COMMIT;
