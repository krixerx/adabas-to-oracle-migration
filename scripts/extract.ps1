# Extract stage - primary path (PROVEN 2026-08-05): Natural extract programs run
# headlessly inside the Natural CE container via natural/run-extract.sh:
#   - installs /poc/natural sources into FUSER library EXTRACT (ftouch)
#   - re-catalogs the hand-authored VEHICLES DDM (READ+CATALOG on the stack;
#     CE has no batch mode and no SYSDDM - see README.md "Spike findings")
#   - runs EXTREMP + EXTRVEH in one stacked session (udb=1, madio=0, unique etid)
#   - programs write the contract CSVs to /poc/data + counts_emp/veh.txt
# This script then merges the reported counts into data/manifest.json.
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }

# stale spike/simulation leftovers must not survive into a real-extract run
Remove-Item (Join-Path $dataDir "spike_*") -ErrorAction SilentlyContinue

Write-Host "  running Natural extract (EXTREMP + EXTRVEH) in a2o-natural ..."
$out = docker exec a2o-natural sh /poc/natural/run-extract.sh
if ($LASTEXITCODE -ne 0) {
    Write-Host ($out -join "`n")
    Write-Error "Natural extract failed - see output above."
    exit 1
}
$out | ForEach-Object { Write-Host "    $_" }

# merge "<file>:<count>" lines from both counts files into manifest.json
$counts = [ordered]@{}
foreach ($cf in @("counts_emp.txt", "counts_veh.txt")) {
    $p = Join-Path $dataDir $cf
    if (-not (Test-Path $p)) { Write-Error "extract did not produce $cf"; exit 1 }
    foreach ($line in Get-Content $p) {
        if ($line -match '^\s*([^:]+):(\d+)\s*$') { $counts[$Matches[1]] = [int]$Matches[2] }
    }
}
if ($counts.Count -ne 5) { Write-Error "expected 5 count lines, got $($counts.Count)"; exit 1 }

$manifest = [ordered]@{
    extracted_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    source       = "Natural CE extract programs EXTREMP+EXTRVEH (REAL Adabas CE data, DBID 1 files 11/12)"
    files        = $counts
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dataDir "manifest.json"), ($manifest | ConvertTo-Json), $utf8)
Write-Host "  manifest.json written (source: REAL Adabas via Natural extract)."
exit 0
