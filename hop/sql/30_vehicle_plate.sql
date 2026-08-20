-- STEP 3: every registration becomes a plate row, hung off the vehicle that
-- step 2 created.
--
-- The same ranking is derived a second time, exactly as pipeline 20 re-derives
-- it. That is deliberate: the rule "base VIN = first 17 characters, ordered by
-- the full VIN" lives in one shape and is applied wherever it is needed, rather
-- than being passed between steps as state.
--
-- The join back to VEHICLE on the base VIN is what resolves the surrogate key.
-- No key cache, no lookup transform, no per-row round trip - uq_vehicle_vin
-- makes it a plain equality join, and it is the reason this design needs no
-- separate source-to-surrogate mapping table.
--
-- plate_seq <= 3 is the target model's limit (ck_vehicle_plate_seq). What falls
-- outside it is not dropped: step 4 quarantines it.

INSERT INTO pocapp.vehicle_plate (
  vehicle_id, plate_seq, plate_no, source_isn, expiry_date
)
WITH ranked AS (
  SELECT s.isn,
         s.plate_no,
         s.plate_expiry,
         SUBSTR(s.vin, 1, 17) AS vin_base,
         ROW_NUMBER() OVER (PARTITION BY SUBSTR(s.vin, 1, 17)
                                ORDER BY s.vin) AS plate_seq
    FROM pocapp.stg_vehicle s
)
SELECT v.vehicle_id,
       r.plate_seq,
       r.plate_no,
       r.isn,
       -- A registration is never deleted, it EXPIRES: empty means still current.
       -- The contract writes an empty field rather than 0 precisely so this does
       -- not need a special case for a date that does not exist.
       TO_DATE(r.plate_expiry, 'YYYYMMDD')
  FROM ranked r
  JOIN pocapp.vehicle v
    ON v.vin = r.vin_base
 WHERE r.plate_seq <= 3;

COMMIT;
