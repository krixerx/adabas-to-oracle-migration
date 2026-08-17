# Reconciliation referee - prints the "VERIFIED: n/n" report.
#
# Every migrated target table has an explicit expected-count rule. The MU/PE
# children are 1 CSV row -> 1 table row, so their rule is "= row count of <csv>";
# the manifest count (reported by the extract programs) is cross-checked against
# the actual CSV line count first.
#
# The vehicle side is NOT 1:1 - that is the whole point of it. The source holds
# one row per PLATE and the target one row per VEHICLE plus one per plate, so the
# expectations are DERIVED from the file by applying the same grouping rule the
# mappings apply (base VIN = first 17 characters).
#
# Three checks matter more than the counts themselves:
#   - plates loaded + rejected = rows in the file   (nothing vanished silently)
#   - fines resolved to a vehicle, measured against the plates actually in the
#     file rather than a number hard-coded here
#   - the vehicle-type replacement happened, measured against the mapping table
# Lookup/seed tables get separate seed-count checks.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"

# VIN length the mappings cut at. Changing it means changing the StringCut
# transform in pipelines 10 and 20 too.
$VIN_LEN = 17

# Plates the target model can hold. Changing it means changing the "at most 3
# plates" filter in pipeline 20 AND ck_vehicle_plate_seq in 01_schema.sql.
$MAX_PLATES = 3

# ---- 1:1 expected-count rules (update together with mappings + seeds) ----
$rules = [ordered]@{
    "TRAFFIC_FINE"          = "traffic_fines.csv"
    "TRAFFIC_FINE_OFFENCE"  = "traffic_fine_offences.csv"
    "TRAFFIC_FINE_PAYMENT"  = "traffic_fine_payments.csv"
}
$seedRules = [ordered]@{
    "CODE_LOOKUP"         = 13     # must match oracle-init/02_lookups.sql
    "VEHICLE_TYPE"        = 6
    "VEHICLE_TYPE_MAP"    = 9
    "POWERTRAIN_TYPE"     = 5
    "VIN_POWERTRAIN_RULE" = 8
}

$manifestPath = Join-Path $dataDir "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Error "No manifest.json in data\ - run an extract (or scripts\make-sample-data.ps1) first."
    exit 1
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

function Invoke-OracleQuery([string]$select) {
    $sql = "SET HEADING OFF`nSET FEEDBACK OFF`nSET PAGESIZE 0`n$select`nEXIT;"
    $out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
    if ($LASTEXITCODE -ne 0) { throw "sqlplus failed for [$select] : $out" }
    return @($out | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Get-OracleScalar([string]$select) {
    $rows = Invoke-OracleQuery $select
    $line = ($rows | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if ($null -eq $line) { throw "could not parse a number from [$select]: $rows" }
    return [int]$line
}

function Get-OracleCount([string]$table) { Get-OracleScalar "SELECT COUNT(*) FROM pocapp.$table;" }

Write-Host ""
Write-Host "RECONCILIATION"
Write-Host "--------------------------------------------------------------"
$total = 0; $ok = 0; $failures = @()

function Assert-Count([string]$label, [int]$expected, [int]$actual, [string]$note) {
    $script:total++
    if ($actual -eq $expected) {
        $script:ok++
        Write-Host ("  {0,-24} expected {1,6}  actual {2,6}  OK    {3}" -f $label, $expected, $actual, $note)
    } else {
        $script:failures += "$label : expected $expected, got $actual"
        Write-Host ("  {0,-24} expected {1,6}  actual {2,6}  MISMATCH {3}" -f $label, $expected, $actual, $note)
    }
}

# ---- vehicle side: expectations derived from the file --------------------
$vehCsvPath = Join-Path $dataDir "vehicles.csv"
if (-not (Test-Path $vehCsvPath)) { throw "source file vehicles.csv missing" }
$vehRows = @(Import-Csv $vehCsvPath)
$manifestVeh = $manifest.files."vehicles.csv"
if ($null -ne $manifestVeh -and [int]$manifestVeh -ne $vehRows.Count) {
    throw "manifest says $manifestVeh vehicle records but vehicles.csv has $($vehRows.Count) rows (extract inconsistent)"
}
# A VIN shorter than the cut length would make the grouping rule meaningless -
# and would silently group unrelated vehicles together. Fail loudly instead.
$short = @($vehRows | Where-Object { $_.vin.Length -lt $VIN_LEN })
if ($short.Count -gt 0) {
    throw "$($short.Count) vehicle rows have a VIN shorter than $VIN_LEN characters (first ISN $($short[0].isn)) - the base-VIN grouping rule does not hold"
}

$groups   = @($vehRows | Group-Object { $_.vin.Substring(0, $VIN_LEN) })
$expPlate = ($groups | ForEach-Object { [Math]::Min($_.Count, $MAX_PLATES) } | Measure-Object -Sum).Sum
$expPlateRej = ($groups | ForEach-Object { [Math]::Max($_.Count - $MAX_PLATES, 0) } | Measure-Object -Sum).Sum

# The plates that actually reach VEHICLE_PLATE - the same ranking the mapping
# applies: sort each VIN group on the full VIN, keep the first $MAX_PLATES.
# This is NOT the same as "every plate in the file", and the difference is a
# real cascade: a fine written against a plate that was rejected as surplus
# cannot resolve to a vehicle either.
$loadedPlates = [System.Collections.Generic.HashSet[string]]::new()
foreach ($g in $groups) {
    $kept = $g.Group | Sort-Object { $_.vin } | Select-Object -First $MAX_PLATES
    foreach ($r in $kept) { if ($r.plate_no) { [void]$loadedPlates.Add($r.plate_no) } }
}

$actVehicle = Get-OracleCount "VEHICLE"
$actPlate   = Get-OracleCount "VEHICLE_PLATE"

$dupRows = $vehRows.Count - $groups.Count
Assert-Count "VEHICLE"       $groups.Count $actVehicle ("(from {0} rows, {1} duplicates removed)" -f $vehRows.Count, $dupRows)
Assert-Count "VEHICLE_PLATE" $expPlate     $actPlate   ""
# Nothing may disappear between the file and the target.
Assert-Count "plates in = out" $vehRows.Count ($actPlate + $expPlateRej) "(loaded + rejected)"

# ---- the vehicle-type replacement actually happened ----------------------
# Expected mapped count is computed against the mapping table as it really is in
# Oracle, so this check does not repeat the seed data.
$mapCodes = @(Invoke-OracleQuery "SELECT source_type FROM pocapp.vehicle_type_map;")
$expMapped = 0
foreach ($g in $groups) {
    $baseRow = $g.Group | Sort-Object { $_.vin } | Select-Object -First 1
    if ($mapCodes -contains $baseRow.veh_type) { $expMapped++ }
}
$actMapped = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE vehicle_type_code <> 'UN';"
Assert-Count "VEHICLE type mapped" $expMapped $actMapped ("({0} unmapped -> UN)" -f ($groups.Count - $expMapped))

# ---- the powertrain derivation ------------------------------------------
# Two checks, and neither re-implements the JavaScript - a referee that repeats
# the mapping's logic only proves the logic agrees with itself.
#
# 1. Every vehicle ends up classified. 'UN' is a classification; NULL is a bug.
$actClassified = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_code IS NOT NULL;"
Assert-Count "powertrain classified" $groups.Count $actClassified ""

# 2. The VIN-derived rows, checked INDEPENDENTLY: read the patterns out of the
#    rule table and match them here with PowerShell's -like (converting SQL's
#    `_` wildcard to `?`). Different engine, different language, same rule - so
#    this genuinely tests the DBJoin rather than echoing it.
$patterns = @(Invoke-OracleQuery "SELECT vin_pattern FROM pocapp.vin_powertrain_rule ORDER BY rule_id;") |
    ForEach-Object { $_.Replace('_', '?') }
$expByVin = 0
foreach ($g in $groups) {
    $vinBase = $g.Name
    foreach ($p in $patterns) {
        if ($vinBase -like $p) { $expByVin++; break }
    }
}
$actByVin = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_source LIKE 'VIN_RULE%';"
$conflicts = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_source = 'VIN_RULE_CONFLICT';"
Assert-Count "powertrain from VIN" $expByVin $actByVin ("({0} of them contradict the fuel text)" -f $conflicts)

# ---- 1:1 tables (fines and their MU/PE children) ------------------------
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
    Assert-Count $table $csvCount (Get-OracleCount $table) ""
}

# ---- fines resolved to a vehicle ----------------------------------------
# A fine's plate must match a plate that exists in the vehicle file. Computing
# the expectation from the file (rather than from a constant) means this check
# still holds after the seeded data changes.
$fineCsvPath = Join-Path $dataDir "traffic_fines.csv"
if (Test-Path $fineCsvPath) {
    $fineRows    = @(Import-Csv $fineCsvPath)
    $expResolved = @($fineRows | Where-Object { $loadedPlates.Contains($_.plate_no) }).Count
    $expFineRej  = $fineRows.Count - $expResolved

    $actResolved = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.traffic_fine WHERE vehicle_id IS NOT NULL;"
    Assert-Count "FINE has a vehicle" $expResolved $actResolved ("({0} unmatched plates)" -f $expFineRej)

    # MIGRATION_REJECT collects both kinds: dropped surplus plates and the fines
    # whose plate matched nothing.
    $actRej = Get-OracleCount "MIGRATION_REJECT"
    Assert-Count "MIGRATION_REJECT" ($expPlateRej + $expFineRej) $actRej ("({0} extra plates + {1} unmatched fines)" -f $expPlateRej, $expFineRej)
}

# ---- seed-count checks (separate from VERIFIED n/n) ----------------------
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
