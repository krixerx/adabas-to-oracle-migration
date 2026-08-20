# Clears the migrated target tables before a (re)load.
#
# The statements themselves live in hop\sql\00_clear_targets.sql, because both
# migration workflows run the same file as their first action - a workflow
# started from the Hop GUI has no wrapper script to do it for them. Keeping the
# delete order in one place means adding a target table is one edit, not three.
#
# Lookup/seed tables (CODE_LOOKUP, VEHICLE_TYPE, VEHICLE_TYPE_MAP,
# POWERTRAIN_TYPE, VIN_POWERTRAIN_RULE) are reference data and are never cleared.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent

$sqlFile = Join-Path $pocRoot "hop\sql\00_clear_targets.sql"
if (-not (Test-Path $sqlFile)) { throw "missing $sqlFile" }

# The shared file carries no EXIT - Hop sends it over JDBC, where EXIT is not a
# statement. sqlplus needs one, and needs to be told to fail rather than carry on.
$sql = "WHENEVER SQLERROR EXIT SQL.SQLCODE`nSET FEEDBACK OFF`n" +
       (Get-Content $sqlFile -Raw) + "`nEXIT;"

$out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
if ($LASTEXITCODE -ne 0) {
    Write-Host $out
    Write-Error "clear-tables failed (sqlplus exit $LASTEXITCODE)"
    exit 1
}
Write-Host "  target tables cleared."
exit 0
