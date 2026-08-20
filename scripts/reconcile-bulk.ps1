# The reconciliation referee, for a bulk run.
#
#     scripts\reconcile-bulk.ps1        ->  "VERIFIED: 11/11"
#
# Same eleven checks as scripts\reconcile.ps1 and the same verdict line. The only
# difference is where the EXPECTED numbers come from.
#
# reconcile.ps1 derives them by re-reading the CSVs and applying the grouping
# rule itself - a genuinely independent second opinion, and the right design at
# lab scale. It cannot be used here: Import-Csv on eleven million rows would take
# longer than the migration and would need more memory than the database.
#
# So at scale the expectation comes from the generator, which counted what it
# wrote as it wrote it (data\bulk-expectations.json). That is exact rather than
# derived, and it is weaker in one specific way worth being honest about: it
# checks that the migration produced what the DATA implies, not that two
# independent implementations of the rule agree. The independence check still
# happens - at lab scale, every time migrate.cmd runs.
#
# The other half of the proof is in scripts\benchmark.ps1, which requires the
# row-by-row path and the staging path to produce IDENTICAL tables. Two
# techniques agreeing on eleven million rows is a stronger statement than either
# one matching a count.
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"

$expPath = Join-Path $dataDir "bulk-expectations.json"
if (-not (Test-Path $expPath)) {
    Write-Error "No data\bulk-expectations.json - run scripts\make-bulk-data.ps1 first."
    exit 1
}
$exp = Get-Content $expPath -Raw | ConvertFrom-Json

# bulk-expectations.json outlives the data it describes: a later scripts\extract.ps1
# replaces data\*.csv with the real Adabas extract and leaves this file sitting
# there. Comparing a real migration against a generator's numbers would fail for
# the wrong reason - or, worse, coincidentally pass. The manifest is the tie
# breaker, because both are written by whoever produced the files last.
$manifestPath = Join-Path $dataDir "manifest.json"
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.generated_by -ne "make-bulk-data.ps1") {
        Write-Error "data\ holds a real extract, not generated data, but bulk-expectations.json is still here. Use scripts\reconcile.ps1 for a real extract, or re-run scripts\make-bulk-data.ps1."
        exit 1
    }
    if ([int]$manifest.files."vehicles.csv" -ne [int]$exp.source_vehicle_rows) {
        Write-Error "data\vehicles.csv holds $($manifest.files.'vehicles.csv') rows but bulk-expectations.json expects $($exp.source_vehicle_rows) - the two are from different runs."
        exit 1
    }
}

function Get-OracleScalar([string]$select) {
    $sql = "SET HEADING OFF`nSET FEEDBACK OFF`nSET PAGESIZE 0`n$select`nEXIT;"
    $out = $sql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
    if ($LASTEXITCODE -ne 0) { throw "sqlplus failed for [$select] : $out" }
    $line = ($out | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
    if ($null -eq $line) { throw "could not parse a number from [$select]: $out" }
    return [long]$line
}

Write-Host ""
Write-Host "RECONCILIATION (bulk)"
Write-Host "--------------------------------------------------------------"
$total = 0; $ok = 0; $failures = @()

function Assert-Count([string]$label, [long]$expected, [long]$actual, [string]$note) {
    $script:total++
    if ($actual -eq $expected) {
        $script:ok++
        Write-Host ("  {0,-24} expected {1,12:N0}  actual {2,12:N0}  OK    {3}" -f $label, $expected, $actual, $note)
    } else {
        $script:failures += "$label : expected $expected, got $actual"
        Write-Host ("  {0,-24} expected {1,12:N0}  actual {2,12:N0}  MISMATCH {3}" -f $label, $expected, $actual, $note)
    }
}

$vehicle   = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle;"
$plate     = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle_plate;"
$mapped    = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE vehicle_type_code <> 'UN';"
$classed   = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_code IS NOT NULL;"
$byVin     = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_source LIKE 'VIN_RULE%';"
$conflicts = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.vehicle WHERE powertrain_source = 'VIN_RULE_CONFLICT';"
$fine      = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.traffic_fine;"
$offence   = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.traffic_fine_offence;"
$payment   = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.traffic_fine_payment;"
$resolved  = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.traffic_fine WHERE vehicle_id IS NOT NULL;"
$rejects   = Get-OracleScalar "SELECT COUNT(*) FROM pocapp.migration_reject;"

Assert-Count "VEHICLE"              $exp.VEHICLE              $vehicle  ("(from {0:N0} source rows)" -f $exp.source_vehicle_rows)
Assert-Count "VEHICLE_PLATE"        $exp.VEHICLE_PLATE        $plate    ""
# Nothing may disappear between the file and the target.
Assert-Count "plates in = out"      $exp.source_vehicle_rows  ($plate + $exp.plate_rejects) "(loaded + rejected)"
Assert-Count "VEHICLE type mapped"  $exp.vehicle_type_mapped  $mapped   ("({0:N0} unmapped -> UN)" -f ($exp.VEHICLE - $exp.vehicle_type_mapped))
Assert-Count "powertrain classified" $exp.VEHICLE             $classed  ""
Assert-Count "powertrain from VIN"  $exp.powertrain_vin_rule  $byVin    ("({0:N0} of them contradict the fuel text)" -f $conflicts)
Assert-Count "TRAFFIC_FINE"         $exp.TRAFFIC_FINE         $fine     ""
Assert-Count "TRAFFIC_FINE_OFFENCE" $exp.TRAFFIC_FINE_OFFENCE $offence  ""
Assert-Count "TRAFFIC_FINE_PAYMENT" $exp.TRAFFIC_FINE_PAYMENT $payment  ""
Assert-Count "FINE has a vehicle"   $exp.fines_resolved       $resolved ("({0:N0} unmatched plates)" -f $exp.fine_rejects)
Assert-Count "MIGRATION_REJECT"     $exp.MIGRATION_REJECT     $rejects  ("({0:N0} extra plates + {1:N0} unmatched fines)" -f $exp.plate_rejects, $exp.fine_rejects)

# The conflict count is reported rather than asserted: it is a property of the
# generated fuel/VIN combinations, and it is here so a change in the derivation
# shows up as a number moving instead of as nothing at all.
Write-Host ("  {0,-24} {1,12:N0} conflicts, {2:N0} decided by fuel text" -f "powertrain detail", $conflicts, ($exp.powertrain_fuel_desc))

Write-Host "--------------------------------------------------------------"
if ($failures.Count -eq 0) {
    Write-Host "VERIFIED: $ok/$total"
    exit 0
} else {
    Write-Host "FAILED: $ok/$total verified"
    $failures | ForEach-Object { Write-Host "  ! $_" }
    exit 1
}
