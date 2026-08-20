# Writes contract CSVs at any scale, so the two migration techniques can be
# compared on a volume that means something.
#
#     scripts\make-bulk-data.ps1                       # 10,000,000 vehicles + 2,000,000 fines
#     scripts\make-bulk-data.ps1 -Vehicles 1000000 -Fines 200000
#
# WHAT THIS IS NOT: an extract. It does not touch Adabas, and it says nothing
# about how fast a real extract runs - that is a mainframe question and it is
# measured separately, if at all. What it produces is the SAME FILE CONTRACT the
# Natural extract produces (FLAT_FILE_CONTRACT.md), with more rows in it, so
# everything downstream of the contract can be measured honestly.
#
# ⚠️ It OVERWRITES data\*.csv. Run scripts\extract.ps1 to put the real Adabas
# extract back.
#
# The generated data is deliberately not random. Every shape the migration has
# to handle appears at a known frequency:
#   - a vehicle registered again under a suffixed VIN (2 or 3 plates), and every
#     500th vehicle with a FOURTH plate, which the target model cannot hold;
#   - a legacy vehicle type absent from VEHICLE_TYPE_MAP (every 10th);
#   - all four powertrain paths - decided by the VIN, decided by the free-text
#     fuel field, the two CONTRADICTING each other, and undecidable;
#   - fines on a base plate, on a second plate (same car, different plate), on a
#     plate this migration rejected (the cascade), and on a plate that never
#     existed.
#
# Because the pattern is deterministic, the generator can COUNT what it writes
# and hand the expected results to the verifier, which is the only way to check
# a run of this size: Import-Csv on eleven million rows is not a thing you do.
[CmdletBinding()]
param(
    [int]$Vehicles = 10000000,
    [int]$Fines    = 2000000
)
$ErrorActionPreference = "Stop"

$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }

# BOM-less UTF-8: the contract says so, and Hop's CSV reader takes the BOM as
# part of the first column name if one is there.
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-Writer([string]$name) {
    # A 4 MB buffer and no AutoFlush: at ten million rows the difference between
    # this and a plain Out-File is minutes, not milliseconds.
    $fs = New-Object System.IO.FileStream((Join-Path $dataDir $name),
              [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4194304)
    $sw = New-Object System.IO.StreamWriter($fs, $utf8, 4194304)
    $sw.AutoFlush = $false
    # LF, not CRLF. The real extract writes these files from inside a Linux
    # container, and Oracle's external-table reader terminates records on a bare
    # linefeed and leaves the carriage return attached to the LAST field. That does not fail loudly - it
    # fails on the SUBSET of rows where the last field is already at its declared
    # width (a plate_expiry of '20200101' becomes 9 characters), so a CRLF file
    # loads most of its rows and rejects a scattering of them. Cost an hour once.
    $sw.NewLine = "`n"
    return $sw
}

# Two things are deliberately NOT factored out below: zero-padding is written
# inline as .ToString("D8") rather than as a helper, and the row is assembled
# with [string]::Concat rather than with "$a,$b". Both are measured, not
# stylistic - a PowerShell function call costs more than the work it wraps at
# twenty million iterations, and the -f operator goes through String.Format.

# ---------------------------------------------------------------------------
# Reference data. These must agree with oracle-init\02_lookups.sql:
#   - $mappedTypes are the codes VEHICLE_TYPE_MAP knows; 'X-OLD' is deliberately
#     not one of them, so the unmapped -> 'UN' path is exercised;
#   - the VIN prefixes are built to match (or miss) VIN_POWERTRAIN_RULE.
# ---------------------------------------------------------------------------
$mappedTypes = @('SEDAN','ESTATE','HATCH','COUPE','PICKUP','VAN-C','LORRY','MBIKE','MINIBUS')
$unmappedType = 'X-OLD'

# Fuel free text, and what the migration should make of each spelling. Kept side
# by side so the expectation cannot drift away from the data.
$fuels = @(
    @{ text = 'PETROL';         pt = 'PETROL' },
    @{ text = 'petrol';         pt = 'PETROL' },
    @{ text = 'BENZIN';         pt = 'PETROL' },
    @{ text = 'ELEC.';          pt = 'EV'     },
    @{ text = 'PLUG-IN HYBRID'; pt = 'PHEV'   },
    @{ text = 'HEV SELF CHG';   pt = 'HEV'    },
    @{ text = 'N/A';            pt = $null    },
    @{ text = '';               pt = $null    }
)

# VIN rules, as seeded. Ford carries the engine code at position 5, BMW at
# position 8 - two manufacturers, two positions, which is exactly why decoding a
# VIN is a lookup and not an algorithm.
$fordEngines = @( @{c='E'; pt='EV'}, @{c='P'; pt='PHEV'}, @{c='H'; pt='HEV'}, @{c='G'; pt='PETROL'} )
$bmwEngines  = @( @{c='I'; pt='EV'}, @{c='X'; pt='PHEV'}, @{c='A'; pt='HEV'}, @{c='B'; pt='PETROL'} )

$makes  = @('FORD','BMW','RENAULT','TOYOTA','VOLVO')
$models = @('FOCUS','X3','CLIO','COROLLA','V60')
$colors = @('WHITE','BLACK','SILVER','ROUGE','BLUE')

# Every VIN below is exactly 17 characters before any legacy suffix. That is not
# decoration: the whole de-duplication rule is "base VIN = first 17 characters",
# and a short VIN would silently group unrelated vehicles together.
function Get-VinBase([int]$i, [int]$makeIx, [string]$engine) {
    $seq = $i.ToString("D8")
    switch ($makeIx) {
        0 { return "FOR1$engine" + "Z" + $seq + "ZZZ" }   # FOR_E____________  position 5
        1 { return "BMW1234$engine" + $seq + "Z" }        # BMW____X_________  position 8
        2 { return "RENZZ1" + $seq + "ZZZ" }
        3 { return "TOYZZ1" + $seq + "ZZZ" }
        default { return "VOLZZ1" + $seq + "ZZZ" }
    }
}

Write-Host ""
Write-Host "Generating contract CSVs: $('{0:N0}' -f $Vehicles) vehicles, $('{0:N0}' -f $Fines) fines ..." -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# vehicles.csv - one row per PLATE, which is the whole point of the file.
# ---------------------------------------------------------------------------
$exp = [ordered]@{}
$vehRows = 0; $plates = 0; $plateRejects = 0; $mapped = 0
$ptVinRule = 0; $ptConflict = 0; $ptFuel = 0; $ptUnknown = 0

$w = New-Writer "vehicles.csv"
$w.WriteLine("isn,plate_no,personnel_id,make,model,color,year_built,vin,veh_type,fuel_desc,plate_expiry")

$isn = 0
for ($i = 1; $i -le $Vehicles; $i++) {

    # How many EXTRA registrations this vehicle picked up over its life. Every
    # 500th gets a fourth plate, which the target model cannot hold.
    $extra = 0
    if     ($i % 500 -eq 0) { $extra = 3 }
    elseif ($i % 50  -eq 0) { $extra = 2 }
    elseif ($i % 10  -eq 0) { $extra = 1 }

    $makeIx = $i % 5
    $engine = ''
    $rulePt = $null
    if ($makeIx -eq 0) { $e = $fordEngines[$i % 4]; $engine = $e.c; $rulePt = $e.pt }
    if ($makeIx -eq 1) { $e = $bmwEngines[$i % 4];  $engine = $e.c; $rulePt = $e.pt }

    $vinBase = Get-VinBase $i $makeIx $engine
    $fuel     = $fuels[$i % 8]
    $fuelText = $fuel.text
    $type     = if ($i % 10 -eq 0) { $unmappedType } else { $mappedTypes[$i % 9] }
    $owner    = (50000000 + ($i % 900000)).ToString("D8")
    $pad      = $i.ToString("D8")
    # make, model, colour and year never vary within one vehicle - render once.
    $tail     = [string]::Concat($makes[$makeIx], ",", $models[$makeIx], ",",
                                 $colors[$i % 5], ",", (1980 + ($i % 45)).ToString())

    # --- what the migration should decide about this vehicle ---------------
    if ($type -ne $unmappedType) { $mapped++ }
    if ($null -ne $rulePt) {
        if ($null -ne $fuel.pt -and $fuel.pt -ne $rulePt) { $ptConflict++ } else { $ptVinRule++ }
    }
    elseif ($null -ne $fuel.pt) { $ptFuel++ }
    else { $ptUnknown++ }

    # --- the rows themselves -----------------------------------------------
    # Row 0 is the vehicle: un-suffixed VIN, so it sorts first and becomes
    # plate_seq 1. Each extra row carries the SAME VIN plus one character and a
    # genuinely different plate - that is the legacy workaround being reproduced.
    for ($p = 0; $p -le $extra; $p++) {
        $isn++
        $vehRows++
        $vin   = if ($p -eq 0) { $vinBase } else { [string]::Concat($vinBase, $p) }
        $plate = if ($p -eq 0) { [string]::Concat("P", $pad) } else { [string]::Concat("X", $pad, $p) }
        # A registration is never deleted, it expires. Empty = still current.
        # Composed from parts rather than by adding a number to 20200101, which
        # cheerfully produces 20200145. Dirty dates are a real migration problem
        # and they belong in a dirty-data experiment, not smuggled in by the
        # generator - here they would just make the load fail with ORA-01847.
        $expiry = if ($p -gt 0 -and ($i % 3) -eq 0) {
                      ((2020 + ($i % 5)) * 10000 + (1 + ($i % 12)) * 100 + (1 + ($i % 28))).ToString()
                  } else { "" }

        $w.WriteLine([string]::Concat($isn.ToString(), ",", $plate, ",", $owner, ",",
                                      $tail, ",", $vin, ",", $type, ",", $fuelText, ",", $expiry))

        if ($p -lt 3) { $plates++ } else { $plateRejects++ }
    }
}
$w.Flush(); $w.Close()
Write-Host ("  vehicles.csv        {0,12:N0} rows   {1,6:N1}s" -f $vehRows, $sw.Elapsed.TotalSeconds)

# ---------------------------------------------------------------------------
# traffic_fines.csv + the MU/PE children.
# ---------------------------------------------------------------------------
$swf = [Diagnostics.Stopwatch]::StartNew()
$statuses = @('I','P','C','A')
$offCodes = @('SPD1','SPD2','RLGT','SBLT','MOBP','PARK')
$methods  = @('CA','CC','BT')
$places   = @('SULTAN QABOOS ST','AL KHUWAIR','RUWI HIGH ST','SEEB ROAD','MUTRAH CORNICHE')

$fineRows = 0; $finesResolved = 0; $offRows = 0; $payRows = 0

$wf = New-Writer "traffic_fines.csv"
$wo = New-Writer "traffic_fine_offences.csv"
$wp = New-Writer "traffic_fine_payments.csv"
$wf.WriteLine("isn,fine_no,plate_no,offence_yyyymmdd,location,amount,status,offender_national_id")
$wo.WriteLine("parent_key,occurrence_index,offence_code")
$wp.WriteLine("parent_key,occurrence_index,paid_yyyymmdd,paid_amount,payment_method")

for ($j = 1; $j -le $Fines; $j++) {
    $vi = (($j - 1) % $Vehicles) + 1

    # Does that vehicle have extra plates? Same rule as above - the generator
    # must not guess, or the expectation would be a second implementation.
    $extra = 0
    if     ($vi % 500 -eq 0) { $extra = 3 }
    elseif ($vi % 50  -eq 0) { $extra = 2 }
    elseif ($vi % 10  -eq 0) { $extra = 1 }

    $resolved = $true
    $vipad = $vi.ToString("D8")
    if ($j % 97 -eq 0) {
        # A plate that was never in the vehicle file: foreign, or deregistered
        # long before the migration. Normal, and not an error.
        $plate = [string]::Concat("F", $j.ToString("D8"))
        $resolved = $false
    }
    elseif ($extra -eq 3 -and $j % 89 -eq 0) {
        # THE CASCADE: a fine written against the fourth plate, which step 4
        # quarantined - so this fine cannot resolve either.
        $plate = [string]::Concat("X", $vipad, "3")
        $resolved = $false
    }
    elseif ($extra -ge 1 -and $j % 13 -eq 0) {
        # A different plate on the SAME car. This is the one that proves the
        # de-duplication paid off.
        $plate = [string]::Concat("X", $vipad, "1")
    }
    else {
        $plate = [string]::Concat("P", $vipad)
    }
    if ($resolved) { $finesResolved++ }

    $js = $j.ToString()
    $wf.WriteLine([string]::Concat(
        $js, ",F", $j.ToString("D9"), ",", $plate, ",",
        ((2022 + ($j % 4)) * 10000 + (1 + ($j % 12)) * 100 + (1 + ($j % 28))).ToString(), ",", $places[$j % 5], ",",
        (25 + ($j % 176)).ToString(), ".00,", $statuses[$j % 4], ",",
        (50000000 + ($j % 900000)).ToString("D8")))
    $fineRows++

    # MU: 1 to 3 offences seen in one stop.
    $nOff = 1 + ($j % 3)
    for ($k = 1; $k -le $nOff; $k++) {
        $wo.WriteLine([string]::Concat($js, ",", $k.ToString(), ",", $offCodes[($j + $k) % 6]))
        $offRows++
    }

    # PE: 0 to 2 part payments. A fine with none is normal and must not break
    # anything - an empty child set is a fact, not a missing file.
    $nPay = $j % 3
    for ($k = 1; $k -le $nPay; $k++) {
        $wp.WriteLine([string]::Concat(
            $js, ",", $k.ToString(), ",", ((2022 + ($j % 4)) * 10000 + (1 + (($j + 1) % 12)) * 100 + (1 + (($j + $k) % 28))).ToString(), ",",
            (10 + ($k * 5)).ToString(), ".00,", $methods[($j + $k) % 3]))
        $payRows++
    }
}
$wf.Flush(); $wf.Close(); $wo.Flush(); $wo.Close(); $wp.Flush(); $wp.Close()
Write-Host ("  traffic_fines.csv   {0,12:N0} rows   {1,6:N1}s" -f $fineRows, $swf.Elapsed.TotalSeconds)
Write-Host ("  offences / payments {0,12:N0} / {1:N0} rows" -f $offRows, $payRows)

# ---------------------------------------------------------------------------
# manifest.json - the extract's own record of what it produced, per the
# contract. reconcile.ps1 cross-checks it against the files.
# ---------------------------------------------------------------------------
$manifest = [ordered]@{
    generated_by = "make-bulk-data.ps1"
    generated_at = (Get-Date).ToString("s")
    files = [ordered]@{
        "vehicles.csv"              = $vehRows
        "traffic_fines.csv"         = $fineRows
        "traffic_fine_offences.csv" = $offRows
        "traffic_fine_payments.csv" = $payRows
    }
}
[IO.File]::WriteAllText((Join-Path $dataDir "manifest.json"), ($manifest | ConvertTo-Json -Depth 4), $utf8)

# ---------------------------------------------------------------------------
# The expectations. This is what makes a run of this size checkable: the counts
# were accumulated WHILE writing, so they are what the file actually contains
# rather than a second opinion about it.
# ---------------------------------------------------------------------------
$exp = [ordered]@{
    vehicles_param        = $Vehicles
    fines_param           = $Fines
    source_vehicle_rows   = $vehRows
    VEHICLE               = $Vehicles
    VEHICLE_PLATE         = $plates
    plate_rejects         = $plateRejects
    vehicle_type_mapped   = $mapped
    powertrain_vin_rule   = $ptVinRule + $ptConflict   # VIN_RULE + VIN_RULE_CONFLICT
    powertrain_conflict   = $ptConflict
    powertrain_fuel_desc  = $ptFuel
    powertrain_unknown    = $ptUnknown
    TRAFFIC_FINE          = $fineRows
    TRAFFIC_FINE_OFFENCE  = $offRows
    TRAFFIC_FINE_PAYMENT  = $payRows
    fines_resolved        = $finesResolved
    fine_rejects          = $fineRows - $finesResolved
    MIGRATION_REJECT      = $plateRejects + ($fineRows - $finesResolved)
}
[IO.File]::WriteAllText((Join-Path $dataDir "bulk-expectations.json"), ($exp | ConvertTo-Json -Depth 4), $utf8)

$sw.Stop()
$totalRows = $vehRows + $fineRows + $offRows + $payRows
$mb = (Get-ChildItem $dataDir -Filter *.csv | Measure-Object -Property Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("  {0:N0} rows across 4 files, {1:N0} MB, in {2:N1}s" -f $totalRows, $mb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host  "  expectations written to data\bulk-expectations.json"
Write-Host  "  data\ no longer holds the real Adabas extract - scripts\extract.ps1 restores it." -ForegroundColor DarkYellow
exit 0
