/*
Builds the M5 database end to end. Run in SQLCMD mode.

    Command line (from anywhere):
        sqlcmd -S localhost -E -C -i "C:\path\to\m5-retail-replenishment\build.sql"

    SSMS:
        Query > SQLCMD Mode, then Execute.

Edit the two paths below first.
*/
:setvar RepoDir "C:\path\to\m5-retail-replenishment"
:setvar RawDir "C:\m5\raw"
:on error exit

-- Deploy database, schemas, and procedures
:r "$(RepoDir)\sql\00_setup\01_create_database.sql"
:r "$(RepoDir)\sql\00_setup\02_create_schemas.sql"
:r "$(RepoDir)\sql\01_staging\usp_load_staging.sql"
:r "$(RepoDir)\sql\02_dimensions\usp_build_dimensions.sql"
:r "$(RepoDir)\sql\06_validation\usp_validate.sql"
:r "$(RepoDir)\sql\99_orchestration\usp_build_all.sql"

-- Build
USE M5;
GO
EXEC dbo.usp_build_all @raw_dir = N'$(RawDir)';
GO
