# Reconciliation referee - prints the "VERIFIED: n/n" report.
#
# Every migrated target table has an explicit expected-count rule (design doc:
# "Reconcile step implementation"). For this lab all loads are 1 CSV row -> 1 table
# row, so each rule is "= row count of <csv>"; the manifest count (reported by the
# extract programs) is cross-checked against the actual CSV line count first.
# Lookup/seed tables get a separate seed-count check.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"

# ---- expected-count rules (update together with mappings + seeds) ----
$rules = [ordered]@{
    "EMPLOYEE"              = "employees.csv"
    "EMPLOYEE_ADDRESS_LINE" = "employees_address_lines.csv"
    "EMPLOYEE_LANGUAGE"     = "employees_languages.csv"
    "EMPLOYEE_INCOME"       = "employees_income.csv"
    "VEHICLE"               = "vehicles.csv"
}
$seedRules = [ordered]@{
    "CODE_LOOKUP" = 6      # must match oracle-init/02_lookups.sql
}

$manifestPath = Join-Path $dataDir "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Error "No manifest.json in data\ - run an extract (or scripts\make-sample-data.ps1) first."
    exit 1
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

function Get-OracleCount([string]$table) {
    $sql = "SET HEADING OFF`nSET FEEDBACK OFF`nSET PAGESIZE 0`nSELECT COUNT(*) FROM pocapp.$table;`nEXIT;"
    $out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
    if ($LASTEXITCODE -ne 0) { throw "sqlplus failed for $table : $out" }
    $line = ($out | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    if ($null -eq $line) { throw "could not parse count for $table from: $out" }
    return [int]$line.Trim()
}

Write-Host ""
Write-Host "RECONCILIATION"
Write-Host "--------------------------------------------------------------"
$total = 0; $ok = 0; $failures = @()

foreach ($table in $rules.Keys) {
    $csv = $rules[$table]
    $csvPath = Join-Path $dataDir $csv
    if (-not (Test-Path $csvPath)) { $failures += "$table : source file $csv missing"; $total++; continue }
    $csvCount = (Get-Content $csvPath | Measure-Object -Line).Lines - 1   # minus header
    $manifestCount = $manifest.files.$csv
    if ($null -ne $manifestCount -and [int]$manifestCount -ne $csvCount) {
        $failures += "$table : manifest says $manifestCount records but $csv has $csvCount rows (extract inconsistent)"
        $total++; continue
    }
    $actual = Get-OracleCount $table
    $total++
    if ($actual -eq $csvCount) {
        $ok++
        Write-Host ("  {0,-24} expected {1,6}  actual {2,6}  OK" -f $table, $csvCount, $actual)
    } else {
        $failures += "$table : expected $csvCount, got $actual"
        Write-Host ("  {0,-24} expected {1,6}  actual {2,6}  MISMATCH" -f $table, $csvCount, $actual)
    }
}

# seed-count checks (separate from VERIFIED n/n)
foreach ($table in $seedRules.Keys) {
    $expected = $seedRules[$table]
    $actual = Get-OracleCount $table
    if ($actual -eq $expected) {
        Write-Host ("  {0,-24} seed     {1,6}  actual {2,6}  OK  (seed check)" -f $table, $expected, $actual)
    } else {
        $failures += "$table (seed) : expected $expected, got $actual"
        Write-Host ("  {0,-24} seed     {1,6}  actual {2,6}  MISMATCH (seed check)" -f $table, $expected, $actual)
    }
}

Write-Host "--------------------------------------------------------------"
if ($failures.Count -eq 0) {
    Write-Host "VERIFIED: $ok/$total"
    exit 0
} else {
    Write-Host "FAILED: $ok/$total verified"
    $failures | ForEach-Object { Write-Host "  ! $_" }
    exit 1
}
