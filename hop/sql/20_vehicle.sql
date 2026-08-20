-- STEP 2: one row per PLATE becomes one row per VEHICLE.
--
-- This is the de-duplication that pipeline 10 does with SortRows +
-- FieldsChangeSequence + FilterRows, and the whole argument for the staging
-- path is visible in the difference: there, the grouping is an emergent property
-- of rows arriving in the right order, and unsorted input silently produces
-- wrong plate numbers instead of an error. Here it is one analytic function
-- that cannot be fed in the wrong order because it does its own ordering.
--
--   ROW_NUMBER() OVER (PARTITION BY base VIN ORDER BY full VIN)
--
-- The un-suffixed row sorts first, so plate_seq = 1 is the vehicle and every
-- other row in the group is one of its extra registrations. ORDER BY on the FULL
-- VIN is load-bearing - it is what makes ...0001 come before ...00011.
--
-- The powertrain cascade (VIN rule -> fuel text -> UN) is inlined below rather
-- than living in a script. It is the same rule; CASE is just where SQL keeps it.
--
-- Note on /*+ APPEND */: Oracle silently ignores the hint on a table with
-- enabled foreign keys, so this insert is conventional-path. That is a real
-- production limit, not an oversight - a full-volume load disables the FKs,
-- loads direct-path, then re-enables them with NOVALIDATE (or validates in
-- parallel). Left in place because it costs nothing and documents the intent.

INSERT /*+ APPEND */ INTO pocapp.vehicle (
  source_isn, vin, owner_national_id, make, model, color, year_built,
  source_vehicle_type, vehicle_type_code,
  source_fuel_desc, powertrain_code, powertrain_source
)
WITH ranked AS (
  SELECT s.isn,
         s.personnel_id,
         s.make,
         s.model,
         s.color,
         s.year_built,
         s.veh_type,
         s.fuel_desc,
         SUBSTR(s.vin, 1, 17) AS vin_base,
         ROW_NUMBER() OVER (PARTITION BY SUBSTR(s.vin, 1, 17)
                                ORDER BY s.vin) AS plate_seq
    FROM pocapp.stg_vehicle s
),
base AS (
  SELECT * FROM ranked WHERE plate_seq = 1
),
-- The VIN decode table, joined rather than queried once per row. Eight rules
-- and a LIKE: the same lookup the DBJoin transform performs, except that the
-- DBJoin performs it as a round trip to Oracle FOR EVERY SOURCE ROW.
vin_rule AS (
  SELECT b.isn,
         r.powertrain_code,
         ROW_NUMBER() OVER (PARTITION BY b.isn
                                ORDER BY r.priority, r.rule_id) AS rn
    FROM base b
    JOIN pocapp.vin_powertrain_rule r
      ON b.vin_base LIKE r.vin_pattern
),
derived AS (
  SELECT b.isn,
         b.vin_base,
         b.personnel_id,
         b.make,
         b.model,
         b.color,
         b.year_built,
         b.veh_type,
         b.fuel_desc,
         vr.powertrain_code AS rule_powertrain,
         -- Free text, thirty years of it, reduced to letters so that 'ELEC.',
         -- 'N/A' and 'HEV SELF CHG' all become matchable.
         --
         -- ORDER MATTERS and it is the easiest mistake in the whole migration:
         -- 'PLUG-IN HYBRID' contains 'HYBRID'. Test plug-in FIRST or every PHEV
         -- silently becomes an HEV - a wrong answer that reconciles perfectly,
         -- because no row count changes.
         CASE
           WHEN INSTR(letters, 'PLUG') > 0
             OR INSTR(letters, 'PHEV') > 0     THEN 'PHEV'
           WHEN INSTR(letters, 'HYB')  > 0
             OR INSTR(letters, 'HEV')  > 0     THEN 'HEV'
           WHEN INSTR(letters, 'ELEC') > 0
             OR INSTR(letters, 'BATTERY') > 0
             OR letters = 'EV'                 THEN 'EV'
           WHEN INSTR(letters, 'PETROL') > 0
             OR INSTR(letters, 'GASOLINE') > 0
             OR INSTR(letters, 'BENZIN') > 0   THEN 'PETROL'
           ELSE NULL
         END AS desc_powertrain
    FROM (SELECT b.*,
                 REGEXP_REPLACE(UPPER(NVL(b.fuel_desc, ' ')), '[^A-Z]', '') AS letters
            FROM base b) b
    LEFT JOIN vin_rule vr
      ON vr.isn = b.isn
     AND vr.rn  = 1
)
SELECT d.isn,
       d.vin_base,
       d.personnel_id,
       d.make,
       d.model,
       d.color,
       TO_NUMBER(d.year_built),
       d.veh_type,
       -- An unmapped legacy code is NOT an error: it lands on 'UN' and stays
       -- visible in source_vehicle_type.
       NVL(m.type_code, 'UN'),
       d.fuel_desc,
       -- The cascade: the manufacturer stamped the VIN, a clerk typed the text.
       COALESCE(d.rule_powertrain, d.desc_powertrain, 'UN'),
       CASE
         WHEN d.rule_powertrain IS NOT NULL THEN
           CASE WHEN d.desc_powertrain IS NOT NULL
                 AND d.desc_powertrain <> d.rule_powertrain
                THEN 'VIN_RULE_CONFLICT'
                ELSE 'VIN_RULE'
           END
         WHEN d.desc_powertrain IS NOT NULL THEN 'FUEL_DESC'
         ELSE 'UNKNOWN'
       END
  FROM derived d
  LEFT JOIN pocapp.vehicle_type_map m
    ON m.source_type = d.veh_type;

COMMIT;
