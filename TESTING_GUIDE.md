# Adabas → Oracle Migration — Hands-On Testing & Learning Guide

How to run the POC, explore it, change mappings, and look at the data.
Everything happens in the repository root — open a terminal there first.

---

## 1. Quick start — run the whole thing

```bat
scripts\lab-up.ps1
migrate.cmd
```

Prerequisites: **Docker Desktop must be running** (all images were already pulled;
no internet needed), and the lab must have been brought up with `scripts\lab-up.ps1`
at least once since the last `docker compose down -v`.

**Why `lab-up.ps1` first.** Besides clearing a stale Adabas lock it runs
`scripts\seed-source.ps1`, which prepares the *source*. The Community Edition demo
database has a `VEHICLES` file with no VIN and no vehicle-type field, and no traffic-fine
file at all, so the lab manufactures them in Adabas: `ADADBM ADD_FIELDS` adds the two
fields to file 12 online, `ADAFDU` creates file 20 with a multiple-value field and a
periodic group, and two Natural programs fill them in. That is lab data preparation, not
migration — which is why `migrate.cmd` does not do it.

What happens (5 steps, ~3–6 min the first time while Oracle warms up):

1. `docker compose up -d --wait` — starts three containers: `a2o-adabas`,
   `a2o-natural`, `a2o-oracle`.
2. **Extract** — Natural programs (`EXTRVEH`, `EXTRFIN`) run headlessly inside the
   Natural container, read Adabas files 12 and 20, and write CSVs into `data\` plus a
   `manifest.json` with record counts.
3. **Clear** — target tables are emptied child-first (DELETE, so FKs don't complain).
4. **Transform + load** — a one-shot Apache Hop container runs the workflow
   `hop\workflows\migrate-all.hwf`, which runs the 5 pipelines in order and loads Oracle.
5. **Reconcile** — Oracle is compared against the CSVs/manifest. For the vehicle side the
   expectations are *derived* from the file, because that mapping is not 1:1.

Success looks like:

```
VERIFIED: 11/11
MIGRATION COMPLETE.
```

### The fast inner loop (use this while playing with mappings)

```bat
migrate.cmd --skip-extract
```

Skips the Adabas extract and reuses the CSVs already in `data\`. This is the
edit-mapping → run → check cycle: **well under a minute** (≈30 s of that is Hop's
JVM cold start — normal).

---

## 2. Key files — where everything lives

| Path | What it is | When you touch it |
|---|---|---|
| `migrate.cmd` | The one command (full run / `--skip-extract`) | Every run |
| `docker-compose.yml` | The whole lab: adabas, natural, oracle, hop-run | Rarely |
| `hop\pipelines\*.hpl` | **The mappings** — 10 vehicle, 20 plates, 30 fines, 40 offences (MU), 50 payments (PE) | **This is where you play** |
| `hop\workflows\migrate-all.hwf` | Runs the 5 pipelines in order | If you add a pipeline |
| `hop\metadata\rdbms\ORACLE_POC.json` | Hop's Oracle connection (`${ORACLE_HOST}`) | Rarely |
| `hop\project-config.json` | Hop project variables (`DATA_DIR`) | Rarely |
| `oracle-init\01_schema.sql` | Target model DDL (runs once on first Oracle start) | If you change the target model |
| `oracle-init\02_lookups.sql` | Seed rows for `CODE_LOOKUP`, `VEHICLE_TYPE`, `VEHICLE_TYPE_MAP` | If you add coded fields or a type mapping |
| `natural\EXTRVEH.NSP`, `EXTRFIN.NSP` | Natural extract programs (source of the CSVs) | If you change the extract |
| `natural\SEEDVEH.NSP`, `SEEDFIN.NSP` | **Lab data prep, not migration** — manufactures the VIN, the duplicate plate rows, the custom type codes and the fines | If you want different legacy data |
| `natural\TRAFFINE.fdt` | FDT of the traffic-fine file (MU + PE) | Only applies to a file that does not exist yet |
| `scripts\seed-source.ps1` | ADADBM + ADAFDU + the seed programs | After `docker compose down -v` (lab-up does it) |
| `scripts\reconcile.ps1` | The "VERIFIED: n/n" referee | If you add a table or change a rule |
| `data\` | Generated CSVs + `manifest.json` (runtime output, not versioned) | Look, don't edit |
| `FLAT_FILE_CONTRACT.md` | The extract ↔ mapping interface spec | Read once — explains the CSV shapes |

**Important mental model:** the extract writes *flat* CSVs (MU/PE repeating groups
become child CSVs with `parent_key` = Adabas ISN + `occurrence_index`). **All**
reshaping — surrogate keys, `YYYYMMDD`→`DATE`, code→description lookups, the VIN
de-duplication and the plate→vehicle resolution — lives only in the Hop pipelines.
`vehicles.csv` contains the duplicate rows exactly as Adabas holds them, VIN suffix and
all; deciding that `…0000011` is the same vehicle as `…0000001` is a *mapping* decision.

---

## 3. Apache Hop GUI — the mapping editor

The GUI is optional — `migrate.cmd` never needs it. Use it to see and edit the
mappings visually.

**Setup, once:** install the Apache Hop desktop client (2.18.1 or later), put
`ojdbc11.jar` in its `lib\jdbc\` folder, and set `HOP_HOME` to the install
directory. Then register this folder's `hop\` as a Hop project named **`a2o`**.

**To start it:** run `hop-gui.cmd` (in this folder). It reads `HOP_HOME`
(defaulting to `C:\hop` if unset) and launches `hop-gui.bat` from there. In the
GUI, pick project `a2o` if it isn't selected already.

⚠️ **`ORACLE_HOST` comes from the `local-gui` environment — select it once.**
Inside Docker the hostname is `oracle`; from your PC it is `localhost`. The value
therefore lives in a Hop **environment** on each side — `hop-env-local-gui.json`
(`localhost`, this GUI) and `hop-env-docker.json` (`oracle`, mounted into the
container) — and **not** in `hop\project-config.json`, because a *project*
variable beats an *environment* variable and would win on both sides at once,
breaking one of them. Select `local-gui` once via the environment icons; Hop
remembers the project+environment pair across restarts. Without it the GUI
resolves nothing usable and every run and **preview** dies with ORA-17868
(`Unknown host specified`). Setting `ORACLE_HOST` as an OS variable is not a
substitute — the container ignores it entirely.

### Things to try in the GUI

- **Open a pipeline:** File → Open → `pipelines\10_vehicle.hpl`. You'll see the
  canvas: CSV input → transforms → Oracle output.
- **Preview data at any point:** click a transform → **Preview** (the eye icon).
  This is the single most useful learning tool — you see the rows *as they look at
  that step*. Preview **cut base VIN** and then **number the plates** back to back and
  the de-duplication rule becomes obvious.
- **Run a single pipeline:** the ▶ button, run configuration `local`. (Oracle
  container must be up: `docker compose up -d oracle`, and clear tables first if
  you'll hit unique constraints — see §5.)
- **Test the DB connection:** Metadata perspective (left toolbar) →
  Relational Database Connections → `ORACLE_POC` → Test.
- **Inspect a transform:** double-click any step to see its configuration — the
  code lookup in `40_traffic_fine_offence.hpl` (offence code → description via
  `CODE_LOOKUP`) and the plate lookup in `30_traffic_fine.hpl` are the instructive ones.

---

## 4. Changing mappings and playing around

The safe loop:

1. Edit a pipeline in Hop GUI (or even the raw `.hpl` XML — it's readable).
2. Save.
3. `migrate.cmd --skip-extract`
4. Read the reconciliation report; query Oracle to see your change (§5).

Ideas, easy → harder:

- **Trace a field:** follow `offence_yyyymmdd` (numeric YYYYMMDD in
  `traffic_fines.csv`) through `30_traffic_fine.hpl` into the `DATE` column. Use
  Preview before/after.
- **Change a lookup:** edit a description in `oracle-init\02_lookups.sql`, then
  reseed by hand (§5) or add a row for a new code — and watch `offence_desc` change.
- **Add a derived column:** e.g. `outstanding` = `amount` minus the payments so far.
  You'll need the column in `01_schema.sql` (ALTER TABLE by hand, since the init
  script only runs on first start) plus the transform and output field in the pipeline.
- **Break it on purpose:** delete some rows from `data\traffic_fines.csv` (keep the
  header) and run `--skip-extract` — reconcile catches the manifest/CSV mismatch.
  Restore with a full `migrate.cmd`. This shows *why* the referee exists.
- **Add a whole new mapping:** new target table in Oracle + new `.hpl` + add it to
  `migrate-all.hwf` + a rule in `scripts\reconcile.ps1` — the full pattern a real
  migration repeats per Adabas file.

**Rules of the road:** reference files via `${DATA_DIR}` (never hardcoded paths),
and remember `data\` is regenerated by every full run — don't store anything there.

---

## 5. Accessing the Oracle database

Connection facts:

| | |
|---|---|
| Host / port | `localhost` : `1521` |
| Service name | `FREEPDB1` |
| Schema / user | `POCAPP` / password `pocapp` |
| Admin | `SYS` / `PocSysPwd1` (as SYSDBA) — rarely needed |
| Tables | `VEHICLE`, `VEHICLE_PLATE`, `TRAFFIC_FINE`, `TRAFFIC_FINE_OFFENCE`, `TRAFFIC_FINE_PAYMENT`, `MIGRATION_REJECT`, `CODE_LOOKUP`, `VEHICLE_TYPE`, `VEHICLE_TYPE_MAP` |

### Zero-install option: sqlplus inside the container

Always works, nothing to set up:

```bat
docker exec -it a2o-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
```

```sql
SELECT COUNT(*) FROM vehicle;
SELECT v.vin, v.owner_national_id, f.fine_no, f.amount, f.status
  FROM vehicle v JOIN traffic_fine f ON f.vehicle_id = v.vehicle_id
 WHERE ROWNUM <= 10;
```

### GUI client — since you already use Eclipse

- **Recommended: DBeaver Community** (free). It *is* an Eclipse-based application,
  so it will feel immediately familiar — same workbench, same shortcuts. New
  Connection → Oracle → host `localhost`, port `1521`, **Service name** `FREEPDB1`
  (not SID), user `pocapp`/`pocapp`. It offers to download the JDBC driver, or
  point it at `hop\lib\ojdbc11.jar`. You get a table browser, ER diagrams, and a
  proper SQL editor — worth the one small install for a day of exploring.
- **Inside your existing Eclipse:** the Data Tools Platform (Database Development
  perspective) can do it with the same ojdbc jar, but it's clunky and dated —
  workable if you refuse any new install, otherwise DBeaver is the better hour.
- **Not worth it here:** Oracle SQL Developer — fine, but a heavier install and no
  advantage over DBeaver for this lab.

### Useful admin snippets

```bat
:: re-run just the reconciliation report
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\reconcile.ps1

:: empty the migrated tables (child-first) without a full run
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\clear-tables.ps1
```

To re-apply the DDL from scratch (e.g. after schema experiments went sideways):
`docker compose down -v` deletes the Oracle **and Adabas** volumes, then
`scripts\lab-up.ps1` recreates everything — `oracle-init\*.sql` runs again on the fresh
Oracle, and the Adabas source is re-prepared (fields, file 20, all the seeded data),
which is why you want `lab-up.ps1` here and not a bare `migrate.cmd`. This is the
clean-slate button — first start takes a few minutes again.

---

## 6. Peeking at the other stages

- **The extract CSVs:** open `data\traffic_fines.csv` and
  `data\traffic_fine_offences.csv` side by side — you can see the MU flattening
  (`parent_key` = ISN, `occurrence_index`). `manifest.json` holds the counts the
  extract itself reported.
- **Run only the extract:**
  `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\extract.ps1`
- **The Natural side:** `natural\EXTRFIN.NSP` is a readable Natural program —
  READ loop, `C*OFFENCE-CODE` to get the occurrence count, `WRITE WORK FILE`, one line
  per record/occurrence. It runs via a headless stacked session (CE has no batch mode —
  see README "Spike findings").
- **The Adabas side directly:**
  `docker exec a2o-adabas sh -lc "adarep db=1 fdt file=20"` shows the traffic-fine FDT,
  including the `MU` option on `AH` and the `PE` group `AP`.
- **Watch Hop's log during a run:** step 4's output scrolls by in `migrate.cmd`;
  for more detail set `HOP_LOG_LEVEL: Detailed` in `docker-compose.yml` (hop-run
  service) temporarily.

---

## 7. The transformations, step by step

This is the part worth an hour. Nothing between the CSVs and the target model is a
row-for-row copy.

### 7.1 One row per plate → one row per vehicle

The old system had nowhere to record a second registration plate, so the vehicle was
registered *again* — same VIN plus a character past position 17, and **a completely
different plate number** in `plate_no`:

```bat
findstr "FIAZZ1JZW00000009" data\vehicles.csv
```

```
isn  plate_no   …  vin
9    537MN75    …  FIAZZ1JZW00000009      <- the original registration
792  90000019   …  FIAZZ1JZW000000091     <- second plate, same car
793  90000020   …  FIAZZ1JZW000000092
794  90000021   …  FIAZZ1JZW000000093     <- these three exceed the limit
795  90000022   …  FIAZZ1JZW000000094        and are rejected (§7.2)
796  90000023   …  FIAZZ1JZW000000095
```

Six rows, one car, six unrelated-looking registrations — the VIN suffix is the *only*
thing tying them together, which is exactly why the de-duplication has to key on it.
The mapping rule is four transforms in
`10_vehicle.hpl` — **cut base VIN** (`StringCut`, characters 0–17) → **sort by VIN** →
**number the plates** (`FieldsChangeSequence`, resetting on `vin_base`) → **first row per
VIN** (`FilterRows` on `plate_seq = 1`). Sorting on the *full* VIN is what makes the
un-suffixed row come first, so plate 1 is also the row whose make/model/colour are
authoritative.

`20_vehicle_plate.hpl` re-derives exactly the same grouping and keeps every row instead
of the first. See the result:

```sql
SELECT v.vin, v.make, v.model,
       LISTAGG(p.plate_seq || ':' || p.plate_no, '  ')
         WITHIN GROUP (ORDER BY p.plate_seq) AS plates
  FROM vehicle v JOIN vehicle_plate p ON p.vehicle_id = v.vehicle_id
 GROUP BY v.vin, v.make, v.model
HAVING COUNT(*) > 1
 ORDER BY v.vin;
```

### 7.2 The fourth plate — quarantined, not dropped

The new model allows 1–3 plates (`PRIMARY KEY (vehicle_id, plate_seq)` plus
`CHECK (plate_seq BETWEEN 1 AND 3)`), and six seeded vehicles deliberately have four, five
or six. The surplus rows go to `MIGRATION_REJECT` with a reason, because a migration that
silently drops what does not fit cannot be reconciled. That is what the `plates in = out`
line of the report asserts.

`MIGRATION_REJECT` collects **two different kinds** of casualty — look at both:

```sql
SELECT source_file, reason, COUNT(*) FROM migration_reject GROUP BY source_file, reason;

SELECT source_isn, reason, detail FROM migration_reject ORDER BY source_file, source_isn;
```

35 rows in a normal run: 10 surplus plates and 25 fines whose plate matched no vehicle.
Each `detail` names what was actually lost — the plate number and the VIN it belonged to,
or the fine number and the plate it was written against — because a quarantine table that
only says "something failed" gives whoever reads it nothing to act on. Both `detail`
strings are built by small JavaScript transforms (`describe lost plate`,
`describe orphan fine`).

### 7.3 Custom type codes → standard types

`veh_type` holds whatever the legacy application wrote. `VEHICLE_TYPE_MAP` translates it
and the original is kept in `vehicle.source_vehicle_type` for lineage:

```sql
SELECT v.source_vehicle_type, v.vehicle_type_code, t.description, COUNT(*)
  FROM vehicle v JOIN vehicle_type t ON t.type_code = v.vehicle_type_code
 GROUP BY v.source_vehicle_type, v.vehicle_type_code, t.description
 ORDER BY 2, 1;
```

`X-OLD` is **deliberately absent** from the mapping table, so seven vehicles land on
`UN` (Unknown) instead of failing the load. Unmapped is a fact to report, not an error —
and because the original code survives, those rows stay findable.

### 7.4 A fine knows a plate, not a vehicle

This is where the plate table pays off. Fines are raised against whatever the camera
read, so three fines written against three *different* plate strings belong to one car:

```sql
SELECT f.fine_no, f.plate_no, TO_CHAR(f.offence_date,'YYYY-MM-DD') AS offence_date,
       f.amount, f.status
  FROM traffic_fine f JOIN vehicle v ON v.vehicle_id = f.vehicle_id
 WHERE v.vin = 'RENZZ1JZW00000001'
 ORDER BY f.fine_no;
```

An unmatched plate is normal — foreign or long-deregistered vehicles. Those fines still
load, with `vehicle_id` NULL, *and* get a `MIGRATION_REJECT` row so they are visible
rather than quietly orphaned. That is why the **resolve status** transform has
`distribute = N`: it **copies** its rows to both branches instead of round-robining them.

**One cascade is worth understanding**, because it is the kind of thing that only appears
once two rules meet: the fourth plate was rejected, so it is not in `VEHICLE_PLATE`, so a
fine written against *that* plate cannot resolve either. Both ends show up:

```sql
SELECT source_file, source_isn, reason, detail FROM migration_reject ORDER BY reject_id;
```

`reconcile.ps1` models this deliberately — it builds its expected plate set with the same
top-3 rule the mapping uses, not from every plate in the file. Getting that wrong is
what made the referee disagree with a correct load the first time it ran.

### 7.5 Deriving what the source does not contain — the scripting one

The target model classifies every vehicle **EV / PHEV / HEV / PETROL**. Adabas holds no
such field. This is the hardest transformation in the lab and the only one that needs a
script, so it is worth walking slowly.

**Step 1 — accept that the VIN cannot be decoded by a formula.** Positions 1–3
(manufacturer) and 10 (model year) are standardised worldwide; positions 4–8 are the
manufacturer's *private* descriptor. Nothing says "position 8 is fuel type". That is why
NHTSA publishes the vPIC decode **database** rather than an algorithm — and why the rules
here live in a table:

```sql
SELECT rule_id, vin_pattern, powertrain_code, note FROM vin_powertrain_rule ORDER BY rule_id;
```

`_` matches exactly one character, so you can *see* which position matters:
`FOR_E____________` is Ford position 5, `BMW____I_________` is BMW position 8 — the same
concept in two places with two alphabets, because that is what real manufacturers do.
Every other make has no rule at all.

The **match VIN rule** transform (`DBJoin`) runs one statement per row:

```sql
SELECT powertrain_code AS "rule_powertrain" FROM pocapp.vin_powertrain_rule
 WHERE ? LIKE vin_pattern ORDER BY priority, rule_id
```

⚠️ It is an **outer** join on purpose. Most vehicles match nothing, and an inner join
would silently drop them.

**Step 2 — the script.** Open **derive powertrain** in `10_vehicle.hpl` (Hop GUI, or just
read the XML). It does two things a built-in transform cannot: normalise free text, and
apply a precedence cascade with provenance.

```bat
:: what the clerks actually typed, over 30 years
powershell -Command "(Import-Csv data\vehicles.csv | Group-Object fuel_desc | Select-Object Count,Name | Sort-Object Name)"
```

`PETROL`, `petrol`, `GASOLINE`, `BENZIN`, `ELEC.`, `EV`, `BATTERY ONLY`, `HYBRID`, `HYB`,
`HEV SELF CHG`, `PLUG-IN HYBRID`, `PHEV`, `PLUGIN HYB`, `N/A`, blank. See how each one
landed:

```sql
SELECT NVL(source_fuel_desc,'(blank)') AS legacy_text, powertrain_code, COUNT(*) AS n
  FROM vehicle WHERE powertrain_source IN ('FUEL_DESC','UNKNOWN')
 GROUP BY source_fuel_desc, powertrain_code ORDER BY 2, 1;
```

**The single most important line in that script** is the comment above the `if` chain.
`PLUG-IN HYBRID` *contains* `HYBRID`. Test hybrid first and every PHEV in the database
silently becomes an HEV — and the migration still reconciles perfectly, because no row
count changes. Wrong answers that pass reconciliation are the ones that reach production.

**Step 3 — precedence and provenance.** The VIN beats the text (the manufacturer stamped
one; a clerk typed the other). Where they disagree the row still loads and *says so*:

```sql
SELECT powertrain_source, COUNT(*) FROM vehicle GROUP BY powertrain_source ORDER BY 2 DESC;

SELECT vin, make, source_fuel_desc AS legacy_text, powertrain_code
  FROM vehicle WHERE powertrain_source = 'VIN_RULE_CONFLICT' AND ROWNUM <= 5;
```

You'll see Fords whose VIN says `E` (electric) while the paperwork says `HYBRID` or
`PETROL`. A derived value with no record of *how* it was derived cannot be argued about
two years later, which is why `powertrain_source` is a stored column and not a comment.

**Step 4 — how the referee checks a script without re-running it.** `reconcile.ps1` does
not re-implement the JavaScript; that would only prove the logic agrees with itself. It
asserts two things instead: every vehicle ended up classified (`UN` is an answer, `NULL`
is a bug), and the VIN-derived count matches patterns re-read from the rule table and
applied with PowerShell's `-like` — a different language and a different matching engine
reaching the same number.

### 7.6 MU and PE — the Adabas-shaped part

One fine can carry several offences (a multiple-value field) and several part payments
(a periodic group). Both become child tables:

```sql
SELECT f.fine_no, f.amount, f.status,
       LISTAGG(o.offence_code || ' ' || o.offence_desc, ' | ')
         WITHIN GROUP (ORDER BY o.seq_no) AS offences
  FROM traffic_fine f JOIN traffic_fine_offence o ON o.fine_id = f.fine_id
 GROUP BY f.fine_no, f.amount, f.status
HAVING COUNT(*) > 2 AND ROWNUM <= 5;

SELECT f.fine_no, p.seq_no, TO_CHAR(p.paid_date,'YYYY-MM-DD') AS paid,
       p.paid_amount, p.method
  FROM traffic_fine_payment p JOIN traffic_fine f ON f.fine_id = p.fine_id
 WHERE f.fine_no = 'F000000012'
 ORDER BY p.seq_no;
```

A useful sanity query, and a real reconciliation idea: paid fines whose payments do not
add up to the amount.

```sql
SELECT f.fine_no, f.amount, SUM(p.paid_amount) AS paid
  FROM traffic_fine f JOIN traffic_fine_payment p ON p.fine_id = f.fine_id
 GROUP BY f.fine_no, f.amount
HAVING SUM(p.paid_amount) <> f.amount;
```

### Things to try

- **Add a mapping for `X-OLD`:** insert a row into `vehicle_type_map` (§5 for how to run
  SQL) — plus the same row in `oracle-init\02_lookups.sql` and `VEHICLE_TYPE_MAP` = 10 in
  `$seedRules` — then `migrate.cmd --skip-extract`. `VEHICLE type mapped` moves from 766
  to 773 **on its own**: it is computed against the mapping table, not hard-coded. The
  seed check is the part you must update by hand, and it is deliberately unforgiving — it
  exists so that seed data and the counts asserting it cannot drift apart quietly.
- **Raise the plate limit to 4:** three places, because three layers encode the same rule
  — `ALTER TABLE vehicle_plate DROP CONSTRAINT ck_vehicle_plate_seq` then add it back with
  `BETWEEN 1 AND 4`; the `3` in the **at most 3 plates** filter of `20_vehicle_plate.hpl`;
  and `$MAX_PLATES` in `scripts\reconcile.ps1`. Re-run and watch **two** things move: the
  plate count, and the fine that could not resolve because its plate had been rejected.
- **Break the sort on purpose:** disable **sort by VIN** in `20_vehicle_plate.hpl` and
  re-run. `FieldsChangeSequence` only resets when the group value *changes*, so unsorted
  input produces wrong plate numbers — and the run fails on a primary-key violation rather
  than quietly loading nonsense. Worth seeing once.
- **Move the duplicates:** change `#BASE-ISN` / `#EXTRAS` in `natural\SEEDVEH.NSP`, re-run
  `scripts\seed-source.ps1` (it deletes the previous run's rows first), then a full
  `migrate.cmd`. Every expected number shifts and the report should still say 11/11. That
  tests the rule, not the specific data.
- **Add an offence code the lookup does not know:** add it to `#OFFCD` in
  `natural\SEEDFIN.NSP` but not to `oracle-init\02_lookups.sql`, re-seed, re-run. It loads
  with `offence_desc = 'Unknown'` — the same forgiving pattern as the vehicle types.
- **Break the powertrain script on purpose** (do this one): in `derive powertrain`, move
  the `HYB`/`HEV` test *above* the `PLUG`/`PHEV` test and re-run. Every PHEV becomes an
  HEV, ~163 rows are now wrong — **and the report still says 11/11**, because no count
  changed. Then look at `SELECT powertrain_code, COUNT(*) FROM vehicle GROUP BY 1` and
  compare with what it said before. This is the most useful five minutes in the guide: it
  shows exactly what row-count reconciliation *cannot* catch, and why a derived field
  needs its own content check.
- **Teach the script a new spelling:** add something like `'ESSENCE'` or `'GASOLINA'` to
  `#FUELD` in `natural\SEEDVEH.NSP`, re-seed and re-run. It lands on `UN` and the unknown
  count rises — visibly, not silently. Then add the pattern to the script and watch it
  move. That loop is what maintaining a real derivation feels like.
- **Add a manufacturer to the VIN rules:** two halves, and it is worth feeling the
  difference. The *rule* is data — one INSERT into `vin_powertrain_rule` (plus the
  `$seedRules` count). The *signal* it matches is lab data — `#PTCHF`-style handling in
  `SEEDVEH.NSP`. In production you would only ever do the first half.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `migrate.cmd` fails at step 1 | Docker Desktop not running — start it, retry. |
| Extract fails with Adabas response **48/8** | Stale ET user from an aborted session: `docker exec a2o-adabas adaopr db=1 display=uq` to find it, `adaopr db=1 stop=<id>`; or just retry — each run uses a unique `etid`. |
| Adabas container aborts, log shows `CONCURRLOCKHOST` | Host-bound lock in the volume: `docker compose down`, then delete `/data/db001/_DB_LOCK` via a temp container, or `docker compose down -v` (nukes data — `lab-up.ps1` rebuilds). |
| Hop load fails with **ORA-00001** (unique constraint) | Tables weren't cleared before loading — run `scripts\clear-tables.ps1`, then re-run the Hop step. `migrate.cmd` normally does this for you. |
| Hop GUI can't reach Oracle — **ORA-17868 `Unknown host specified: oracle`** on run *or* preview | The `local-gui` environment isn't active, so `${ORACLE_HOST}` fell through to a Docker-internal name your PC can't resolve. Select `local-gui` via the environment icons (left panel). Check too that `hop\project-config.json` has **no** `ORACLE_HOST` variable — a project variable overrides the environment and re-breaks this. |
| Hop GUI can't reach Oracle (other errors) | The GUI's `lib\jdbc` lacks `ojdbc11.jar`, or the Oracle container is down (`docker ps`). |
| Container run fails with **ORA-17868 `${ORACLE_HOST}`** (the literal string) | The `hop-env-docker.json` mount or the `HOP_ENVIRONMENT_*` variables are missing from the `hop-run` service in `docker-compose.yml`. An OS env var alone does not work — the image does not turn it into a Hop variable. |
| **Hop GUI opens the `samples` project instead of `a2o`** | The GUI reopens whatever the *newest* `*-open.event` in `%HOP_HOME%\audit\projects\project\` names (environment likewise in `...\audit\projects\environment\`), and falls back to `samples` when that name is unknown or the event is unreadable. Fastest fix: pick `a2o` once via the diamond icons in the left panel — Hop then records it and reopens it from then on. Editing it by hand works too, but only with the GUI **closed** (it rewrites config and audit on exit) and only as **BOM-less UTF-8** (PowerShell 5.1 `-Encoding utf8` adds a BOM → the event is silently discarded). `defaultProject` in `hop-config.json`, `last-projects.list`, and `HOP_PROJECT_NAME` do **not** control this — the last is Hop Web only. |
| First run very slow / oracle unhealthy | Normal on first start (Oracle initializes ~2–4 min). `docker compose logs -f oracle` to watch. |
| Reconcile says manifest/CSV mismatch | You hand-edited a CSV (fine for experiments) — run a full `migrate.cmd` to regenerate. |
| Extract stops with **"vehicles.csv carries no VIN"** or **"file 20 holds no traffic fines"** | The Adabas source has not been prepared — run `scripts\seed-source.ps1` (or `scripts\lab-up.ps1`). Expected after any `docker compose down -v`. |
| Reconcile throws **"VIN shorter than 17 characters"** | The base-VIN grouping rule no longer holds for some row, so de-duplication would merge unrelated vehicles. Check what `SEEDVEH.NSP` wrote before touching the mappings. |
| `20_vehicle_plate` fails with **ORA-00001 on `PK_VEHICLE_PLATE`** | Plate numbering went wrong — almost always because the rows reaching `FieldsChangeSequence` are not sorted by `vin_base`. |
| An amount is exactly 100× too big | `COMPRESS` on an Adabas packed field drops the decimal point. Use `MOVE EDITED … (EM=ZZZZ9.99)` in the extract, as `EXTRFIN.NSP` does. |

---

## 9. Suggested plan for today

1. `scripts\lab-up.ps1`, then `migrate.cmd` — see `VERIFIED: 11/11` once, end to end.
2. sqlplus (or DBeaver): query the tables, join `vehicle` ↔ `vehicle_plate` ↔
   `traffic_fine`, look at the MU/PE children of one fine.
3. Work through §7 — the de-duplication, the quarantined fourth plate, the type
   replacement, and how a fine finds its car. This is the part that shows what a
   migration actually has to do.
4. Open `10_vehicle.hpl` and `30_traffic_fine.hpl` in Hop GUI, Preview each step.
5. Make one small mapping change → `migrate.cmd --skip-extract` → see it in Oracle.
6. If appetite remains: the "break it on purpose" exercises from §4 and §7.
