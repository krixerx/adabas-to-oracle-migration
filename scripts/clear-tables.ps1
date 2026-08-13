# Clears the migrated target tables before a (re)load - DELETE in child-first
# order so FK constraints stay enabled (Oracle raises ORA-02266 on TRUNCATE of a
# parent referenced by an enabled FK, even with empty children).
# Lookup/seed tables (CODE_LOOKUP) are never cleared.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$sql = @"
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
DELETE FROM pocapp.employee_address_line;
DELETE FROM pocapp.employee_language;
DELETE FROM pocapp.employee_income;
DELETE FROM pocapp.vehicle;
DELETE FROM pocapp.employee;
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
