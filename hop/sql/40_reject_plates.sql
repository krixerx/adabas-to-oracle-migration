-- STEP 4: the fourth plate on a VIN has nowhere to go in the target model, so
-- it is quarantined rather than dropped.
--
-- "loaded + rejected = rows in the file" is an asserted check, and it only
-- holds because this step exists. A migration that silently drops what does not
-- fit cannot be reconciled - and the row counts would still balance, which is
-- what makes silent drops dangerous rather than merely wrong.
--
-- The reason and detail text match what pipeline 20 writes character for
-- character, so the two paths can be compared row by row and not just counted.

INSERT INTO pocapp.migration_reject (source_file, source_isn, reason, detail)
WITH ranked AS (
  SELECT s.isn,
         s.plate_no,
         s.vin,
         SUBSTR(s.vin, 1, 17) AS vin_base,
         ROW_NUMBER() OVER (PARTITION BY SUBSTR(s.vin, 1, 17)
                                ORDER BY s.vin) AS plate_seq
    FROM pocapp.stg_vehicle s
)
SELECT 'vehicles.csv',
       r.isn,
       'more than 3 plates registered on one VIN',
       -- The VIN alone does not say what was lost here: a REGISTRATION went
       -- missing. Name the plate, the VIN it belonged to and the position it
       -- would have taken.
       'plate ' || r.plate_no ||
       ' (VIN ' || r.vin ||
       ', would have been plate ' || TO_CHAR(r.plate_seq) || ')'
  FROM ranked r
 WHERE r.plate_seq > 3;

COMMIT;
