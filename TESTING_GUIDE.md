# Adabas → Oracle Migration — Hands-On Testing & Learning Guide

How to run the POC, explore it, change mappings, and look at the data.
Everything happens in the repository root — open a terminal there first.

---

## 1. Quick start — run the whole thing

```bat
migrate.cmd
```

Prerequisite: **Docker Desktop must be running** (all images were already pulled;
no internet needed).

What happens (5 steps, ~3–6 min the first time while Oracle warms up):

1. `docker compose up -d --wait` — starts three containers: `a2o-adabas`,
   `a2o-natural`, `a2o-oracle`.
2. **Extract** — Natural programs (`EXTREMP`, `EXTRVEH`) run headlessly inside the
   Natural container, read the real Adabas demo files (EMPLOYEES + VEHICLES), and
   write CSVs into `data\` plus a `manifest.json` with record counts.
3. **Clear** — target tables are emptied child-first (DELETE, so FKs don't complain).
4. **Transform + load** — a one-shot Apache Hop container runs the workflow
   `hop\workflows\migrate-all.hwf`, which runs the 5 pipelines in order and loads Oracle.
5. **Reconcile** — row counts in Oracle are compared against the CSVs/manifest.

Success looks like:

```
VERIFIED: 5/5
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
| `hop\pipelines\*.hpl` | **The mappings** — one per target table (10=employee, 20=address lines, 30=languages, 40=income, 50=vehicle) | **This is where you play** |
| `hop\workflows\migrate-all.hwf` | Runs the 5 pipelines in order | If you add a pipeline |
| `hop\metadata\rdbms\ORACLE_POC.json` | Hop's Oracle connection (`${ORACLE_HOST}`) | Rarely |
| `hop\project-config.json` | Hop project variables (`DATA_DIR`, `ORACLE_HOST`) | Rarely |
| `oracle-init\01_schema.sql` | Target model DDL (runs once on first Oracle start) | If you change the target model |
| `oracle-init\02_lookups.sql` | Seed rows for `CODE_LOOKUP` | If you add coded fields |
| `natural\EXTREMP.NSP`, `EXTRVEH.NSP` | Natural extract programs (source of the CSVs) | If you change the extract |
| `natural\run-extract.sh` | Installs + runs the Natural programs in the container | Rarely |
| `scripts\reconcile.ps1` | The "VERIFIED: n/n" referee — expected-count rules per table | If you add a table |
| `data\` | Generated CSVs + `manifest.json` (runtime output, not versioned) | Look, don't edit |
| `FLAT_FILE_CONTRACT.md` | The extract ↔ mapping interface spec | Read once — explains the CSV shapes |

**Important mental model:** the extract writes *flat* CSVs (MU/PE repeating groups
become child CSVs with `parent_key` = Adabas ISN + `occurrence_index`). **All**
reshaping — surrogate keys, YYYYMMDD→DATE, code→description lookups, the
vehicle→employee join — lives only in the Hop pipelines.

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

- **Open a pipeline:** File → Open → `pipelines\10_employee.hpl`. You'll see the
  canvas: CSV input → transforms → Oracle output.
- **Preview data at any point:** click a transform → **Preview** (the eye icon).
  This is the single most useful learning tool — you see the rows *as they look at
  that step*, e.g. before and after the YYYYMMDD→DATE conversion.
- **Run a single pipeline:** the ▶ button, run configuration `local`. (Oracle
  container must be up: `docker compose up -d oracle`, and clear tables first if
  you'll hit unique constraints — see §5.)
- **Test the DB connection:** Metadata perspective (left toolbar) →
  Relational Database Connections → `ORACLE_POC` → Test.
- **Inspect a transform:** double-click any step to see its configuration — the
  lookup step in `10_employee.hpl` (marital code → description via `CODE_LOOKUP`)
  and the stream-lookup join in `50_vehicle.hpl` (personnel_id → emp_id) are the
  instructive ones.

---

## 4. Changing mappings and playing around

The safe loop:

1. Edit a pipeline in Hop GUI (or even the raw `.hpl` XML — it's readable).
2. Save.
3. `migrate.cmd --skip-extract`
4. Read the reconciliation report; query Oracle to see your change (§5).

Ideas, easy → harder:

- **Trace a field:** follow `BIRTH-DATE` (numeric YYYYMMDD in `employees.csv`)
  through `10_employee.hpl` into the `DATE` column. Use Preview before/after.
- **Change a lookup:** edit a description in `oracle-init\02_lookups.sql`, then
  reseed by hand (§5) or add a row for a new code — and watch `marital_status` change.
- **Add a derived column:** e.g. `full_name` = first + last name. You'll need all
  three layers: column in `01_schema.sql` (ALTER TABLE by hand, since the init
  script only runs on first start), the transform + output field in
  `10_employee.hpl`, done — reconcile still passes because row counts don't change.
- **Break it on purpose:** delete some rows from `data\employees.csv` (keep the
  header) and run `--skip-extract` — reconcile catches the manifest/CSV mismatch.
  Restore with a full `migrate.cmd`. This shows *why* the referee exists.
- **Add a whole new mapping:** new target table in Oracle + new `.hpl` + add it to
  `migrate-all.hwf` + a rule in `scripts\reconcile.ps1` (`$rules`) — the full
  pattern a real migration repeats per Adabas file.

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
| Tables | `EMPLOYEE`, `EMPLOYEE_ADDRESS_LINE`, `EMPLOYEE_LANGUAGE`, `EMPLOYEE_INCOME`, `VEHICLE`, `CODE_LOOKUP` |

### Zero-install option: sqlplus inside the container

Always works, nothing to set up:

```bat
docker exec -it a2o-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
```

```sql
SELECT COUNT(*) FROM employee;
SELECT e.last_name, v.make, v.model
  FROM employee e JOIN vehicle v ON v.emp_id = e.emp_id
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
`docker compose down -v` deletes the Oracle **and Adabas** volumes; the next
`migrate.cmd` recreates everything, and `oracle-init\*.sql` runs again on the fresh
Oracle. This is the clean-slate button — first start takes a few minutes again.

---

## 6. Peeking at the other stages

- **The extract CSVs:** open `data\employees.csv` and
  `data\employees_address_lines.csv` side by side — you can see the MU flattening
  (`parent_key` = ISN, `occurrence_index`). `manifest.json` holds the counts the
  extract itself reported.
- **Run only the extract:**
  `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\extract.ps1`
- **The Natural side:** `natural\EXTREMP.NSP` is a readable Natural program —
  READ loop, `WRITE WORK FILE`, one line per record/occurrence. It runs via a
  headless stacked session (CE has no batch mode — see README "Spike findings").
- **Watch Hop's log during a run:** step 4's output scrolls by in `migrate.cmd`;
  for more detail set `HOP_LOG_LEVEL: Detailed` in `docker-compose.yml` (hop-run
  service) temporarily.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `migrate.cmd` fails at step 1 | Docker Desktop not running — start it, retry. |
| Extract fails with Adabas response **48/8** | Stale ET user from an aborted session: `docker exec a2o-adabas adaopr db=1 display=uq` to find it, `adaopr db=1 stop=<id>`; or just retry — each run uses a unique `etid`. |
| Adabas container aborts, log shows `CONCURRLOCKHOST` | Host-bound lock in the volume: `docker compose down`, then delete `/data/db001/_DB_LOCK` via a temp container, or `docker compose down -v` (nukes data — full rerun rebuilds). |
| Hop load fails with **ORA-00001** (unique constraint) | Tables weren't cleared before loading — run `scripts\clear-tables.ps1`, then re-run the Hop step. `migrate.cmd` normally does this for you. |
| Hop GUI can't reach Oracle — **ORA-17868 `Unknown host specified: oracle`** on run *or* preview | The `local-gui` environment isn't active, so `${ORACLE_HOST}` fell through to a Docker-internal name your PC can't resolve. Select `local-gui` via the environment icons (left panel). Check too that `hop\project-config.json` has **no** `ORACLE_HOST` variable — a project variable overrides the environment and re-breaks this. |
| Hop GUI can't reach Oracle (other errors) | The GUI's `lib\jdbc` lacks `ojdbc11.jar`, or the Oracle container is down (`docker ps`). |
| Container run fails with **ORA-17868 `${ORACLE_HOST}`** (the literal string) | The `hop-env-docker.json` mount or the `HOP_ENVIRONMENT_*` variables are missing from the `hop-run` service in `docker-compose.yml`. An OS env var alone does not work — the image does not turn it into a Hop variable. |
| **Hop GUI opens the `samples` project instead of `a2o`** | The GUI reopens whatever the *newest* `*-open.event` in `%HOP_HOME%\audit\projects\project\` names (environment likewise in `...\audit\projects\environment\`), and falls back to `samples` when that name is unknown or the event is unreadable. Fastest fix: pick `a2o` once via the diamond icons in the left panel — Hop then records it and reopens it from then on. Editing it by hand works too, but only with the GUI **closed** (it rewrites config and audit on exit) and only as **BOM-less UTF-8** (PowerShell 5.1 `-Encoding utf8` adds a BOM → the event is silently discarded). `defaultProject` in `hop-config.json`, `last-projects.list`, and `HOP_PROJECT_NAME` do **not** control this — the last is Hop Web only. |
| First run very slow / oracle unhealthy | Normal on first start (Oracle initializes ~2–4 min). `docker compose logs -f oracle` to watch. |
| Reconcile says manifest/CSV mismatch | You hand-edited a CSV (fine for experiments) — run a full `migrate.cmd` to regenerate. |

---

## 8. Suggested plan for today

1. `migrate.cmd` — see `VERIFIED: 5/5` once, end to end.
2. sqlplus (or DBeaver): query the tables, join `employee` ↔ `vehicle`, look at the
   MU/PE children of one employee.
3. Open `10_employee.hpl` in Hop GUI, Preview each step, understand the flow.
4. Make one small mapping change → `migrate.cmd --skip-extract` → see it in Oracle.
5. If appetite remains: the "add a derived column" or "break it on purpose"
   exercises from §4.
