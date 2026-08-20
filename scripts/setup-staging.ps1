# Applies oracle-init\03_staging.sql to a lab that already exists.
#
#     scripts\setup-staging.ps1
#
# oracle-init\ only runs on the FIRST container start, so a lab created before
# the staging layer existed has none of it. This script applies the same file -
# one source of truth, no second copy of the DDL to drift - and it is idempotent,
# so running it again is harmless.
#
# It also recreates the oracle container if the ./data bind mount is missing.
# Oracle reads the contract CSVs as external tables from /opt/oracle/a2o-data,
# and a container started before that mount existed cannot see them. Recreating
# does NOT lose data: the datafiles live in the oracle-data named volume.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent

# --- is the data mount there? ------------------------------------------------
$mounted = docker exec a2o-oracle sh -c "test -d /opt/oracle/a2o-data && echo yes || echo no" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "a2o-oracle is not running. Start the lab first: scripts\lab-up.ps1"
    exit 1
}
if ($mounted.Trim() -ne "yes") {
    Write-Host "  /opt/oracle/a2o-data is not mounted - recreating the oracle container ..."
    Push-Location $pocRoot
    try {
        docker compose up -d --wait oracle
        if ($LASTEXITCODE -ne 0) { throw "docker compose up -d oracle failed" }
    } finally { Pop-Location }
}

# --- apply the DDL -----------------------------------------------------------
# As SYSDBA against the CDB root, exactly as oracle-init runs it: the file's
# first statement is ALTER SESSION SET CONTAINER, and CREATE DIRECTORY needs the
# privilege anyway.
$ddl = Join-Path $pocRoot "oracle-init\03_staging.sql"
if (-not (Test-Path $ddl)) { throw "missing $ddl" }

$sql = "WHENEVER SQLERROR EXIT SQL.SQLCODE" + "`n" + (Get-Content $ddl -Raw)
$out = $sql | docker exec -i a2o-oracle sqlplus -s "sys/PocSysPwd1@//localhost:1521/FREE" as sysdba
if ($LASTEXITCODE -ne 0) {
    Write-Host $out
    Write-Error "staging DDL failed (sqlplus exit $LASTEXITCODE)"
    exit 1
}

# --- prove the database can actually read the extract ------------------------
# The DDL succeeding says nothing about whether the file is readable: an external
# table is only checked when it is queried. Fail here, with a usable message,
# rather than four steps into a load.
$probe = @"
SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT COUNT(*) FROM pocapp.ext_vehicle WHERE ROWNUM <= 1;
EXIT;
"@
$probeOut = $probe | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
if ($LASTEXITCODE -ne 0) {
    Write-Host $probeOut
    Write-Error "the staging tables exist but Oracle cannot read data\vehicles.csv as an external table. Has an extract been run?"
    exit 1
}

Write-Host "  staging layer ready (stg_*, ext_* and directory A2O_DATA)."
exit 0
