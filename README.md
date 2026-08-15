# Adabas → Oracle migration lab

A complete, runnable example of migrating data out of **Adabas** (a legacy
mainframe-era NoSQL database) into a **hand-designed relational Oracle model** —
including the parts that are actually hard: multiple-value fields, periodic groups,
and a target schema that deliberately does not mirror the source.

Everything is free and runs offline after the initial image pulls. One command:

```bat
migrate.cmd
```

It ends with **`VERIFIED: 5/5`** when every migrated table's row count matches its
expected-count rule.

> **The other direction lives in a sibling repo:** [`oracle-to-adabas-sync`](https://github.com/krixerx/oracle-to-adabas-sync)
> — Oracle → Adabas log-based change synchronisation, writing back *through* Natural
> business logic. This repo is the bulk load; that one is the ongoing sync.

## What it demonstrates

| | |
|---|---|
| **MU/PE flattening** | Adabas multiple-value fields (`ADDRESS-LINE`, `LANG`) and a periodic group (`INCOME`) become proper child tables with `parent_key` + `occurrence_index` |
| **Structural redesign** | One Adabas file becomes several Oracle tables, with surrogate keys — the target model is intentionally *not* a copy of the source |
| **Type conversion** | Adabas numeric `YYYYMMDD` → Oracle `DATE`, including leap-day dates |
| **Code resolution** | Single-character codes resolved to descriptions through a `CODE_LOOKUP` table — the classic Adabas one-file-many-code-tables pattern |
| **Cross-file joins** | `VEHICLES` joined to `EMPLOYEES` on the business key, producing a real FK |
| **Reconciliation** | An independent count/checksum pass that proves the migration, rather than assuming it |

Real numbers from a run: 1,107 employees · 2,441 address lines · 1,813 languages ·
3,578 income rows · 773 vehicles.

## Architecture

```
Adabas CE (Docker)                                    Oracle 23ai Free (Docker)
  file 11 EMPLOYEES ─┐                                   ┌─ EMPLOYEE
  file 12 VEHICLES ──┤                                   ├─ EMPLOYEE_ADDRESS_LINE
                     │                                   ├─ EMPLOYEE_LANGUAGE
                     ▼                                   ├─ EMPLOYEE_INCOME
        Natural extract programs                         ├─ VEHICLE
        (EXTREMP, EXTRVEH)                               └─ CODE_LOOKUP
                     │                                          ▲
                     ▼                                          │
        contract CSVs in data/  ──▶  Apache Hop  ───────────────┘
        (BOM-less UTF-8, RFC 4180)   pipelines 10–50
                                     splits · surrogate keys
                                     date conversion · lookups · joins
```

**Why Natural extract programs and not JDBC?** There is no free JDBC driver for Adabas,
and in a real migration the extract is usually written by the team who own the Natural
codebase anyway. Extract-to-flat-files is the production-faithful shape, and it keeps
the extract stage swappable — the rest of the pipeline only knows about the file
contract in [`FLAT_FILE_CONTRACT.md`](FLAT_FILE_CONTRACT.md).

## Quick start

```bat
scripts\lab-up.ps1              :: bring the lab up (clears a stale Adabas lock if present)
migrate.cmd                     :: full run, ends "VERIFIED: 5/5"
migrate.cmd --skip-extract      :: inner mapping loop, reuses existing CSVs (<1 min)
```

`--skip-extract` is the loop you want while editing mappings: it skips the Adabas
extract and re-runs only the transform and load.

Hands-on walkthrough, including how to inspect the data at each stage:
[`TESTING_GUIDE.md`](TESTING_GUIDE.md).

## Prerequisites

One-time, and they need internet. After this the lab runs fully offline.

1. **Docker Desktop.** ≥16 GB host RAM recommended (WSL `.wslconfig` memory ≥ 8 GB).
2. **`docker login`** with a free Docker Hub account — the Adabas and Natural
   Community Edition images require it.
3. **Images:** `softwareag/adabas-ce`, `softwareag/natural-ce`,
   `gvenzl/oracle-free:23-slim`, `apache/hop:latest`.
4. **Oracle JDBC driver.** Download `ojdbc11.jar` and put it in **`hop/lib/`**.
   It is not in this repo (Oracle OTN licence). `migrate.cmd` checks for it and stops
   with a clear message if it is missing — otherwise Docker would create a *directory*
   with that name and Hop would fail obscurely.
   → https://www.oracle.com/database/technologies/appdev/jdbc-downloads.html
5. *(Optional)* [Apache Hop desktop client](https://hop.apache.org/download/) to edit
   the mappings visually, and NaturalONE CE to edit the extract programs.

⚠️ **Ports.** This lab publishes **60001, 8190, 2700, 1521**. The sibling
`oracle-to-adabas-sync` repo publishes the same ones. **Stop one lab before starting
the other** — they are designed to run one at a time.

## Layout

```
migrate.cmd                  the one command
docker-compose.yml           adabas, natural, oracle, hop-run
FLAT_FILE_CONTRACT.md        the extract → transform interface
oracle-init/                 target DDL + CODE_LOOKUP seeds (auto-applied on first start)
natural/                     extract programs (EXTREMP, EXTRVEH) + the VEHICLES DDM
hop/pipelines/               10 employee · 20 address · 30 language · 40 income · 50 vehicle
hop/workflows/               migrate-all.hwf — runs them in dependency order
scripts/                     extract · clear-tables · reconcile · lab-up · make-sample-data
data/                        extract output lands here (gitignored)
```

## Spike findings — how the Natural CE extract actually works

These cost real time to discover. If you are building something similar, start here.

- **Natural CE has no batch mode** (Startup Error 42, licence-gated). The workaround
  that works: run the *interactive* driver headlessly with a stacked command list —
  `natural udb=1 madio=0 "etid=X$$" "stack=(LOGON EXTRACT;...;FIN)" </dev/null`.
  Exit codes propagate. Extract programs must not `WRITE` to the terminal, or the
  session blocks on a `MORE` prompt.
- **DBID routing** goes in `$ACLDIR/config/dbmapping.txt` → `1 = adatcp://adabas:60001`.
  `run-extract.sh` appends it idempotently on every run; the file lives inside the
  image and is lost when the container is recreated.
- **Program install:** copy sources into `$FUSER/EXTRACT/SRC`, then register with
  `ftouch lib=EXTRACT sm -b -d`. Extensions matter: `.NSP` program, `.NSN` subprogram,
  `.NSD` DDM.
- **DDMs must be catalogued** (`.NGD`) — source-only compiles fail with NAT0002, and CE
  has no SYSDDM. Workaround: put `READ <ddm>;CATALOG` on the stack, which
  `run-extract.sh` does every run so it self-heals. `VEHICLES.NSD` was hand-authored
  from `adarep db=1 fdt file=12`; DDM source is **fixed-column**, so copy the spacing
  from an existing DDM exactly.
- **Session limits:** `madio=0` is required (otherwise NAT1009 after 512 database
  calls), and each run needs a unique `etid=`. An aborted session leaves a stale ET
  user in the Adabas user queue and the next run fails with response 48/8; clear it
  with `adaopr db=1 stop=<id>`.
- **The Adabas nucleus writes a host-bound lock** at `/data/db001/_DB_LOCK`. Compose
  pins `hostname: a2o-adabas` for exactly this reason — a recreated container with a
  random hostname aborts with ADANUC-F-CONCURRLOCKHOST. `scripts\lab-up.ps1` clears a
  stale lock automatically.
- **Real-data lesson:** one vehicle in the demo data has no `REG-NUM`, so `REG_NUM` had
  to be made nullable. The `NOT NULL` assumption came from simulated sample data and
  survived until the first run against the real file.

## Licence

Code in this repository: **Apache-2.0** (see [LICENSE](LICENSE)).

**Adabas & Natural Community Edition** — the Docker images this lab runs on — are
licensed by Software AG for **personal use and learning only**; commercial production
use is prohibited. No CE binaries and no CE demo data are redistributed here: the
images are pulled from Docker Hub and the extract output is gitignored.

The Oracle JDBC driver is not included either; it carries Oracle's OTN licence and you
download it yourself (see Prerequisites).
