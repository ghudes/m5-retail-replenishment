@echo off
rem Builds the M5 database. Usage: build.cmd [raw_dir]   (default C:\m5\raw)
setlocal
cd /d "%~dp0"

set "RAW_DIR=%~1"
if "%RAW_DIR%"=="" set "RAW_DIR=C:\m5\raw"

sqlcmd -S localhost -E -C -b -i build.sql -v RawDir="%RAW_DIR%"
exit /b %ERRORLEVEL%
