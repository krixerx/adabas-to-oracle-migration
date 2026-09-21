# Enlarge the online redo logs. Run once before any volume run; re-runnable.
#
#     scripts\resize-redo.ps1                    # 3 groups x 512 MB
#     scripts\resize-redo.ps1 -SizeMb 1024       # bigger still
#
# WHY. gvenzl/oracle-free ships TWO redo groups of TEN MEGABYTES. A 100,000
# vehicle load writes about a gigabyte of redo, so it switches logs a hundred
# times and stalls on each one waiting for the checkpoint to catch up
# (v$session_event: 'log file switch (checkpoint incomplete)', measured
# 2026-09-21). At 1,000,000 vehicles that is a thousand switches.
#
# It is worse than slow, it is UNFAIR: the row-by-row arm and the direct-path
# staging arm generate very different amounts of redo, so undersized logs
# distort the comparison scripts\benchmark.ps1 exists to make. A benchmark that
# measures the log writer is not measuring the technique.
#
# Redo logs belong to the CDB, not the PDB, and they live in the oracle-data
# named volume - so this survives a container recreate, and is lost (back to
# 2 x 10 MB) by `docker compose down -v`. Run it again after that.
#
# Not part of migrate.cmd on purpose: it is a one-off change to the lab's
# storage layout, not a step of the migration.
[CmdletBinding()]
param(
    [int]$SizeMb = 512,
    [int]$Groups = 3
)
$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# A here-string piped into sqlplus arrives with a BOM, which sqlplus reports as
# SP2-0734 against whatever is on line 1 - hence the leading blank line, which
# gives the BOM somewhere harmless to land.
function Invoke-Sql([string]$body) {
    $sql = "`nWHENEVER SQLERROR EXIT SQL.SQLCODE`nSET FEEDBACK OFF`nSET HEADING OFF`nSET PAGESIZE 0`nSET LINESIZE 300`n" +
           $body + "`nEXIT;`n"
    $out = $sql | docker exec -i a2o-oracle sqlplus -s "sys/PocSysPwd1@//localhost:1521/FREE as sysdba"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($out -join "`n")
        throw "sqlplus failed (exit $LASTEXITCODE)"
    }
    # sqlplus greets a piped here-string with
    #     SP2-0042: unknown command "<BOM>" - rest of line ignored
    # because PowerShell puts a byte order mark at the head of the stream no
    # matter what $OutputEncoding says. It is harmless noise, but a caller that
    # casts the first line to an int gets "cannot convert SP2-0042:" instead of
    # a number - so the noise is stripped here rather than at every call site.
    return @($out |
        ForEach-Object { ($_ -replace "﻿", "").Trim() } |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^(SP2-|Help: https)' })
}

docker exec a2o-oracle true 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "a2o-oracle is not running. Start the lab first: scripts\lab-up.ps1"
    exit 1
}

$bytes = [long]$SizeMb * 1024 * 1024

# --- what is there now -------------------------------------------------------
# @(...) at the CALL SITE, not just inside the function: PowerShell unwraps a
# single-element array on the way out of a function, so (Invoke-Sql ...)[0] was
# indexing into a String and quietly yielding its first CHARACTER. Everything
# downstream then read as "group 0, directory nothing", and the first thing that
# noticed was Oracle refusing to add a logfile group 1 that already existed.
$survey = @(Invoke-Sql ("SELECT (SELECT COUNT(*) FROM v`$log) || ' ' ||
       (SELECT COUNT(*) FROM v`$log WHERE bytes >= {BYTES}) || ' ' ||
       (SELECT MAX(group#) FROM v`$log) || ' ' ||
       (SELECT MIN(SUBSTR(member, 1, INSTR(member, '/', -1))) FROM v`$logfile)
  FROM dual;".Replace("{BYTES}", "$bytes")))[0] -split '\s+'

$total    = [int]$survey[0]
$atSize   = [int]$survey[1]
$maxGroup = [int]$survey[2]
$dir      = $survey[3]

Write-Host ""
Write-Host "Redo logs: $total group(s), $atSize of them at least $SizeMb MB. Target: $Groups x $SizeMb MB." -ForegroundColor Cyan

if ($atSize -ge $Groups -and $atSize -eq $total) {
    Write-Host "  already sized - nothing to do."
    exit 0
}

# The members about to be replaced, captured BEFORE the drop: once the group is
# gone, v$logfile cannot tell us which file on disk was its.
# Oracle does not delete the file when the group is dropped (these are not OMF -
# db_create_file_dest is empty), so it would sit there forever otherwise.
$oldMembers = @(Invoke-Sql ("SELECT member FROM v`$logfile WHERE group# <= $maxGroup ORDER BY group#;"))

# --- add the new groups ------------------------------------------------------
$add = ""
for ($i = 1; $i -le $Groups; $i++) {
    $g = $maxGroup + $i
    $add += "ALTER DATABASE ADD LOGFILE GROUP $g ('${dir}redo_a2o_$g.log') SIZE ${SizeMb}M;`n"
}
Invoke-Sql $add | Out-Null
Write-Host "  added $Groups group(s) of $SizeMb MB in $dir"

# --- rotate off the old ones, then drop them ---------------------------------
# A group can only be dropped when it is neither CURRENT nor ACTIVE. Switching
# makes it not-current; a checkpoint makes it not-active. Both are cheap here,
# and the retry loop exists because the switch is asynchronous - LGWR may still
# be finishing with the group when the DROP arrives.
$drop = @'
DECLARE
  v_cur NUMBER;
BEGIN
  FOR i IN 1 .. 20 LOOP
    SELECT group# INTO v_cur FROM v$log WHERE status = 'CURRENT';
    EXIT WHEN v_cur > {MAXOLD};
    EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
  END LOOP;
  EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';

  FOR g IN (SELECT group# FROM v$log WHERE group# <= {MAXOLD} ORDER BY group#) LOOP
    FOR attempt IN 1 .. 15 LOOP
      BEGIN
        EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || g.group#;
        EXIT;
      EXCEPTION WHEN OTHERS THEN
        IF attempt = 15 THEN RAISE; END IF;
        EXECUTE IMMEDIATE 'ALTER SYSTEM SWITCH LOGFILE';
        EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';
        DBMS_SESSION.SLEEP(1);
      END;
    END LOOP;
  END LOOP;
END;
/
'@
Invoke-Sql $drop.Replace("{MAXOLD}", "$maxGroup") | Out-Null
Write-Host "  dropped the $maxGroup old group(s)"

# --- and the files they left behind ------------------------------------------
$still = @(Invoke-Sql ("SELECT COUNT(*) FROM v`$logfile WHERE group# <= $maxGroup;"))
if ([int]$still[0] -eq 0 -and $oldMembers.Count -gt 0) {
    $rm = ($oldMembers | ForEach-Object { "rm -f '$_'" }) -join "; "
    docker exec a2o-oracle sh -c $rm | Out-Null
    Write-Host "  removed $($oldMembers.Count) old redo file(s) from disk"
}

# --- report ------------------------------------------------------------------
Write-Host ""
Invoke-Sql ("SELECT '  group ' || group# || '  ' || LPAD(ROUND(bytes/1024/1024), 5) || ' MB  ' || status
  FROM v`$log ORDER BY group#;") | ForEach-Object { Write-Host $_ }
Write-Host ""
exit 0
