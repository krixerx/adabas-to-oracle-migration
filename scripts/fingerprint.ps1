# A content fingerprint of the migrated tables.
#
#     scripts\fingerprint.ps1              ->  one line per table: rows and a hash
#
# Counts prove that the right NUMBER of rows arrived. They say nothing about
# whether the right VALUES did - a migration can produce 10,000,000 rows of
# nonsense and reconcile perfectly. This is what lets scripts\benchmark.ps1 make
# the stronger claim: that the row-by-row path and the staging path produce the
# SAME DATA, not merely the same totals.
#
# Two design points, both load-bearing:
#
#   - SURROGATE KEYS ARE EXCLUDED. vehicle_id and fine_id are IDENTITY values,
#     so they depend on insert order and the two techniques do not insert in the
#     same order. Hashing them would report a difference on every run and prove
#     nothing. Relationships are covered instead by hashing the PARENT'S
#     BUSINESS KEY through the join - which is the property that actually
#     matters: this plate belongs to the car with that VIN.
#
#   - SUM of hashes, not a hash of the concatenation, because SUM does not care
#     what order the rows come back in. Two techniques may well return rows in
#     different physical order and still be identical as sets.
#
# NULL is folded to a marker string rather than left as NULL: without that,
# 'a value went missing' and 'a value changed' would hash the same way.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# The leading blank line is not decoration: PowerShell writes a UTF-8 BOM into
# the pipe and sqlplus reports it as SP2-0734 on whatever the first line is.
$sql = @"

SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 200
WHENEVER SQLERROR EXIT SQL.SQLCODE

SELECT 'VEHICLE              ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         v.source_isn || '|' || v.vin || '|' || NVL(v.owner_national_id,'~') || '|' ||
         NVL(v.make,'~') || '|' || NVL(v.model,'~') || '|' || NVL(v.color,'~') || '|' ||
         NVL(TO_CHAR(v.year_built),'~') || '|' || NVL(v.source_vehicle_type,'~') || '|' ||
         NVL(v.vehicle_type_code,'~') || '|' || NVL(v.source_fuel_desc,'~') || '|' ||
         NVL(v.powertrain_code,'~') || '|' || NVL(v.powertrain_source,'~')))),'0')
  FROM pocapp.vehicle v;

SELECT 'VEHICLE_PLATE        ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         v.vin || '|' || p.plate_seq || '|' || NVL(p.plate_no,'~') || '|' ||
         p.source_isn || '|' || NVL(TO_CHAR(p.expiry_date,'YYYYMMDD'),'~')))),'0')
  FROM pocapp.vehicle_plate p JOIN pocapp.vehicle v ON v.vehicle_id = p.vehicle_id;

SELECT 'TRAFFIC_FINE         ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         f.source_isn || '|' || f.fine_no || '|' || NVL(v.vin,'~') || '|' ||
         NVL(f.plate_no,'~') || '|' || NVL(TO_CHAR(f.offence_date,'YYYYMMDD'),'~') || '|' ||
         NVL(f.location,'~') || '|' || NVL(TO_CHAR(f.amount),'~') || '|' ||
         NVL(f.status_code,'~') || '|' || NVL(f.status,'~') || '|' ||
         NVL(f.offender_national_id,'~')))),'0')
  FROM pocapp.traffic_fine f LEFT JOIN pocapp.vehicle v ON v.vehicle_id = f.vehicle_id;

SELECT 'TRAFFIC_FINE_OFFENCE ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         f.source_isn || '|' || o.seq_no || '|' || o.offence_code || '|' ||
         NVL(o.offence_desc,'~')))),'0')
  FROM pocapp.traffic_fine_offence o JOIN pocapp.traffic_fine f ON f.fine_id = o.fine_id;

SELECT 'TRAFFIC_FINE_PAYMENT ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         f.source_isn || '|' || p.seq_no || '|' ||
         NVL(TO_CHAR(p.paid_date,'YYYYMMDD'),'~') || '|' ||
         NVL(TO_CHAR(p.paid_amount),'~') || '|' || NVL(p.method_code,'~') || '|' ||
         NVL(p.method,'~')))),'0')
  FROM pocapp.traffic_fine_payment p JOIN pocapp.traffic_fine f ON f.fine_id = p.fine_id;

SELECT 'MIGRATION_REJECT     ' || COUNT(*) || ' ' || NVL(TO_CHAR(SUM(ORA_HASH(
         r.source_file || '|' || r.source_isn || '|' || r.reason || '|' ||
         NVL(r.detail,'~')))),'0')
  FROM pocapp.migration_reject r;

EXIT;
"@

$out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
if ($LASTEXITCODE -ne 0) {
    Write-Host $out
    Write-Error "fingerprint failed (sqlplus exit $LASTEXITCODE)"
    exit 1
}
$out | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
exit 0
