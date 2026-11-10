@echo off
rem Builds the M5 database.
rem Usage: build.cmd [raw_dir] [server]
rem   raw_dir  folder with the M5 CSVs           (default C:\m5\raw)
rem   server   SQL Server instance to build on   (default %SQLCMDSERVER%, else localhost)
rem A named instance such as SQL Server Express is localhost\SQLEXPRESS. To avoid
rem passing it every time, set it once:  setx SQLCMDSERVER localhost\SQLEXPRESS
setlocal
cd /d "%~dp0"

set "RAW_DIR=%~1"
if "%RAW_DIR%"=="" set "RAW_DIR=C:\m5\raw"

set "SERVER=%~2"
if "%SERVER%"=="" set "SERVER=%SQLCMDSERVER%"
if "%SERVER%"=="" set "SERVER=localhost"

echo Building M5 on %SERVER% from %RAW_DIR%
sqlcmd -S "%SERVER%" -E -C -b -i build.sql -v RawDir="%RAW_DIR%"
exit /b %ERRORLEVEL%
