# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A runnable lab that migrates data out of **Adabas** (legacy mainframe NoSQL) into a
**hand-designed relational Oracle model** — deliberately *not* a mirror of the source.
Domain: vehicles, their registration plates, and traffic fines. Everything is free,
Docker-based, and runs offline after the initial image pulls.

The whole thing is one command, and its contract is the final line of output:

```bat
migrate.cmd          :: full run, ends "VERIFIED: 11/11"
```

`VERIFIED: 11/11` is the acceptance criterion. A change that does not end there is not done.

The reverse direction (Oracle → Adabas log-based sync) lives in the sibling repo
`oracle-to-adabas-sync`, not here.

## Commands

| | |
|---|---|
| `scripts\lab-up.ps1` | bring the lab up; clears a stale Adabas lock, then seeds the source data — prefer this over bare `docker compose up` |
| `scripts\demo-extract.ps1 [-Live]` | proves the CSVs come out of Adabas: FDT with MU/PE, Adabas's own counts, delete the CSVs, re-extract, and (`-Live`) change a record and watch the CSV follow |
| `scripts\seed-source.ps1` | lab data preparation only (ADADBM field add, ADAFDU file create, Natural SEEDVEH + SEEDFIN); idempotent |
| `migrate.cmd` | full run: extract → clear → transform+load → reconcile |
| `migrate.cmd --skip-extract` | inner loop while editing mappings; reuses the CSVs in `data\` (<1 min) |
| `docker compose run --rm hop-run` | just the Hop workflow |
| `powershell -File scripts\reconcile.ps1` | just the verification report |
| `hop-gui.cmd` | Hop desktop client against this project (needs `HOP_HOME`, default `C:\hop`) |

Ad-hoc SQL: `docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1`
(service `FREEPDB1`, schema `POCAPP`; SYS password `PocSysPwd1`).

## Pipeline shape

```
Adabas CE (file 12 VEHICLES, file 20 TRAFFINE)
  ↑ natural/SEEDVEH.NSP + SEEDFIN.NSP  (lab data prep, NOT migration — see below)
  → natural/EXTRVEH.NSP + EXTRFIN.NSP  (run headlessly via natural/run-extract.sh)
  → contract CSVs + manifest.json in data\        ← FLAT_FILE_CONTRACT.md
  → hop/workflows/migrate-all.hwf → pipelines 10..50
  → Oracle POCAPP (VEHICLE, VEHICLE_PLATE, TRAFFIC_FINE + 2 children,
                   MIGRATION_REJECT, CODE_LOOKUP/VEHICLE_TYPE/VEHICLE_TYPE_MAP,
                   POWERTRAIN_TYPE/VIN_POWERTRAIN_RULE)
  → scripts/reconcile.ps1 → "VERIFIED: n/n"
```

Division of labour, and it matters: **the Natural programs only serialise; Hop does all
reshaping.** Splits, surrogate keys, `YYYYMMDD`→`DATE`, code resolution, the VIN
de-duplication and the plate→vehicle resolution belong in `.hpl` files, never in `.NSP`.
That is what keeps the extract stage swappable (Natural today, JDBC/SQL Gateway later)
behind one file contract.

Inside each pipeline: `CSVInput` = source fields · `SelectValues` = type conversion ·
`DBLookup` = code resolution and parent-key resolution · `TableOutput` = column mapping.

**Vehicles are not 1:1 and that is the point.** The source holds one row **per plate**:
a vehicle with several plates was registered again under the same VIN with a character
appended past position 17. Pipeline 10 cuts the VIN to 17, sorts on the full VIN so the
un-suffixed row sorts first, numbers the rows within the group and keeps `plate_seq = 1`
→ `VEHICLE`. Pipeline 20 re-derives the same grouping and keeps *every* row → up to three
`VEHICLE_PLATE` rows, with the surplus quarantined in `MIGRATION_REJECT` rather than
dropped. `veh_type` is a house-grown code replaced via `VEHICLE_TYPE_MAP`; an unmapped
code is not an error — it lands on `UN` and stays visible in `source_vehicle_type`.

**The powertrain is derived, not copied — and it is the one place a script earns its
keep.** The source has no powertrain field. Two partial sources are combined in pipeline
10: `match VIN rule` (a `DBJoin` running `? LIKE vin_pattern` against
`vin_powertrain_rule`, **outer join** so the majority of makes with no rule still pass
through), then `derive powertrain` (`ScriptValueMod`) which normalises the free-text
`fuel_desc` and runs the cascade **VIN → fuel text → `UN`**. Three rules hold it together:
*there is no formula* (VIN positions 4–8 are manufacturer-private, so decoding is a table
lookup — the vPIC shape); *order matters inside the script* — `PLUG-IN HYBRID` contains
`HYBRID`, so plug-in must be tested first or every PHEV silently becomes an HEV and the
row counts still reconcile; and *provenance is stored* in `powertrain_source`
(`VIN_RULE` / `VIN_RULE_CONFLICT` / `FUEL_DESC` / `UNKNOWN`) because a derived value
without it cannot be argued about later. `reconcile.ps1` checks the VIN branch by
re-matching the patterns with PowerShell `-like` — a genuinely independent engine, not a
copy of the script.

**A fine identifies a plate, never a vehicle.** Pipeline 30 resolves it through
`VEHICLE_PLATE`, which is what makes the de-duplication pay off — fines on `344RG94`,
`344RG94-1` and `344RG94-2` all land on the one car. An unmatched plate is normal
(foreign, deregistered): the fine still loads, with `vehicle_id` NULL *and* a
`MIGRATION_REJECT` row, which is why `resolve status` has `distribute = N` — it **copies**
its rows to both branches instead of round-robining them.

**There is a cascade worth knowing about:** a plate rejected as surplus is not in
`VEHICLE_PLATE`, so fines written against *that* plate cannot resolve either. Both ends
land in `MIGRATION_REJECT`, and `reconcile.ps1` models it by building its expected plate
set with the same top-N rule the mapping uses — not from every plate in the file.

**`natural/SEEDVEH.NSP` and `SEEDFIN.NSP` are lab data preparation, not migration.** The
CE demo database has no VIN, no vehicle-type field and no traffic-fine file, so
`scripts\seed-source.ps1` adds them (`ADADBM ADD_FIELDS` online, `ADAFDU` for file 20) and
the two programs manufacture the legacy shapes. Both are re-runnable by design — each
empties what it owns before recreating it — and both must be re-run after any
`docker compose down -v`.

## Change these together

Most breakage here is a half-applied change across files that share one fact.

- **A column in the extract** → `FLAT_FILE_CONTRACT.md` + the `.NSP` (header row *and* the
  row-building `PERFORM APPEND-F` sequence) + the pipeline's `CSVInput` + `TableOutput`.
- **A field in Adabas file 12** → the `$newFields` list in `scripts/seed-source.ps1` +
  `natural/VEHICLES.NSD` + `SEEDVEH.NSP` + `EXTRVEH.NSP` + **both** vehicle pipelines'
  `CSVInput`. Fields are added one at a time and each is FDT-checked first, so an
  existing lab picks up a new one without being rebuilt.
- **A VIN decode rule** → `vin_powertrain_rule` in `oracle-init/02_lookups.sql` only —
  that is the point of it being data. But the *lab* signal it matches is written by
  `SEEDVEH.NSP` (`#PTCHF`/`#PTCHB` and the `#VDS` positions), so a new manufacturer needs
  both if you want rows that actually match it.
- **The free-text fuel spellings** → `#FUELD` in `natural/SEEDVEH.NSP` and the regexes in
  the `derive powertrain` script in `10_vehicle.hpl`. Adding a spelling the script does
  not know is a legitimate experiment: it lands on `UN`, loudly and countably.
- **A field in Adabas file 20** → `natural/TRAFFINE.fdt` + `natural/TRAFFINE.NSD` +
  `SEEDFIN.NSP` + `EXTRFIN.NSP`. The FDT only applies to a file that does not exist yet,
  so changing it means `docker compose down -v` (or dropping file 20 by hand).
- **Both DDMs are fixed-column, 53 characters per field line** — copy the spacing from an
  existing line exactly. The header name must match the *object* name (`TRAFFINE`), not
  the Adabas file name.
- **A target table or column** → `oracle-init/01_schema.sql` + the pipeline + (if it is a
  new table) `scripts/reconcile.ps1` and the DELETE order in `scripts/clear-tables.ps1`.
- **Lookup seed rows** → `oracle-init/02_lookups.sql` + the `$seedRules` counts in
  `scripts/reconcile.ps1` (`CODE_LOOKUP` 13, `VEHICLE_TYPE` 6, `VEHICLE_TYPE_MAP` 9,
  `POWERTRAIN_TYPE` 5, `VIN_POWERTRAIN_RULE` 8). The
  seed check fails loudly if they drift.
- **The custom vehicle-type codes** → `#TYPES` in `natural/SEEDVEH.NSP` *and*
  `vehicle_type_map` in `oracle-init/02_lookups.sql`. Keep `X-OLD` out of the map: the
  unmapped→`UN` path is only exercised because one code is deliberately missing.
- **Offence / status / payment-method codes** → the arrays in `natural/SEEDFIN.NSP` *and*
  the matching `CODE_LOOKUP` domains in `oracle-init/02_lookups.sql`.
- **The VIN cut length** → the `StringCut` transform in pipelines 10 **and** 20, and
  `$VIN_LEN` in `scripts/reconcile.ps1`. All three encode the same rule.
- **The maximum plates per vehicle** → `ck_vehicle_plate_seq` in
  `oracle-init/01_schema.sql` + the **at most 3 plates** filter in `20_vehicle_plate.hpl`
  + `$MAX_PLATES` in `scripts/reconcile.ps1`. Three layers, one rule.
- `oracle-init/` runs **only on first container start**. Schema changes need
  `docker compose down -v` (destroys the Oracle volume) or manual DDL.

## Traps that have already cost time

Each of these has a comment at the site explaining it; do not "clean up" the comment.

- **`ORACLE_HOST` must NOT be a project variable.** It is supplied by a Hop **environment**,
  one per side: `hop-env-docker.json` (`oracle`, mounted into the container and named by
  `HOP_ENVIRONMENT_*` in compose) and `hop-env-local-gui.json` (`localhost`, the `local-gui`
  environment the desktop GUI selects). The measured layering, 2026-08-16:
  **a project variable beats an environment variable** — the opposite of what this file
  claimed until then. So a project default wins on *both* sides at once, and whichever value
  it holds breaks the other side: `oracle` makes every GUI run/preview fail with ORA-17868,
  `localhost` makes every container run fail with ORA-12541. Both failures have now happened
  here. A plain OS environment variable is no substitute either — the `apache/hop` container
  never picks it up as a Hop variable and the connection URL keeps the literal
  `${ORACLE_HOST}`. If you add another host-dependent setting, give it the same treatment.
- **`hop/lib/ojdbc11.jar` is not in the repo** (Oracle OTN licence) and is bind-mounted as a
  *file*. If missing, Docker creates a **directory** with that name and Hop fails obscurely.
  `migrate.cmd` preflights both cases; keep that check.
- **Natural CE has no batch mode.** The extract runs the interactive driver headlessly with
  a stacked command list. Consequences: extract programs must never `WRITE` to the terminal
  (the session blocks on a `MORE` prompt), `madio=0` is required (NAT1009 after 512 DB
  calls), and each run needs a unique `etid=` (a stale ET user gives response 48/8 — clear
  with `adaopr db=1 stop=<id>`).
- **DDMs must be catalogued**; CE has no SYSDDM, so `run-extract.sh` re-runs
  `READ <ddm>;CATALOG` for both DDMs every time to self-heal.
- **`COMPRESS` on a packed field writes the digits with no decimal point** — `25.00`
  becomes `2500`, a silent factor of 100 that nothing downstream can detect. `EXTRFIN.NSP`
  uses an edit mask and strips the mask's leading blanks; do the same for any new amount.
- **A subroutine must not reuse its caller's `FOR` index.** `SEEDFIN.NSP` uses `#M` inside
  `BUILD-FINE` precisely because pass 3 calls it from inside a `FOR #K` loop.
- **Adabas writes a host-bound lock** (`/data/db001/_DB_LOCK`). Compose pins
  `hostname: a2o-adabas`; an unclean stop leaves a stale lock and the container then exits 0
  looking healthy. That is why `lab-up.ps1` exists.
- **The extract is deliberately NOT a Hop action.** The Natural runtime is in another
  container and the Hop image has no Docker CLI, so a `shell` action cannot reach it
  without a Docker-socket mount. It is also not production-faithful - a real extract is a
  mainframe job. `migrate-all.hwf` instead opens with a `FILES_EXIST` gate that aborts
  with a usable message when the contract files are missing; do not "fix" this by adding
  a shell action.
- **Clear with `DELETE`, child-first — never `TRUNCATE`** (ORA-02266 against enabled FKs,
  even with empty children).
- **`ADADBM ADD_FIELDS` takes its field definitions as parameter lines** ending in
  `end_of_fields` — the `field=` keyword it also accepts answers `FDUSYN` whatever you
  give it. And **piping those parameters into `docker exec -i` from PowerShell makes
  adadbm read nothing**: banner, no `DBON`, exit 0. A silent no-op that looks like
  success, which is why `seed-source.ps1` uses a heredoc inside the container *and*
  asserts on the `FUNC, function ADD_FIELDS executed` line.
- **The `adabas` service bind-mounts nothing from this repo** (only `natural` does), so
  anything ADAFDU or ADADBM needs has to be `docker cp`'d to `/tmp` first.
- **Multi-line strings sent into a container must be joined with an explicit `` `n ``.**
  `.gitattributes` checks `.ps1` out with CRLF, so a PowerShell here-string would carry
  CRs into a shell heredoc and the body would arrive as `db=1\r`.
- **Sorting is load-bearing for the vehicle pipelines.** `FieldsChangeSequence` resets its
  counter when the group field *changes*, so unsorted input silently produces wrong plate
  numbers rather than an error. `SortRows` uses `case_sensitive=Y` on purpose — a collator
  must not reorder a VIN against its own suffixed form.
- **Line endings are load-bearing.** `.gitattributes` keeps `.sh`/`.NSP`/`.NSD`/`.hpl`/
  `.fdt`/`.fdu` at LF (they execute inside Linux containers; Natural source and DDMs are
  column-sensitive) and `.cmd`/`.ps1` at CRLF. A CRLF shell script fails with a confusing
  "command not found".
- **Ports 60001, 8190, 2700, 1521** collide with the sibling `oracle-to-adabas-sync` lab.
  One at a time.

## Conventions

- Orchestration is `.cmd` + PowerShell on the host; anything inside a container is `sh`.
- Scripts fail loudly: `$ErrorActionPreference = "Stop"`, non-zero exit, and `migrate.cmd`
  aborts on the first failing stage.
- Comments in this repo explain *why*, usually a bug that was paid for once. Match that
  density rather than trimming it.
- **Never commit** CE binaries, CE demo data, extract output (`data\*`) or the Oracle JDBC
  jar. Adabas & Natural CE are licensed for personal use and learning only — the repo is
  Apache-2.0 but must stay free of anything CE-derived.
