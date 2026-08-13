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
- Alongside the CSVs the extractor reports per-file record counts; the orchestrator
  writes them to `data/manifest.json`.

## Files (this lab scope)

### employees.csv  (Adabas file EMPLOYEES, one row per record)
| column | source (DDM field) | notes |
|---|---|---|
| isn | *ISN | Adabas ISN |
| personnel_id | PERSONNEL-ID | A8, natural key |
| first_name | FIRST-NAME | |
| middle_name | MIDDLE-NAME / MIDDLE-I | verify in spike which exists |
| last_name | NAME | |
| mar_stat | MAR-STAT | code S/M/D/W → lookup in Hop |
| sex | SEX | code M/F |
| birth_yyyymmdd | BIRTH | numeric date, EDITED to YYYYMMDD; → DATE in Hop |
| city | CITY | |
| postal_code | ZIP / POST-CODE | verify name in spike |
| country | COUNTRY | |
| dept | DEPT | |
| job_title | JOB-TITLE / CURR-TITLE | verify name in spike |

### employees_address_lines.csv  (MU ADDRESS-LINE)
| column | source |
|---|---|
| parent_key | *ISN of employee |
| occurrence_index | MU occurrence (1-based) |
| address_line | ADDRESS-LINE(i) |

### employees_languages.csv  (MU LANG)
| column | source |
|---|---|
| parent_key | *ISN |
| occurrence_index | MU occurrence |
| language_code | LANG(i), A3 |

### employees_income.csv  (PE INCOME — first-level occurrences only; BONUS MU-in-PE deferred to round 2)
| column | source |
|---|---|
| parent_key | *ISN |
| occurrence_index | PE occurrence |
| currency_code | CURR-CODE(i) |
| salary_amount | SALARY(i), numeric |

### vehicles.csv  (Adabas file VEHICLES, one row per record)
| column | source | notes |
|---|---|---|
| isn | *ISN | |
| reg_num | REG-NUM | |
| personnel_id | PERSONNEL-ID | join key to employees |
| make | MAKE | |
| model | MODEL | |
| color | COLOR | |
| year_built | YEAR | verify field exists in spike; else leave empty |

## manifest.json shape

```json
{
  "extracted_at": "2026-08-04T18:00:00Z",
  "files": {
    "employees.csv": 1107,
    "employees_address_lines.csv": 2214,
    "employees_languages.csv": 1800,
    "employees_income.csv": 1500,
    "vehicles.csv": 900
  }
}
```

Counts are the record counts REPORTED BY THE EXTRACT PROGRAMS (not just `wc -l`);
the reconcile step cross-checks them against actual CSV line counts and Oracle.

> Columns marked "verify in spike" are pinned down when the EMPLOYEES/VEHICLES DDMs
> are inspected in the Natural CE container; update this file + the Natural programs +
> the affected pipeline together in one commit-equivalent change.
