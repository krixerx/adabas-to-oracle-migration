# Rebuild the Oracle target schema from the DDL, in seconds, without touching
# Adabas and without re-initialising the database.
#
#     scripts\reset-oracle.ps1
#
# WHAT IT IS FOR. Not speed - clearing between runs is what
# hop\sql\00_clear_targets.sql does, and TRUNCATE is already as fast as it gets
# at any row count. This is for a KNOWN STATE: before a demo, after an aborted
# run, or whenever the schema itself has changed. It gives you
#   - tables exactly as oracle-init\01_schema.sql declares them today,
#   - IDENTITY counters back at 1, so surrogate keys start from 1 again,
#   - no chance of a foreign key left DISABLED by a clear that died half way,
#   - lookup tables reseeded and asserted against the counts reconcile.ps1 uses.
#
# `docker compose down -v` achieves the same and more, but it re-initialises the
# whole database (minutes) and destroys the Adabas side with it, which then has
# to be re-seeded through Natural. This touches only POCAPP.
#
# ⚠️ It DROPS the migrated data. That is the point, but there is no undo and no
# prompt - re-run migrate.cmd afterwards.
#
# Tables that belong to something else - the PROFILE_* and DQ_* tables from
# examples\data-cleansing - are deliberately left alone. Resetting the migration
# is not a licence to delete somebody's experiment.
[CmdletBinding()]
param()
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent

# Leading blank line: a here-string piped into sqlplus carries a BOM, reported
# as SP2-0734 against line 1.
function Invoke-SqlText([string]$body, [string]$what) {
    $sql = "`nWHENEVER SQLERROR EXIT SQL.SQLCODE`nSET FEEDBACK OFF`n" + $body
    $out = $sql | docker exec -i a2o-oracle sqlplus -s "sys/PocSysPwd1@//localhost:1521/FREE as sysdba"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out -join "`n")
        Write-Error "$what failed (sqlplus exit $LASTEXITCODE)"
        exit 1
    }
    # See resize-redo.ps1: the piped here-string carries a BOM and sqlplus says so.
    return @($out | ForEach-Object { ($_ -replace "﻿", "").Trim() } |
                    Where-Object { $_ -notmatch '^(SP2-0042|Help: https)' })
}

docker exec a2o-oracle true 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "a2o-oracle is not running. Start the lab first: scripts\lab-up.ps1"
    exit 1
}

Write-Host ""
Write-Host "Resetting the POCAPP schema ..." -ForegroundColor Cyan

# --- 1. drop ------------------------------------------------------------------
# By name, not by "everything POCAPP owns". CASCADE CONSTRAINTS so the order
# does not matter; PURGE so the recycle bin does not quietly keep a copy of a
# million-row table in the tablespace. The stg_/ext_ prefixes are matched rather
# than listed because 03_staging.sql generates them and the list would drift.
$drop = @'
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  FOR t IN (SELECT table_name FROM all_tables
             WHERE owner = 'POCAPP'
               AND (table_name IN ('TRAFFIC_FINE_OFFENCE','TRAFFIC_FINE_PAYMENT','TRAFFIC_FINE',
                                   'VEHICLE_PLATE','MIGRATION_REJECT','VEHICLE',
                                   'VIN_POWERTRAIN_RULE','POWERTRAIN_TYPE',
                                   'VEHICLE_TYPE_MAP','VEHICLE_TYPE','CODE_LOOKUP')
                    OR SUBSTR(table_name, 1, 4) IN ('STG_','EXT_')))
  LOOP
    EXECUTE IMMEDIATE 'DROP TABLE pocapp.' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
  END LOOP;
END;
/
EXIT;
'@
Invoke-SqlText $drop "drop" | Out-Null
Write-Host "  dropped the migration tables"

# --- 2. reapply the DDL -------------------------------------------------------
# The same files the container runs on first start, in the same order and as the
# same user. One source of truth: if these stop working here they were already
# broken for a fresh lab.
foreach ($f in @("01_schema.sql", "02_lookups.sql", "03_staging.sql")) {
    $path = Join-Path $pocRoot "oracle-init\$f"
    if (-not (Test-Path $path)) { throw "missing $path" }
    Invoke-SqlText (Get-Content $path -Raw) $f | Out-Null
    Write-Host "  applied oracle-init\$f"
}

# --- 3. prove it ---------------------------------------------------------------
# The seed counts are the same ones scripts\reconcile.ps1 asserts. Checking them
# here means a reset that half-worked fails now, rather than as a puzzling
# reconciliation failure two steps later.
$verify = @'
SET HEADING OFF
SET PAGESIZE 0
SET LINESIZE 200
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT CASE WHEN (SELECT COUNT(*) FROM pocapp.code_lookup)         = 13
             AND (SELECT COUNT(*) FROM pocapp.vehicle_type)        =  6
             AND (SELECT COUNT(*) FROM pocapp.vehicle_type_map)    =  9
             AND (SELECT COUNT(*) FROM pocapp.powertrain_type)     =  5
             AND (SELECT COUNT(*) FROM pocapp.vin_powertrain_rule) =  8
             AND (SELECT COUNT(*) FROM pocapp.vehicle)             =  0
             AND (SELECT COUNT(*) FROM pocapp.traffic_fine)        =  0
            THEN 'OK' ELSE 'SEEDS WRONG' END FROM dual;
EXIT;
'@
# @(...) because PowerShell unwraps a single-element array out of a function.
$res = @(Invoke-SqlText $verify "verify" | Where-Object { $_ -match '\S' })
if ($res -notcontains 'OK') {
    Write-Host ($res -join "`n")
    Write-Error "the schema was rebuilt but the seed counts are not what reconcile.ps1 expects"
    exit 1
}

Write-Host "  schema rebuilt, lookups reseeded, target tables empty." -ForegroundColor Green
Write-Host "  next: migrate.cmd  (or migrate.cmd --staging)"
Write-Host ""
exit 0
