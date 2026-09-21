-- STEP 7: the Adabas-shaped part - a multiple-value field and a periodic group
-- become child tables.
--
-- The flattening itself already happened, in the extract, where the occurrence
-- semantics live: the contract files carry parent_key (the owning record's ISN)
-- and occurrence_index. What is left here is only the surrogate-key resolution,
-- and that is a join on uq_traffic_fine_isn.
--
-- This is the one part of the redesign that is genuinely 1:1 - one CSV row, one
-- table row - which is why the reconciliation can assert it as a plain count.

INSERT INTO pocapp.traffic_fine_offence (fine_id, seq_no, offence_code, offence_desc)
SELECT f.fine_id,
       o.occurrence_index,
       o.offence_code,
       NVL(c.description, 'Unknown')
  FROM pocapp.stg_fine_offence o
  JOIN pocapp.traffic_fine f
    ON f.source_isn = o.parent_key
  LEFT JOIN pocapp.code_lookup c
    ON c.domain = 'OFFENCE'
   AND c.code   = o.offence_code;

COMMIT;

INSERT INTO pocapp.traffic_fine_payment (fine_id, seq_no, paid_date, paid_amount, method_code, method)
SELECT f.fine_id,
       p.occurrence_index,
       TO_DATE(p.paid_yyyymmdd, 'YYYYMMDD'),
       -- The amount arrives with an explicit decimal point because the extract
       -- applies an edit mask. Adabas stores it packed with no decimal position
       -- of its own, and COMPRESS would have written 2500 for 25.00 - a silent
       -- factor of a hundred that nothing downstream could detect.
       TO_NUMBER(p.paid_amount),
       p.payment_method,
       NVL(c.description, 'Unknown')
  FROM pocapp.stg_fine_payment p
  JOIN pocapp.traffic_fine f
    ON f.source_isn = p.parent_key
  LEFT JOIN pocapp.code_lookup c
    ON c.domain = 'PAY_METHOD'
   AND c.code   = p.payment_method;

COMMIT;
