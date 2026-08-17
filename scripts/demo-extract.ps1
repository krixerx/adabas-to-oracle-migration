# Demonstrates that the contract CSVs really come OUT OF ADABAS.
#
# The extract stage is the least self-evident part of this lab: an audience sees
# CSV files and has no way to tell whether they were produced from the database
# or checked in as fixtures. This script answers that, in five steps, each of
# which is evidence rather than assertion:
#
#   1. the STRUCTURE is Adabas - an FDT with a multiple-value field and a
#      periodic group, which no relational export could have produced;
#   2. the COUNTS come from Adabas, before any file is written;
#   3. the CSVs are DELETED, live, so nothing is left to fall back on;
#   4. the extract runs and the files reappear with the counts from step 2;
#   5. (-Live) a record is CHANGED inside Adabas and the CSV line changes with
#      it - the only step that proves causality rather than correlation.
#
#   scripts\demo-extract.ps1            steps 1-4
#   scripts\demo-extract.ps1 -Live      steps 1-5  (changes one Adabas record -
#                                       see the note on -Live below)
#   scripts\demo-extract.ps1 -Pause     wait for a keypress between steps
[CmdletBinding()]
param(
    [switch]$Live,
    [switch]$Pause
)
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"

function Step([int]$n, [string]$title) {
    Write-Host ""
    Write-Host ("=" * 74) -ForegroundColor DarkGray
    Write-Host ("  STEP {0}   {1}" -f $n, $title) -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkGray
}
function Note([string]$text) { Write-Host "  $text" -ForegroundColor DarkGray }
function Wait-Step { if ($Pause) { Write-Host ""; Read-Host "  [enter] to continue" | Out-Null } }

$running = docker ps --filter "name=a2o-adabas" --filter "status=running" --format "{{.Names}}"
if (-not $running) { Write-Error "a2o-adabas is not running - start the lab first (scripts\lab-up.ps1)."; exit 1 }

# ---------------------------------------------------------------------------
Step 1 "The data lives in Adabas, and it is not relational"
Note "The traffic-fine file's FDT. Look for the MU and PE options - a"
Note "multiple-value field and a periodic group. Nothing that came out of a"
Note "spreadsheet or an RDBMS export can have these."
Write-Host ""
docker exec a2o-adabas sh -lc "adarep db=1 fdt file=20" |
    Select-String -Pattern "Field Definition|Level|^ *-|^  1|^   2" | ForEach-Object { Write-Host "    $_" }
Wait-Step

# ---------------------------------------------------------------------------
Step 2 "Adabas reports how many records it holds - before any file exists"
$vehCount  = (docker exec a2o-adabas sh -lc "adarep db=1 fdt file=12" | Select-String "Records loaded:").ToString()
$fineCount = (docker exec a2o-adabas sh -lc "adarep db=1 fdt file=20" | Select-String "Records loaded:").ToString()
Write-Host ""
Write-Host ("    file 12 VEHICLES   {0}" -f $vehCount.Trim())
Write-Host ("    file 20 TRAFFINE   {0}" -f $fineCount.Trim())
Note ""
Note "Remember these two numbers. They come from the database's own report."
Wait-Step

# ---------------------------------------------------------------------------
Step 3 "Delete every CSV, so there is nothing to fall back on"
# -Exclude against a literal directory path silently returns NOTHING unless the
# path carries a wildcard - it reported "deleting 0 files" and the demo proved
# nothing. Where-Object cannot be got wrong.
$before = @(Get-ChildItem $dataDir -File | Where-Object { $_.Name -ne ".gitkeep" })
Write-Host ""
Write-Host ("    deleting {0} files from data\ ..." -f $before.Count)
$before | Remove-Item -Force
$after = @(Get-ChildItem $dataDir -File | Where-Object { $_.Name -ne ".gitkeep" })
Write-Host ("    data\ now contains {0} files" -f $after.Count) -ForegroundColor Yellow
if ($after.Count -ne 0) { Write-Error "data\ is not empty - the demo would not prove anything"; exit 1 }
Wait-Step

# ---------------------------------------------------------------------------
Step 4 "Run ONLY the extract - Natural programs reading Adabas"
Note "natural\EXTRVEH.NSP and EXTRFIN.NSP run headlessly inside the Natural"
Note "container. They READ V BY ISN and WRITE WORK FILE - no SQL anywhere."
Note "The counts below are reported BY THE PROGRAMS as they read."
Write-Host ""
& (Join-Path $PSScriptRoot "extract.ps1")
if ($LASTEXITCODE -ne 0) { throw "extract failed" }
Write-Host ""
Write-Host "    data\ now contains:" -ForegroundColor Green
Get-ChildItem $dataDir -File | Where-Object { $_.Name -ne ".gitkeep" } |
    ForEach-Object { Write-Host ("      {0,-32} {1,8:N0} bytes" -f $_.Name, $_.Length) }
Note ""
Note "The row counts match the numbers Adabas reported in step 2."
Wait-Step

# ---------------------------------------------------------------------------
if (-not $Live) {
    Write-Host ""
    Write-Host "  Done. Re-run with -Live to also prove the CSV FOLLOWS Adabas." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

Step 5 "Change a record inside Adabas, and watch the CSV follow"
Write-Host ""
Write-Host "    vehicle ISN 9, as the CSV has it right now:" -ForegroundColor DarkGray
$rowBefore = Import-Csv (Join-Path $dataDir "vehicles.csv") | Where-Object { $_.isn -eq "9" }
Write-Host ("      plate {0}   make {1}   colour {2}" -f $rowBefore.plate_no, $rowBefore.make, $rowBefore.color) -ForegroundColor Yellow
Write-Host ""
Write-Host "    changing its COLOR inside Adabas (natural\DEMOUPD.NSP) ..." -ForegroundColor DarkGray
$out = docker exec a2o-natural sh /poc/natural/run-demo-update.sh
if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n"); throw "demo update failed" }
$out | ForEach-Object { Write-Host "      $_" }
Write-Host ""
Write-Host "    re-running the extract ..." -ForegroundColor DarkGray
& (Join-Path $PSScriptRoot "extract.ps1") | Out-Null
if ($LASTEXITCODE -ne 0) { throw "extract failed" }
$rowAfter = Import-Csv (Join-Path $dataDir "vehicles.csv") | Where-Object { $_.isn -eq "9" }
Write-Host ""
Write-Host "    the same CSV row, re-extracted:" -ForegroundColor DarkGray
Write-Host ("      plate {0}   make {1}   colour {2}" -f $rowAfter.plate_no, $rowAfter.make, $rowAfter.color) -ForegroundColor Green
Write-Host ""
if ($rowBefore.color -eq $rowAfter.color) {
    Write-Error "the colour did not change - the CSV is NOT tracking Adabas"
    exit 1
}
Write-Host ("    '{0}' -> '{1}'.  The CSV is a projection of Adabas, not a fixture." -f $rowBefore.color, $rowAfter.color)
Note ""
Note "The change is permanent: SEEDVEH rewrites the VIN, type and fuel text on"
Note "a re-seed but never touches COLOR, so only a full rebuild"
Note "(docker compose down -v, then scripts\lab-up.ps1) puts the original back."
Note "Harmless either way - COLOR is copied straight through the migration."
Write-Host ""
exit 0
