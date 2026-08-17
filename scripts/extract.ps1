# Extract stage - primary path (PROVEN 2026-08-05): Natural extract programs run
# headlessly inside the Natural CE container via natural/run-extract.sh:
#   - installs /poc/natural sources into FUSER library EXTRACT (ftouch)
#   - re-catalogs the hand-authored VEHICLES and TRAFFINE DDMs (READ+CATALOG on
#     the stack; CE has no batch mode and no SYSDDM - see README.md "Spike findings")
#   - runs EXTRVEH + EXTRFIN in one stacked session (udb=1, madio=0, unique etid)
#   - programs write the contract CSVs to /poc/data + counts_veh/fin.txt
# This script then merges the reported counts into data/manifest.json.
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }

# stale spike/simulation leftovers must not survive into a real-extract run
Remove-Item (Join-Path $dataDir "spike_*") -ErrorAction SilentlyContinue

Write-Host "  running Natural extract (EXTRVEH + EXTRFIN) in a2o-natural ..."
$out = docker exec a2o-natural sh /poc/natural/run-extract.sh
if ($LASTEXITCODE -ne 0) {
    Write-Host ($out -join "`n")
    Write-Error "Natural extract failed - see output above."
    exit 1
}
$out | ForEach-Object { Write-Host "    $_" }

# merge "<file>:<count>" lines from both counts files into manifest.json
$counts = [ordered]@{}
foreach ($cf in @("counts_veh.txt", "counts_fin.txt")) {
    $p = Join-Path $dataDir $cf
    if (-not (Test-Path $p)) { Write-Error "extract did not produce $cf"; exit 1 }
    foreach ($line in Get-Content $p) {
        if ($line -match '^\s*([^:]+):(\d+)\s*$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
}
if ($counts.Count -ne 4) { Write-Error "expected 4 count lines, got $($counts.Count)"; exit 1 }

# The VIN and VEH-TYPE fields do not exist in the untouched CE demo file; they are
# put there by scripts\seed-source.ps1. Without them the vehicle mappings would
# fail deep inside Hop with an Oracle NOT NULL violation, so say it here instead.
$vehCsv = Join-Path $dataDir "vehicles.csv"
$firstVeh = @(Import-Csv $vehCsv | Select-Object -First 1)
if ($firstVeh.Count -eq 0 -or -not $firstVeh[0].PSObject.Properties.Name.Contains("vin") -or
    [string]::IsNullOrWhiteSpace($firstVeh[0].vin)) {
    Write-Error "vehicles.csv carries no VIN - the Adabas source has not been prepared. Run: scripts\seed-source.ps1"
    exit 1
}
if ($counts["traffic_fines.csv"] -eq 0) {
    Write-Error "Adabas file 20 holds no traffic fines - run: scripts\seed-source.ps1"
    exit 1
}

$manifest = [ordered]@{
    extracted_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    source       = "Natural CE extract programs EXTRVEH+EXTRFIN (REAL Adabas CE data, DBID 1 files 12/20)"
    files        = $counts
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dataDir "manifest.json"), ($manifest | ConvertTo-Json), $utf8)
Write-Host "  manifest.json written (source: REAL Adabas via Natural extract)."
exit 0
