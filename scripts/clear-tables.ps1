# Clears the migrated target tables before a (re)load - DELETE in child-first
# order so FK constraints stay enabled (Oracle raises ORA-02266 on TRUNCATE of a
# parent referenced by an enabled FK, even with empty children).
# Lookup/seed tables (CODE_LOOKUP, VEHICLE_TYPE, VEHICLE_TYPE_MAP) are never cleared.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$sql = @"
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
DELETE FROM pocapp.traffic_fine_offence;
DELETE FROM pocapp.traffic_fine_payment;
DELETE FROM pocapp.traffic_fine;
DELETE FROM pocapp.vehicle_plate;
DELETE FROM pocapp.migration_reject;
DELETE FROM pocapp.vehicle;
COMMIT;
EXIT;
"@

$out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
if ($LASTEXITCODE -ne 0) {
    Write-Host $out
    Write-Error "clear-tables failed (sqlplus exit $LASTEXITCODE)"
    exit 1
}
Write-Host "  target tables cleared."
exit 0
