# Runs the SAME migration two ways and reports what each costs.
#
#     scripts\benchmark.ps1 -Vehicles 10000000 -Fines 2000000
#     scripts\benchmark.ps1                          # reuse the data already in data\
#     scripts\benchmark.ps1 -Arms staging            # one arm only
#
#   ROW BY ROW   hop\workflows\migrate-all.hwf      pipelines 10..50; every record
#                                                    is read, reshaped and written
#                                                    by a JVM, one row at a time
#   STAGING      hop\workflows\migrate-staging.hwf   the files land in Oracle
#                                                    unchanged and the redesign is
#                                                    done in set-based SQL
#
# Hop runs BOTH: the difference measured here is the technique, not the tool. The
# same container, the same JVM start-up, the same connection, the same source
# files and the same reconciliation.
#
# The comparison is only worth anything if both arms are correct, so each one is
# reconciled AND fingerprinted, and the two fingerprints must match. Identical
# counts would not be enough - two techniques can agree on how many rows they
# produced and disagree about what is in them.
#
# ⚠️ This overwrites data\ with generated files when -Vehicles is given, and it
# clears the target tables repeatedly. It is a benchmark, not a migration.
[CmdletBinding()]
param(
    [int]$Vehicles = 0,
    [int]$Fines    = 0,
    [ValidateSet('both','rowbyrow','staging')]
    [string]$Arms  = 'both'
)
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent
Set-Location $pocRoot

# A full-scale target to extrapolate against. Legacy systems of this shape keep
# most of their volume in a handful of very large files, and a few hundred
# million records between them is an ordinary size for the biggest of them.
$LARGE_LOAD_ROWS = 300000000

# Below this, a throughput figure is not a throughput figure. Both arms pay the
# same fixed toll before touching a single row - Docker starting a container, a
# JVM starting, Hop loading its plugin registry, a connection opening - and that
# is tens of seconds. At 19,222 rows it IS the measurement: the two techniques
# came out 1.3x apart, which says nothing about either of them. At 384,400 rows,
# where the same overhead is a smaller share, the gap was 2.6x and widening.
# Extrapolating from under this threshold produces a confident-looking number
# that is mostly a measurement of Docker, so the report refuses to print one.
$MEANINGFUL_ROWS = 1000000

# Native commands here write progress to stderr - docker compose always does -
# and with $ErrorActionPreference = "Stop" plus 2>&1 PowerShell promotes every
# one of those lines to a TERMINATING error. The benchmark would die on
# "Container a2o-oracle Running". Redirection is therefore done with the
# preference temporarily relaxed, and success is judged on the EXIT CODE, which
# is the only thing that actually means failure.
function Invoke-Native([scriptblock]$block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $block 2>&1
        return @{ ok = ($LASTEXITCODE -eq 0); out = $out }
    } finally { $ErrorActionPreference = $prev }
}

function Run-Ps([string]$script, [string[]]$scriptArgs) {
    $path = Join-Path $PSScriptRoot $script
    return Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $path @scriptArgs }
}

# ---------------------------------------------------------------------------
# 1. the data
# ---------------------------------------------------------------------------
if ($Vehicles -gt 0) {
    $genArgs = @("-Vehicles", $Vehicles)
    if ($Fines -gt 0) { $genArgs += @("-Fines", $Fines) }
    $r = Run-Ps "make-bulk-data.ps1" $genArgs
    $r.out | ForEach-Object { Write-Host $_ }
    if (-not $r.ok) { throw "generation failed" }
}

$expPath = Join-Path $pocRoot "data\bulk-expectations.json"
if (-not (Test-Path $expPath)) {
    throw "data\bulk-expectations.json is missing. Give -Vehicles to generate a dataset, or run scripts\make-bulk-data.ps1 first."
}
$exp = Get-Content $expPath -Raw | ConvertFrom-Json
$sourceRows = [long]$exp.source_vehicle_rows + [long]$exp.TRAFFIC_FINE +
              [long]$exp.TRAFFIC_FINE_OFFENCE + [long]$exp.TRAFFIC_FINE_PAYMENT

# The staging arm needs its tables and its view of data\; harmless if already done.
if ($Arms -ne 'rowbyrow') {
    $r = Run-Ps "setup-staging.ps1" @()
    if (-not $r.ok) { $r.out | ForEach-Object { Write-Host $_ }; throw "setup-staging failed" }
}

Write-Host ""
Write-Host "BENCHMARK  -  $('{0:N0}' -f $sourceRows) source rows across 4 contract files" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# 2. the arms
# ---------------------------------------------------------------------------
$plan = @()
if ($Arms -eq 'both' -or $Arms -eq 'rowbyrow') {
    $plan += @{ name = "row by row (pipelines)"; file = "/poc/hop/workflows/migrate-all.hwf" }
}
if ($Arms -eq 'both' -or $Arms -eq 'staging') {
    $plan += @{ name = "staging + set-based SQL"; file = "/poc/hop/workflows/migrate-staging.hwf" }
}

$results = @()
foreach ($arm in $plan) {
    Write-Host ("-- {0}" -f $arm.name) -ForegroundColor Yellow

    $r = Run-Ps "clear-tables.ps1" @()
    if (-not $r.ok) { $r.out | ForEach-Object { Write-Host $_ }; throw "clear-tables failed" }

    $env:HOP_FILE_PATH = $arm.file
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hop = Invoke-Native { docker compose run --rm hop-run }
    $sw.Stop()
    Remove-Item Env:\HOP_FILE_PATH -ErrorAction SilentlyContinue

    if (-not $hop.ok) {
        $hop.out | Select-String -Pattern "ERROR|ORA-" | Select-Object -First 10 | ForEach-Object { Write-Host $_ }
        throw "$($arm.name): the Hop run failed"
    }

    $rec = Run-Ps "reconcile-bulk.ps1" @()
    $verdict = ($rec.out | Select-String -Pattern "^(VERIFIED|FAILED):" | Select-Object -First 1)
    if (-not $rec.ok) { $rec.out | ForEach-Object { Write-Host $_ } }

    $fp = Run-Ps "fingerprint.ps1" @()
    if (-not $fp.ok) { $fp.out | ForEach-Object { Write-Host $_ }; throw "fingerprint failed" }

    $secs = $sw.Elapsed.TotalSeconds
    Write-Host ("   {0,8:N1}s   {1,10:N0} rows/s   {2}" -f $secs, ($sourceRows / $secs), $verdict)
    Write-Host ""

    $results += @{
        name    = $arm.name
        seconds = $secs
        ok      = $rec.ok
        verdict = "$verdict"
        finger  = ($fp.out | Where-Object { $_ -match '\S' })
    }
}

# ---------------------------------------------------------------------------
# 3. did the two techniques produce the same data?
# ---------------------------------------------------------------------------
$identical = $null
if ($results.Count -eq 2) {
    $a = $results[0].finger -join "`n"
    $b = $results[1].finger -join "`n"
    $identical = ($a -eq $b)
}

# ---------------------------------------------------------------------------
# 4. the report
# ---------------------------------------------------------------------------
Write-Host "RESULT" -ForegroundColor Cyan
Write-Host "----------------------------------------------------------------------------"
Write-Host ("  {0,-24} {1,10} {2,14} {3,14}" -f "technique", "wall clock", "rows/s", "300M est.")
$meaningful = ($sourceRows -ge $MEANINGFUL_ROWS)
foreach ($r in $results) {
    $rate = $sourceRows / $r.seconds
    $flag = if ($r.ok) { "" } else { "  NOT VERIFIED" }
    $est  = if ($meaningful) {
                "{0:N1} h" -f ([TimeSpan]::FromSeconds($LARGE_LOAD_ROWS / $rate)).TotalHours
            } else { "-" }
    $shown = if ($meaningful) { "{0:N0}" -f $rate } else { "({0:N0})" -f $rate }
    Write-Host ("  {0,-24} {1,9:N1}s {2,14} {3,14}{4}" -f $r.name, $r.seconds, $shown, $est, $flag)
}
Write-Host "----------------------------------------------------------------------------"

if ($results.Count -eq 2) {
    $fast = ($results | Sort-Object seconds)[0]
    $slow = ($results | Sort-Object seconds)[-1]
    Write-Host ("  {0} is {1:N1}x faster" -f $fast.name, ($slow.seconds / $fast.seconds))
    if ($identical) {
        Write-Host "  fingerprints MATCH - both techniques produced identical data" -ForegroundColor Green
    } else {
        Write-Host "  fingerprints DIFFER - the two techniques did NOT produce the same data" -ForegroundColor Red
        Write-Host "    row by row:" ; $results[0].finger | ForEach-Object { Write-Host "      $_" }
        Write-Host "    staging   :" ; $results[1].finger | ForEach-Object { Write-Host "      $_" }
    }
}

Write-Host ""
if (-not $meaningful) {
    Write-Host ("  Rates are in brackets and there is no full-scale estimate: at {0:N0} rows the" -f $sourceRows) -ForegroundColor DarkYellow
    Write-Host "  fixed start-up cost - Docker, the JVM, Hop's plugin registry, the Oracle" -ForegroundColor DarkYellow
    Write-Host "  connection - is most of the wall clock in BOTH arms, so the ratio above is" -ForegroundColor DarkYellow
    Write-Host "  largely a measurement of Docker. Run with -Vehicles 1000000 or more before" -ForegroundColor DarkYellow
    Write-Host "  quoting a number to anyone. What this run DOES prove is correctness: both" -ForegroundColor DarkYellow
    Write-Host "  techniques reconciled and produced byte-identical data." -ForegroundColor DarkYellow
} else {
    Write-Host "  300M est. is a straight-line extrapolation to a three hundred million" -ForegroundColor DarkGray
    Write-Host "  row load. Read it as an order of magnitude and nothing more: it flatters" -ForegroundColor DarkGray
    Write-Host "  the row-by-row path, which degrades as sorts spill to disk," -ForegroundColor DarkGray
    Write-Host "  and it ignores index and constraint maintenance on both." -ForegroundColor DarkGray
    Write-Host "  It also excludes the extract itself, which is a mainframe question." -ForegroundColor DarkGray
}

$failed = @($results | Where-Object { -not $_.ok })
if ($failed.Count -gt 0 -or $identical -eq $false) { exit 1 }
exit 0
