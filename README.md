# Adabas → Oracle migration lab

A complete, runnable example of migrating data out of **Adabas** (a legacy
mainframe-era NoSQL database) into a **hand-designed relational Oracle model** —
including the parts that are actually hard: multiple-value fields, periodic groups,
duplicated records left behind by a legacy workaround, and a target schema that
deliberately does not mirror the source.

The domain is vehicles, their registration plates, and traffic fines. Everything is free
and runs offline after the initial image pulls. One command:

```bat
migrate.cmd
```

It ends with **`VERIFIED: 11/11`** when every migrated table matches its expected-count
rule.

> **The other direction lives in a sibling repo:** [`oracle-to-adabas-sync`](https://github.com/krixerx/oracle-to-adabas-sync)
> — Oracle → Adabas log-based change synchronisation, writing back *through* Natural
> business logic. This repo is the bulk load; that one is the ongoing sync.

## What it demonstrates

| | |
|---|---|
| **MU/PE flattening** | An Adabas multiple-value field (the offences seen in one stop) and a periodic group (part payments) become proper child tables with `parent_key` + `occurrence_index` |
| **Structural redesign** | Two flat Adabas files become six related tables with surrogate keys — the target model is intentionally *not* a copy of the source |
| **De-duplication** | A legacy workaround stored one row **per plate** — the same vehicle repeated under a suffixed VIN. The migration collapses those rows into one vehicle with 1–3 plates |
| **Code replacement** | House-grown vehicle-type codes (`SEDAN`, `LORRY`, `MBIKE`, …) substituted for the target model's standard types, with the original kept for lineage |
| **Type conversion** | Adabas numeric `YYYYMMDD` → Oracle `DATE`; packed decimal amounts → `NUMBER(9,2)` |
| **Code resolution** | Fine status, offence and payment-method codes resolved to descriptions through a `CODE_LOOKUP` table — the classic Adabas one-file-many-code-tables pattern |
| **Cross-file resolution** | A fine records the *plate*, so the migration resolves plate → vehicle through the plate table it just built |
| **Derivation with provenance** | EV/PHEV/HEV/Petrol exists nowhere in the source. It is derived in **JavaScript** from two partial, disagreeing inputs — a per-manufacturer VIN rule table and thirty years of free text — and every row records *which* strategy decided it |
| **Quarantine, not loss** | Rows the target model cannot hold (a fourth plate) or cannot resolve (a plate belonging to no vehicle) go to `MIGRATION_REJECT`; `loaded + rejected = rows in` is an asserted check |
| **Reconciliation** | An independent count pass that proves the migration, rather than assuming it |

Real numbers from a run: 807 vehicle rows → **773 vehicles, 797 plates** · 766 vehicle
types replaced, 7 unmapped codes parked on `UN` · powertrain derived for all 773 — 216
from the VIN (132 of those contradicting the fuel text), 493 from free text, 64 genuinely
unknown · **1,136 fines** with 2,271 offence rows and 682 payment rows, 1,111 resolved to
a vehicle · **35 rows quarantined in `MIGRATION_REJECT`** — 10 surplus plates and 25 fines
whose plate belongs to no vehicle.

### The de-duplication rule

```
source: one row per PLATE                     target: one row per VEHICLE
  ISN 9   537MN75   FIAZZ1JZW00000009           VEHICLE  vin FIAZZ1JZW00000009
  ISN 792 90000019  FIAZZ1JZW000000091   ──▶      VEHICLE_PLATE 1  537MN75
  ISN 793 90000020  FIAZZ1JZW000000092            VEHICLE_PLATE 2  90000019
  ISN 794 90000021  FIAZZ1JZW000000093            VEHICLE_PLATE 3  90000020
  ISN 795 90000022  FIAZZ1JZW000000094         MIGRATION_REJECT  90000021
  ISN 796 90000023  FIAZZ1JZW000000095         MIGRATION_REJECT  90000022
                             ^^                MIGRATION_REJECT  90000023
        the workaround: same VIN, one extra
        character, and A DIFFERENT PLATE
```

Each row carries a **genuinely different registration** — that is the whole reason the
workaround exists. The VIN suffix is the only thing tying them together.

Cut the VIN to 17 characters, sort on the full VIN so the un-suffixed row comes first,
number the rows within each group: row 1 becomes the vehicle, rows 1–3 become its
plates, anything beyond 3 is rejected. The rule lives entirely in the Hop mappings —
the extract writes the VIN exactly as stored.

Fines then resolve against those plates, which is where the work pays off: fines written
against `537MN75`, `90000019` and `90000020` — three unrelated-looking registrations — all
land on the one car.

### Deriving something the source does not contain

The target model classifies every vehicle as **EV / PHEV / HEV / Petrol**. Nothing in
Adabas holds that. Two partial sources have to be combined, and this is the one place a
script is the right answer:

```
VIN  FORZE1JZW00000041          <- Ford puts the engine code at position 5
        ^                          BMW puts it at position 8, different letters,
                                   and most manufacturers encode nothing at all
     └─ vin_powertrain_rule  ──▶ EV          (a TABLE, not a formula)

FUEL-DESC  'HYBRID'            <- 30 years of free text: 'petrol', 'BENZIN',
     └─ JavaScript normalise ──▶ HEV            'ELEC.', 'PLUG-IN HYBRID', 'N/A'

                    they disagree ──▶ EV, powertrain_source = 'VIN_RULE_CONFLICT'
```

**There is no algorithm that decodes a VIN.** Positions 1–3 (manufacturer) and 10 (model
year) are standardised worldwide, but 4–8 are the manufacturer's private descriptor —
which is why NHTSA publishes the vPIC *database* rather than a formula. So the rules live
in a table an analyst can extend, and the script does what only a script does well:
normalise messy text, apply precedence, and record what happened.

Two details carry most of the lesson. `PLUG-IN HYBRID` contains `HYBRID`, so plug-in must
be tested **first** — get it backwards and every PHEV silently becomes an HEV while the
row counts reconcile perfectly. And where the two sources disagree the row still loads,
flagged rather than quietly resolved: 132 vehicles in a real run are `VIN_RULE_CONFLICT`.

## Architecture

```
Adabas CE (Docker)                                    Oracle 23ai Free (Docker)
  file 12 VEHICLES ──┐                                   ┌─ VEHICLE
  file 20 TRAFFINE ──┤                                   ├─ VEHICLE_PLATE
    (MU offences,    │                                   ├─ TRAFFIC_FINE
     PE payments)    ▼                                   ├─ TRAFFIC_FINE_OFFENCE
        Natural extract programs                         ├─ TRAFFIC_FINE_PAYMENT
        (EXTRVEH, EXTRFIN)                               ├─ MIGRATION_REJECT
                     │                                   └─ CODE_LOOKUP · VEHICLE_TYPE
                     ▼                                      · VEHICLE_TYPE_MAP
        contract CSVs in data/  ──▶  Apache Hop  ─────────────────▲
        (BOM-less UTF-8, RFC 4180)   pipelines 10–50              │
                                     splits · surrogate keys ─────┘
                                     dates · lookups · de-duplication
```

**Why Natural extract programs and not JDBC?** There is no free JDBC driver for Adabas,
and in a real migration the extract is usually written by the team who own the Natural
codebase anyway. Extract-to-flat-files is the production-faithful shape, and it keeps
the extract stage swappable — the rest of the pipeline only knows about the file
contract in [`FLAT_FILE_CONTRACT.md`](FLAT_FILE_CONTRACT.md).

## Quick start

```bat
scripts\lab-up.ps1              :: bring the lab up + prepare the source data
migrate.cmd                     :: full run, ends "VERIFIED: 11/11"
migrate.cmd --skip-extract      :: inner mapping loop, reuses existing CSVs (<1 min)
```

**Start with `lab-up.ps1`, not with `docker compose up`.** Besides clearing a stale
Adabas lock, it runs `scripts\seed-source.ps1`, which prepares the source. The Community
Edition demo database gives us a `VEHICLES` file with no VIN and no vehicle-type field,
and no traffic-fine file at all, so the lab manufactures them in Adabas first:
`ADADBM ADD_FIELDS` adds the three fields online, `ADAFDU` creates file 20 with its MU and
PE, and two Natural programs fill them in. Every step is idempotent, and all of it is
needed again after every `docker compose down -v`.

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
oracle-init/                 target DDL + lookup/mapping seeds (auto-applied on first start)
natural/                     extract programs (EXTRVEH, EXTRFIN), the lab data seeders
                             (SEEDVEH, SEEDFIN), the DDMs and the traffic-fine FDT
hop/pipelines/               10 vehicle (de-duplicate) · 20 vehicle_plate (+ rejects) ·
                             30 traffic_fine (plate → vehicle) · 40 offences (MU) ·
                             50 payments (PE)
hop/workflows/               migrate-all.hwf — runs them in dependency order
scripts/                     extract · clear-tables · reconcile · lab-up · seed-source ·
                             make-sample-data
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
  `run-extract.sh` does every run so it self-heals. The DDMs here are hand-authored and
  **fixed-column** (53 characters per field line), so copy the spacing exactly.
- **Session limits:** `madio=0` is required (otherwise NAT1009 after 512 database
  calls), and each run needs a unique `etid=`. An aborted session leaves a stale ET
  user in the Adabas user queue and the next run fails with response 48/8; clear it
  with `adaopr db=1 stop=<id>`.
- **The Adabas nucleus writes a host-bound lock** at `/data/db001/_DB_LOCK`. Compose
  pins `hostname: a2o-adabas` for exactly this reason — a recreated container with a
  random hostname aborts with ADANUC-F-CONCURRLOCKHOST. `scripts\lab-up.ps1` clears a
  stale lock automatically.
- **`COMPRESS` on a packed field drops the decimal point.** An amount of `25.00` reaches
  the CSV as `2500` — silently a hundred times too big, and nothing downstream can tell.
  Apply an edit mask (`MOVE EDITED … (EM=ZZZZ9.99)`) and strip the mask's leading blanks.
- **Fields can be added to a loaded Adabas file online** — `ADADBM ADD_FIELDS`, nucleus
  up, no unload/reload; existing records simply do not carry the new fields and read back
  as blank. Two traps cost time. The field definitions are ADADBM **parameter lines**
  terminated by `end_of_fields`, *not* the `field=` keyword that ADADBM also accepts (that
  one answers `FDUSYN` whatever you feed it). And piping the parameters into
  `docker exec -i … adadbm` from PowerShell makes it read **nothing**: it prints its
  banner, never opens the database, and exits 0 — a no-op that looks exactly like
  success. Use a heredoc inside the container and assert on the
  `FUNC, function ADD_FIELDS executed` line.
- **A descriptor (`DE`) on a newly added field would need an `ADAINV` pass** over the
  loaded file. Nothing here searches by VIN, so the added fields are plain `NU`.
- **A whole new file with MU and PE is one `ADAFDU` run.** The FDT syntax is
  `1,AH,4,A,NU,MU` for a multiple-value field and a bare `1,AP,PE` group header followed
  by level-2 members for a periodic group. The `adabas` service bind-mounts nothing from
  the repo, so the FDT has to be `docker cp`'d in.
- **Real-data lesson:** one vehicle in the demo data has no `REG-NUM`, so the plate is
  nullable — and it cannot be fined, since a fine is raised against a plate. The
  `NOT NULL` assumption came from simulated sample data and survived until the first run
  against the real file.

## Licence

Code in this repository: **Apache-2.0** (see [LICENSE](LICENSE)).

**Adabas & Natural Community Edition** — the Docker images this lab runs on — are
licensed by Software AG for **personal use and learning only**; commercial production
use is prohibited. No CE binaries and no CE demo data are redistributed here: the
images are pulled from Docker Hub and the extract output is gitignored.

The Oracle JDBC driver is not included either; it carries Oracle's OTN licence and you
download it yourself (see Prerequisites).
