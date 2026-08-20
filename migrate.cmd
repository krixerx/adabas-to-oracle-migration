@echo off
rem ============================================================
rem  Adabas to Oracle migration - the one command.
rem    migrate.cmd                 full run (extract + load + verify)
rem    migrate.cmd --skip-extract  inner mapping loop (reuse existing CSVs)
rem    migrate.cmd --staging       reshape in set-based SQL instead of row by row
rem
rem  --staging swaps ONLY the transform technique. Same extract, same target
rem  tables, same reconciliation, same "VERIFIED: 11/11" - the files land in
rem  Oracle unchanged and the redesign happens there. See hop\sql\ and
rem  scripts\benchmark.ps1, which runs both and proves they agree.
rem ============================================================
setlocal
cd /d "%~dp0"

set SKIP_EXTRACT=0
set STAGING=0
for %%a in (%*) do (
  if /I "%%a"=="--skip-extract" set SKIP_EXTRACT=1
  if /I "%%a"=="--staging" set STAGING=1
)

rem --- preflight: the Oracle JDBC driver is NOT in this repo -----------------
rem docker-compose bind-mounts hop\lib\ojdbc11.jar as a FILE. If it is missing,
rem Docker silently creates a DIRECTORY with that name, Hop starts with no JDBC
rem driver and fails obscurely - and the junk directory then has to be deleted
rem before the real jar will mount. Fail clearly here instead.
if not exist "hop\lib\ojdbc11.jar" (
  echo.
  echo ERROR: hop\lib\ojdbc11.jar is missing.
  echo.
  echo   The Oracle JDBC driver is not redistributed in this repository
  echo   ^(Oracle OTN licence^). Download ojdbc11.jar and place it at:
  echo       hop\lib\ojdbc11.jar
  echo.
  echo   https://www.oracle.com/database/technologies/appdev/jdbc-downloads.html
  echo.
  exit /b 2
)
dir /a-d "hop\lib\ojdbc11.jar" >nul 2>&1
if errorlevel 1 (
  echo.
  echo ERROR: hop\lib\ojdbc11.jar exists but is a DIRECTORY, not a file.
  echo   Docker created it on an earlier run. Delete it, then put the real
  echo   ojdbc11.jar there:  rmdir /s /q "hop\lib\ojdbc11.jar"
  echo.
  exit /b 2
)

echo.
echo [1/5] Starting the stack (docker compose up -d --wait) ...
docker compose up -d --wait adabas natural oracle
if errorlevel 1 goto :fail

if "%SKIP_EXTRACT%"=="1" (
  echo [2/5] Extract SKIPPED - using existing CSVs in data\
  goto :clear
)
echo [2/5] Extracting from Adabas (Natural batch) ...
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\extract.ps1
if errorlevel 1 goto :fail

:clear
echo [3/5] Clearing migrated target tables (DELETE child-first) ...
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\clear-tables.ps1
if errorlevel 1 goto :fail

if "%STAGING%"=="1" (
  echo [4/5] Transform + load ^(staging + set-based SQL^) ...
  rem The staging tables and the external tables over data\ are created here
  rem rather than assumed: oracle-init only runs on a container's FIRST start,
  rem so a lab built before this existed has none of it. Idempotent.
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup-staging.ps1
  if errorlevel 1 goto :fail
  set HOP_FILE_PATH=/poc/hop/workflows/migrate-staging.hwf
) else (
  echo [4/5] Transform + load ^(Apache Hop pipelines, row by row^) ...
)
docker compose run --rm hop-run
if errorlevel 1 goto :fail

echo [5/5] Reconciling source vs target ...
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\reconcile.ps1
if errorlevel 1 goto :fail

echo.
echo MIGRATION COMPLETE.
exit /b 0

:fail
echo.
echo MIGRATION FAILED - see output above.
exit /b 1
