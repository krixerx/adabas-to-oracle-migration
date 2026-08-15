# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A runnable lab that migrates data out of **Adabas** (legacy mainframe NoSQL) into a
**hand-designed relational Oracle model** — deliberately *not* a mirror of the source.
Everything is free, Docker-based, and runs offline after the initial image pulls.

The whole thing is one command, and its contract is the final line of output:

```bat
migrate.cmd          :: full run, ends "VERIFIED: 5/5"
```

`VERIFIED: 5/5` is the acceptance criterion. A change that does not end there is not done.

The reverse direction (Oracle → Adabas log-based sync) lives in the sibling repo
`oracle-to-adabas-sync`, not here.

## Commands

| | |
|---|---|
| `scripts\lab-up.ps1` | bring the lab up; clears a stale Adabas lock first — prefer this over bare `docker compose up` |
| `migrate.cmd` | full run: extract → clear → transform+load → reconcile |
| `migrate.cmd --skip-extract` | inner loop while editing mappings; reuses the CSVs in `data\` (<1 min) |
| `docker compose run --rm hop-run` | just the Hop workflow |
| `powershell -File scripts\reconcile.ps1` | just the verification report |
| `hop-gui.cmd` | Hop desktop client against this project (needs `HOP_HOME`, default `C:\hop`) |

Ad-hoc SQL: `docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1`
(service `FREEPDB1`, schema `POCAPP`; SYS password `PocSysPwd1`).

## Pipeline shape

```
Adabas CE (files 11 EMPLOYEES / 12 VEHICLES)
  → natural/EXTREMP.NSP + EXTRVEH.NSP  (run headlessly via natural/run-extract.sh)
  → contract CSVs + manifest.json in data\        ← FLAT_FILE_CONTRACT.md
  → hop/workflows/migrate-all.hwf → pipelines 10..50
  → Oracle POCAPP (EMPLOYEE + 3 children, VEHICLE, CODE_LOOKUP)
  → scripts/reconcile.ps1 → "VERIFIED: n/n"
```

Division of labour, and it matters: **the Natural programs only serialise; Hop does all
reshaping.** Splits, surrogate keys, `YYYYMMDD`→`DATE`, code resolution and the
`VEHICLES`→`EMPLOYEE` join belong in `.hpl` files, never in `.NSP`. That is what keeps the
extract stage swappable (Natural today, JDBC/SQL Gateway later) behind one file contract.

Inside each pipeline: `CSVInput` = source fields · `SelectValues` = type conversion ·
`DBLookup` = code resolution and parent-key (`source_isn` → `emp_id`) resolution ·
`TableOutput` = column mapping.

## Change these together

Most breakage here is a half-applied change across files that share one fact.

- **A column in the extract** → `FLAT_FILE_CONTRACT.md` + the `.NSP` (header row *and* the
  row-building `PERFORM APPEND-F` sequence) + the pipeline's `CSVInput` + `TableOutput`.
- **A target table or column** → `oracle-init/01_schema.sql` + the pipeline + (if it is a
  new table) `$rules` in `scripts/reconcile.ps1` and the DELETE order in
  `scripts/clear-tables.ps1`.
- **Lookup seed rows** → `oracle-init/02_lookups.sql` + the `$seedRules` count in
  `scripts/reconcile.ps1` (currently 6). The seed check fails loudly if they drift.
- `oracle-init/` runs **only on first container start**. Schema changes need
  `docker compose down -v` (destroys the Oracle volume) or manual DDL.

## Traps that have already cost time

Each of these has a comment at the site explaining it; do not "clean up" the comment.

- **`ORACLE_HOST` in `hop/project-config.json` must stay `oracle`.** Hop *project
  variables override OS environment variables*, so a host-friendly `localhost` there
  silently defeats compose and every container run dies with ORA-12541. The host GUI
  overrides it through the `local-gui` **environment** (`hop-env-local-gui.json`) — the only
  layer that wins over a project default. This exact bug shipped once and broke every run.
- **`hop/lib/ojdbc11.jar` is not in the repo** (Oracle OTN licence) and is bind-mounted as a
  *file*. If missing, Docker creates a **directory** with that name and Hop fails obscurely.
  `migrate.cmd` preflights both cases; keep that check.
- **Natural CE has no batch mode.** The extract runs the interactive driver headlessly with
  a stacked command list. Consequences: extract programs must never `WRITE` to the terminal
  (the session blocks on a `MORE` prompt), `madio=0` is required (NAT1009 after 512 DB
  calls), and each run needs a unique `etid=` (a stale ET user gives response 48/8 — clear
  with `adaopr db=1 stop=<id>`).
- **DDMs must be catalogued**; CE has no SYSDDM, so `run-extract.sh` re-runs
  `READ VEHICLES;CATALOG` every time to self-heal. `VEHICLES.NSD` is hand-authored and
  **fixed-column** — copy spacing from an existing DDM exactly.
- **Adabas writes a host-bound lock** (`/data/db001/_DB_LOCK`). Compose pins
  `hostname: a2o-adabas`; an unclean stop leaves a stale lock and the container then exits 0
  looking healthy. That is why `lab-up.ps1` exists.
- **Clear with `DELETE`, child-first — never `TRUNCATE`** (ORA-02266 against enabled FKs,
  even with empty children).
- **Line endings are load-bearing.** `.gitattributes` keeps `.sh`/`.NSP`/`.NSD`/`.hpl` at LF
  (they execute inside Linux containers; Natural source is column-sensitive) and
  `.cmd`/`.ps1` at CRLF. A CRLF shell script fails with a confusing "command not found".
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
