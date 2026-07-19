-- =============================================================================
-- validate-databases.sql
-- -----------------------------------------------------------------------------
-- Validacao estritamente READ-ONLY do estado produzido por
-- bootstrap-databases.sql. Nao altera estado, nao le secrets, nao imprime
-- senhas. Acumula falhas em uma tabela temporaria de sessao e, ao final,
-- lanca RAISERROR (severidade 16) caso qualquer verificacao falhe, fazendo o
-- sqlcmd (-b) encerrar com codigo diferente de zero.
-- =============================================================================

SET NOCOUNT ON;
GO

IF OBJECT_ID('tempdb..#failures') IS NOT NULL DROP TABLE #failures;
CREATE TABLE #failures (reason nvarchar(400) NOT NULL);
GO

-- -----------------------------------------------------------------------------
-- 1. Contexto master: bancos e logins.
-- -----------------------------------------------------------------------------
IF DB_ID(N'OficinaCadastroDb')      IS NULL INSERT INTO #failures VALUES (N'Banco ausente: OficinaCadastroDb');
IF DB_ID(N'OficinaEstoqueDb')       IS NULL INSERT INTO #failures VALUES (N'Banco ausente: OficinaEstoqueDb');
IF DB_ID(N'OficinaOrdensServicoDb') IS NULL INSERT INTO #failures VALUES (N'Banco ausente: OficinaOrdensServicoDb');

-- 1.1 Sete logins existem.
DECLARE @logins TABLE (name sysname PRIMARY KEY);
INSERT INTO @logins (name) VALUES
    (N'cadastro_app'), (N'cadastro_migrator'),
    (N'estoque_app'), (N'estoque_migrator'),
    (N'ordens_app'), (N'ordens_migrator'),
    (N'auth_read');

INSERT INTO #failures (reason)
SELECT N'Login ausente: ' + l.name
FROM @logins l
WHERE SUSER_ID(l.name) IS NULL;

-- 1.2 Todos os logins habilitados.
INSERT INTO #failures (reason)
SELECT N'Login desabilitado ou nao-SQL: ' + l.name
FROM @logins l
WHERE NOT EXISTS (
    SELECT 1 FROM sys.sql_logins s
    WHERE s.name = l.name AND s.is_disabled = 0
);
GO

-- -----------------------------------------------------------------------------
-- 2. OficinaCadastroDb.
-- -----------------------------------------------------------------------------
USE [OficinaCadastroDb];
GO

-- Usuarios esperados presentes.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'cadastro_app'      AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Cadastro: cadastro_app');
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'cadastro_migrator' AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Cadastro: cadastro_migrator');
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'auth_read'         AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Cadastro: auth_read');

-- Runtime: datareader + datawriter, sem db_owner e sem db_ddladmin.
IF IS_ROLEMEMBER('db_datareader', 'cadastro_app') = 0 INSERT INTO #failures VALUES (N'cadastro_app sem db_datareader em Cadastro');
IF IS_ROLEMEMBER('db_datawriter', 'cadastro_app') = 0 INSERT INTO #failures VALUES (N'cadastro_app sem db_datawriter em Cadastro');
IF IS_ROLEMEMBER('db_owner',    'cadastro_app') = 1 INSERT INTO #failures VALUES (N'cadastro_app com db_owner em Cadastro');
IF IS_ROLEMEMBER('db_ddladmin', 'cadastro_app') = 1 INSERT INTO #failures VALUES (N'cadastro_app com db_ddladmin em Cadastro');

-- Migrator: db_ddladmin, sem db_owner.
IF IS_ROLEMEMBER('db_ddladmin', 'cadastro_migrator') = 0 INSERT INTO #failures VALUES (N'cadastro_migrator sem db_ddladmin em Cadastro');
IF IS_ROLEMEMBER('db_owner',    'cadastro_migrator') = 1 INSERT INTO #failures VALUES (N'cadastro_migrator com db_owner em Cadastro');

-- auth_read: role auth_reader existe, auth_read e membro e possui leitura.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'auth_reader' AND type = 'R') INSERT INTO #failures VALUES (N'Role ausente em Cadastro: auth_reader');
IF IS_ROLEMEMBER('auth_reader', 'auth_read') = 0 INSERT INTO #failures VALUES (N'auth_read nao e membro de auth_reader');
IF IS_ROLEMEMBER('db_owner',    'auth_read') = 1 INSERT INTO #failures VALUES (N'auth_read com db_owner em Cadastro');
IF IS_ROLEMEMBER('db_ddladmin', 'auth_read') = 1 INSERT INTO #failures VALUES (N'auth_read com db_ddladmin em Cadastro');

-- Leitura de auth_reader: db_datareader OU SELECT no schema auth.
IF IS_ROLEMEMBER('db_datareader', 'auth_reader') = 0
   AND NOT EXISTS (
       SELECT 1
       FROM sys.database_permissions dp
       JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
       JOIN sys.schemas sc ON sc.schema_id = dp.major_id
       WHERE pr.name = N'auth_reader'
         AND dp.class = 3                 -- SCHEMA
         AND dp.permission_name = N'SELECT'
         AND dp.state = N'G'              -- GRANT
         AND sc.name = N'auth'
   )
    INSERT INTO #failures VALUES (N'auth_reader sem leitura (db_datareader ou SELECT em schema auth)');

-- Isolamento: nenhum usuario gerenciado de outra stack presente.
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name IN (N'estoque_app', N'estoque_migrator', N'ordens_app', N'ordens_migrator') AND type = 'S')
    INSERT INTO #failures VALUES (N'Usuario gerenciado indevido presente em Cadastro');
GO

-- -----------------------------------------------------------------------------
-- 3. OficinaEstoqueDb.
-- -----------------------------------------------------------------------------
USE [OficinaEstoqueDb];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'estoque_app'      AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Estoque: estoque_app');
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'estoque_migrator' AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Estoque: estoque_migrator');

IF IS_ROLEMEMBER('db_datareader', 'estoque_app') = 0 INSERT INTO #failures VALUES (N'estoque_app sem db_datareader em Estoque');
IF IS_ROLEMEMBER('db_datawriter', 'estoque_app') = 0 INSERT INTO #failures VALUES (N'estoque_app sem db_datawriter em Estoque');
IF IS_ROLEMEMBER('db_owner',    'estoque_app') = 1 INSERT INTO #failures VALUES (N'estoque_app com db_owner em Estoque');
IF IS_ROLEMEMBER('db_ddladmin', 'estoque_app') = 1 INSERT INTO #failures VALUES (N'estoque_app com db_ddladmin em Estoque');

IF IS_ROLEMEMBER('db_ddladmin', 'estoque_migrator') = 0 INSERT INTO #failures VALUES (N'estoque_migrator sem db_ddladmin em Estoque');
IF IS_ROLEMEMBER('db_owner',    'estoque_migrator') = 1 INSERT INTO #failures VALUES (N'estoque_migrator com db_owner em Estoque');

-- Isolamento: nenhum usuario de Cadastro, Ordens ou auth_read.
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name IN (N'cadastro_app', N'cadastro_migrator', N'auth_read', N'ordens_app', N'ordens_migrator') AND type = 'S')
    INSERT INTO #failures VALUES (N'Usuario gerenciado indevido presente em Estoque');
GO

-- -----------------------------------------------------------------------------
-- 4. OficinaOrdensServicoDb.
-- -----------------------------------------------------------------------------
USE [OficinaOrdensServicoDb];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ordens_app'      AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Ordens: ordens_app');
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ordens_migrator' AND type = 'S') INSERT INTO #failures VALUES (N'Usuario ausente em Ordens: ordens_migrator');

IF IS_ROLEMEMBER('db_datareader', 'ordens_app') = 0 INSERT INTO #failures VALUES (N'ordens_app sem db_datareader em Ordens');
IF IS_ROLEMEMBER('db_datawriter', 'ordens_app') = 0 INSERT INTO #failures VALUES (N'ordens_app sem db_datawriter em Ordens');
IF IS_ROLEMEMBER('db_owner',    'ordens_app') = 1 INSERT INTO #failures VALUES (N'ordens_app com db_owner em Ordens');
IF IS_ROLEMEMBER('db_ddladmin', 'ordens_app') = 1 INSERT INTO #failures VALUES (N'ordens_app com db_ddladmin em Ordens');

IF IS_ROLEMEMBER('db_ddladmin', 'ordens_migrator') = 0 INSERT INTO #failures VALUES (N'ordens_migrator sem db_ddladmin em Ordens');
IF IS_ROLEMEMBER('db_owner',    'ordens_migrator') = 1 INSERT INTO #failures VALUES (N'ordens_migrator com db_owner em Ordens');

-- Isolamento: nenhum usuario de Cadastro, Estoque ou auth_read.
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name IN (N'cadastro_app', N'cadastro_migrator', N'auth_read', N'estoque_app', N'estoque_migrator') AND type = 'S')
    INSERT INTO #failures VALUES (N'Usuario gerenciado indevido presente em Ordens');
GO

-- -----------------------------------------------------------------------------
-- 5. Resultado final.
-- -----------------------------------------------------------------------------
USE [master];
GO

IF EXISTS (SELECT 1 FROM #failures)
BEGIN
    DECLARE @n int = (SELECT COUNT(*) FROM #failures);
    SELECT N'[FALHA] ' + reason AS Validacao FROM #failures ORDER BY reason;
    DROP TABLE #failures;
    RAISERROR('validate-databases: %d verificacao(oes) falharam.', 16, 1, @n);
    RETURN;
END

DROP TABLE #failures;
PRINT 'validate-databases: todas as verificacoes passaram.';
GO
