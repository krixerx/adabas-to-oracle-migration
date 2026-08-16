@echo off
rem Launch the Apache Hop GUI for the Adabas to Oracle migration project.
rem Set HOP_HOME to wherever the Hop desktop client is installed, or edit the
rem default below.
rem
rem The GUI reaches Oracle on localhost:1521; inside Docker the hostname is "oracle".
rem That value comes from the 'local-gui' Hop ENVIRONMENT (hop-env-local-gui.json) -
rem select it once in the GUI and Hop remembers it. It must NOT be a project variable:
rem a project variable outranks an environment variable and would win on both sides,
rem breaking either the GUI (ORA-17868) or the container runs (ORA-12541).
rem The set below is a harmless belt-and-braces; on its own it does nothing, because
rem Hop does not adopt OS environment variables as Hop variables here.
if "%HOP_HOME%"=="" set HOP_HOME=C:\hop
set ORACLE_HOST=localhost
cd /d "%HOP_HOME%"
start "Apache Hop GUI" hop-gui.bat
