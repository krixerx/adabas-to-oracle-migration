# Show how far a running migration has got, from the outside.
#
#     scripts\watch-progress.ps1                 # refresh every 10s until done
#     scripts\watch-progress.ps1 -Interval 30
#     scripts\watch-progress.ps1 -Once
#
# Run it in a SECOND window while migrate.cmd or benchmark.ps1 is working. It
# touches nothing - it counts rows in the target (and staging) tables and
# compares them with data\bulk-expectations.json, which the generator wrote
# while producing the files. Read-only by construction: an observer, never a
# dependency.
#
# WHY IT IS NOT IN THE HOP LOG. Hop reports each transform's row count when the
# pipeline ENDS, which is exactly when you no longer need it. Its internal
# feedback counter is not a pipeline setting in Hop 2.x (checked in
# hop-engine-2.19.0.jar: Pipeline has setFeedbackShown(), the XML has no element
# for it), so there is nothing to switch on in the .hpl files. Counting the
# target tables works for BOTH techniques, needs no change to either, and is
# the same thing you would do against a real migration at three in the morning.
#
# At 11 M rows each refresh scans a few million index entries. That is cheap
# next to the load itself, but do not point it at a production database every
# second and call it monitoring.
[CmdletBinding()]
param(
    [int]$Interval = 10,
    [switch]$Once
)
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$pocRoot = Split-Path $PSScriptRoot -Parent

# Target row counts, accumulated by make-bulk-data.ps1 WHILE it wrote the files.
# Without them this still runs - it just shows counts with no denominator.
$expPath = Join-Path $pocRoot "data\bulk-expectations.json"
$exp = $null
if (Test-Path $expPath) { $exp = Get-Content $expPath -Raw | ConvertFrom-Json }

# Staging mirrors the FILE, so its expected count is the source row count, not
# the target's - stg_vehicle holds one row per plate, vehicle holds one per car.
$expected = @{}
if ($exp) {
    $expected = @{
        "STG_VEHICLE"          = [long]$exp.source_vehicle_rows
        "STG_TRAFFIC_FINE"     = [long]$exp.TRAFFIC_FINE
        "STG_FINE_OFFENCE"     = [long]$exp.TRAFFIC_FINE_OFFENCE
        "STG_FINE_PAYMENT"     = [long]$exp.TRAFFIC_FINE_PAYMENT
        "VEHICLE"              = [long]$exp.VEHICLE
        "VEHICLE_PLATE"        = [long]$exp.VEHICLE_PLATE
        "TRAFFIC_FINE"         = [long]$exp.TRAFFIC_FINE
        "TRAFFIC_FINE_OFFENCE" = [long]$exp.TRAFFIC_FINE_OFFENCE
        "TRAFFIC_FINE_PAYMENT" = [long]$exp.TRAFFIC_FINE_PAYMENT
        "MIGRATION_REJECT"     = [long]$exp.MIGRATION_REJECT
    }
}
# Display order: staging fills first on the --staging path, targets on both.
$order = @("STG_VEHICLE","STG_TRAFFIC_FINE","STG_FINE_OFFENCE","STG_FINE_PAYMENT",
           "VEHICLE","VEHICLE_PLATE","TRAFFIC_FINE","TRAFFIC_FINE_OFFENCE",
           "TRAFFIC_FINE_PAYMENT","MIGRATION_REJECT")

# One round trip per refresh, and it skips tables that do not exist yet - a
# reset lab has no staging layer until setup-staging.ps1 has run, and a plain
# SELECT against a missing table would end the whole poll with ORA-00942.
$countSql = @'

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET HEADING OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
DECLARE
  n NUMBER;
BEGIN
  FOR t IN (SELECT table_name FROM all_tables
             WHERE owner = 'POCAPP'
               AND table_name IN ('STG_VEHICLE','STG_TRAFFIC_FINE','STG_FINE_OFFENCE',
                                  'STG_FINE_PAYMENT','VEHICLE','VEHICLE_PLATE','TRAFFIC_FINE',
                                  'TRAFFIC_FINE_OFFENCE','TRAFFIC_FINE_PAYMENT','MIGRATION_REJECT'))
  LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM pocapp.' || t.table_name INTO n;
    DBMS_OUTPUT.PUT_LINE(t.table_name || ' ' || n);
  END LOOP;
END;
/
EXIT;
'@

function Get-Counts {
    $out = $countSql | docker exec -i a2o-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1
    if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n"); throw "count query failed" }
    $h = @{}
    foreach ($line in $out) {
        # The piped here-string arrives with a BOM; sqlplus answers SP2-0042.
        $l = ($line -replace "`u{FEFF}", "").Trim()
        if ($l -match '^([A-Z_]+)\s+(\d+)$') { $h[$Matches[1]] = [long]$Matches[2] }
    }
    return $h
}

function Show-Bar([string]$name, [long]$now, [long]$want, [double]$rate) {
    $bar = ""
    $pct = ""
    if ($want -gt 0) {
        $f = [Math]::Min(1.0, $now / [double]$want)
        $filled = [int][Math]::Round($f * 28)
        $bar = "[" + ("#" * $filled) + ("." * (28 - $filled)) + "]"
        $pct = "{0,5:N1}%" -f ($f * 100)
    } else {
        $bar = "[" + ("." * 28) + "]"
        $pct = "     -"
    }
    $eta = ""
    if ($rate -gt 1 -and $want -gt $now) {
        $secs = ($want - $now) / $rate
        $eta = "  eta {0}" -f ([TimeSpan]::FromSeconds([Math]::Round($secs))).ToString("hh\:mm\:ss")
    } elseif ($want -gt 0 -and $now -ge $want) {
        $eta = "  done"
    }
    $r = if ($rate -gt 1) { "{0,9:N0}/s" -f $rate } else { "" }
    Write-Host ("  {0,-22} {1} {2} {3,12:N0} / {4,-12:N0} {5}{6}" -f $name, $bar, $pct, $now, $want, $r, $eta)
}

docker exec a2o-oracle true 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "a2o-oracle is not running. Start the lab first: scripts\lab-up.ps1"
    exit 1
}

$prev = $null
$prevAt = $null
while ($true) {
    $now = Get-Counts
    $at  = Get-Date
    $secs = if ($prevAt) { ($at - $prevAt).TotalSeconds } else { 0 }

    Write-Host ""
    Write-Host ("  {0}   (POCAPP)" -f $at.ToString("HH:mm:ss")) -ForegroundColor Cyan
    $allDone = $expected.Count -gt 0
    foreach ($t in $order) {
        if (-not $now.ContainsKey($t)) { continue }
        $want = if ($expected.ContainsKey($t)) { $expected[$t] } else { 0 }
        $rate = 0.0
        if ($prev -and $prev.ContainsKey($t) -and $secs -gt 0) {
            $rate = ($now[$t] - $prev[$t]) / $secs
        }
        Show-Bar $t $now[$t] $want $rate
        # Staging tables are only populated by the --staging arm, so they must not
        # hold the "finished" verdict hostage on a row-by-row run.
        if ($want -gt 0 -and $now[$t] -lt $want -and $t -notlike "STG_*") { $allDone = $false }
    }

    if ($Once) { break }
    if ($allDone) {
        Write-Host ""
        Write-Host "  every target table has reached its expected count." -ForegroundColor Green
        Write-Host "  that is not a verification - run scripts\reconcile-bulk.ps1 for that."
        break
    }
    $prev = $now; $prevAt = $at
    Start-Sleep -Seconds $Interval
}
Write-Host ""
exit 0
