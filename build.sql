/*
Builds the M5 database end to end. Run through build.cmd from the repo root:

    .\build.cmd                  raw files in C:\m5\raw (default)
    .\build.cmd D:\data\m5       raw files somewhere else

Paths in :r are relative to the repo root, and RawDir comes in from the
command line, so nothing in this file needs editing per machine.
*/
:on error exit

-- Deploy database, schemas, and procedures
:r sql\00_setup\01_create_database.sql
:r sql\00_setup\02_create_schemas.sql
:r sql\01_staging\usp_load_staging.sql
:r sql\02_dimensions\usp_build_dimensions.sql
:r sql\03_facts\usp_build_sales_facts.sql
:r sql\06_validation\usp_validate.sql
:r sql\99_orchestration\usp_build_all.sql

-- Build
USE M5;
GO
EXEC dbo.usp_build_all @raw_dir = N'$(RawDir)';
GO
