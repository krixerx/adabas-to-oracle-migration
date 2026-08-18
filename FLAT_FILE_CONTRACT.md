# Flat-File Contract — extract ↔ mapping interface

The stable interface between the extract stage (Natural programs; or any fallback
extractor) and the Hop mappings. **Any change here is a breaking change** — it is the
artifact production Natural extracts must later reproduce semantically (same columns,
quoting, NULL convention) after EBCDIC→UTF-8 conversion.

## Format rules

- BOM-less UTF-8, comma-delimited CSV, one header row.
- RFC 4180 quoting: fields containing comma/quote/newline are double-quoted; `"` → `""`.
- Empty string = NULL.
- One file per **source shape** (Adabas record type or MU/PE repeating group).
- MU/PE-group files carry `parent_key` (= Adabas ISN of the owning record, `*ISN`)
  and `occurrence_index` (1-based).
- Numeric dates are written as `YYYYMMDD` strings; conversion to a real date is a
  mapping decision and happens in Hop.
- Amounts carry an explicit decimal point (`25.00`). Adabas stores them packed with no
  decimal position of its own, so the extract applies the edit mask — without it
  `COMPRESS` writes `2500` and the value is silently a hundred times too big.
- Alongside the CSVs the extractor reports per-file record counts; the orchestrator
  writes them to `data/manifest.json`.

## Files (this lab scope)

### vehicles.csv  (Adabas file 12 VEHICLES, one row per record — **not** one per vehicle)
| column | source (DDM field) | notes |
|---|---|---|
| isn | *ISN | Adabas ISN |
| plate_no | REG-NUM | the registration plate — same concept and same name as in `traffic_fines.csv` |
| personnel_id | PERSONNEL-ID | the registered owner's national id |
| make | MAKE | |
| model | MODEL | |
| color | COLOR | |
| year_built | YEAR | |
| vin | VIN (BA) | **as stored, suffix and all** — see below |
| veh_type | VEH-TYPE (BB) | the legacy/custom type code, mapped in Hop |
| fuel_desc | FUEL-DESC (BC) | **free text, verbatim** — mixed case and punctuation intact |
| plate_expiry | PLATE-EXPIRY (BD) | numeric YYYYMMDD, **empty when the plate is still current** |

`plate_expiry` exists because **a registration is never deleted — it expires**. The
extract writes an empty field rather than `0` for a current plate: the contract already
says empty = NULL, whereas a literal `0` would have to be special-cased downstream into a
date that does not exist. Not to be confused with `DATE-ACQ` (AJ), which is when the
vehicle was *acquired*; the legacy file had no expiry field at all and the lab adds `BD`
with `ADADBM ADD_FIELDS`.

**One row per plate, not per vehicle.** The source has nowhere to record a second
registration plate, so a vehicle with more plates was registered again under the same
VIN with a trailing character appended (`…0000011`, `…0000012`) **and a different
plate number in `plate_no`**. The extract writes the
VIN **exactly as stored** — cutting it to its first 17 characters and grouping is a
mapping decision and lives in the Hop pipelines, not in the extract. Consumers must
therefore expect duplicate vehicles in this file.

`veh_type` values are whatever the legacy application wrote (`SEDAN`, `LORRY`, `MBIKE`,
…) and are **not** guaranteed to exist in the target's mapping table.

`fuel_desc` is free text and is written **exactly as stored** — `PETROL`, `petrol`,
`BENZIN`, `ELEC.`, `PLUG-IN HYBRID`, `HEV SELF CHG`, `N/A`, blank. Normalising it is a
mapping decision (JavaScript, in `10_vehicle.hpl`), not the extract's job. Consumers must
not assume it is upper-case, spelled consistently, in English, or populated at all.

Note there is **no powertrain column**: the source does not hold one. EV/PHEV/HEV/PETROL
is *derived* downstream from the VIN where the manufacturer encoded it, and from
`fuel_desc` otherwise.

### traffic_fines.csv  (Adabas file 20 TRAFFINE, one row per fine)
| column | source | notes |
|---|---|---|
| isn | *ISN | |
| fine_no | FINE-NO | business key |
| plate_no | PLATE-NO | **the plate, not the vehicle** — see below |
| offence_yyyymmdd | OFFENCE-DATE | numeric date; → DATE in Hop |
| location | LOCATION | |
| amount | AMOUNT | packed P7.2, written with the decimal point |
| status | STATUS | code I/P/C/A → description via `CODE_LOOKUP` |
| offender_national_id | OFFENDER-ID | |

**A fine identifies a plate, never a vehicle.** Resolving `plate_no` to a vehicle is the
migration's job, and it is why the plate table matters: a fine written against
`90000019` belongs to the same car as one written against `537MN75`. A plate that
matches nothing is normal — foreign and long-deregistered vehicles — and must not cause
the fine to be dropped.

### traffic_fine_offences.csv  (MU OFFENCE-CODE)
| column | source |
|---|---|
| parent_key | *ISN of the fine |
| occurrence_index | MU occurrence (1-based) |
| offence_code | OFFENCE-CODE(i), A4 |

### traffic_fine_payments.csv  (PE PAYMENT)
| column | source |
|---|---|
| parent_key | *ISN of the fine |
| occurrence_index | PE occurrence |
| paid_yyyymmdd | PAY-DATE(i) |
| paid_amount | PAY-AMT(i), packed P7.2 |
| payment_method | PAY-METH(i), A2 |

## manifest.json shape

```json
{
  "extracted_at": "2026-08-17T12:00:00Z",
  "files": {
    "vehicles.csv": 807,
    "traffic_fines.csv": 1136,
    "traffic_fine_offences.csv": 2271,
    "traffic_fine_payments.csv": 682
  }
}
```

Counts are the record counts REPORTED BY THE EXTRACT PROGRAMS (not just `wc -l`);
the reconcile step cross-checks them against actual CSV line counts and Oracle.

> Note `vehicles.csv` counts **rows in the file**, not vehicles — the reconcile step
> derives the vehicle and plate expectations from the file itself.
