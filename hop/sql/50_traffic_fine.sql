-- STEP 5: fines, and the cross-file resolution that is the point of them.
--
-- A fine records the PLATE the camera read, never the vehicle. Resolving plate
-- -> vehicle is the migration's job, and it is why the plate table had to be
-- built first: a fine written against '344RG94-2' belongs to the same car as one
-- written against '344RG94'.
--
-- Two things worth reading carefully:
--
-- 1. The plate set is GROUPED before the join. plate_no is not unique in the
--    target model - nothing declares it to be - so joining straight to
--    VEHICLE_PLATE would multiply a fine into several rows the moment two
--    vehicles ever shared a plate number. MIN(vehicle_id) picks deterministically
--    and, more importantly, guarantees one row out per row in. The DBLookup
--    transform hides this decision by silently returning its first hit.
--
-- 2. A plate that matches nothing is NOT an error and NOT a reason to drop the
--    fine: foreign and long-deregistered vehicles are normal. The fine loads
--    with vehicle_id NULL and step 6 records it, so it is visible rather than
--    merely absent.

INSERT INTO pocapp.traffic_fine (
  source_isn, fine_no, vehicle_id, plate_no, offence_date, location,
  amount, status_code, status, offender_national_id
)
WITH plate AS (
  SELECT plate_no,
         MIN(vehicle_id) AS vehicle_id
    FROM pocapp.vehicle_plate
   WHERE plate_no IS NOT NULL
   GROUP BY plate_no
)
SELECT s.isn,
       s.fine_no,
       p.vehicle_id,
       s.plate_no,
       TO_DATE(s.offence_yyyymmdd, 'YYYYMMDD'),
       s.location,
       TO_NUMBER(s.amount),
       s.status,
       -- Code resolved to its description, and the code kept beside it. An
       -- unknown code is not an error either - it reads 'Unknown' and the raw
       -- code is still there to argue with.
       NVL(c.description, 'Unknown'),
       s.offender_national_id
  FROM pocapp.stg_traffic_fine s
  LEFT JOIN plate p
    ON p.plate_no = s.plate_no
  LEFT JOIN pocapp.code_lookup c
    ON c.domain = 'FINE_STATUS'
   AND c.code   = s.status;

COMMIT;
