-- =============================================================================
-- bootstrap-databases.sql
-- -----------------------------------------------------------------------------
-- Bootstrap idempotente da stack de bancos SQL Server da Oficina (Fase 4).
--
-- Cria/atualiza, de forma repetivel:
--   * 3 bancos: OficinaCadastroDb, OficinaEstoqueDb, OficinaOrdensServicoDb
--   * 7 logins SQL de aplicacao (runtime, migrator e auth_read)
--   * 7 usuarios nos bancos correspondentes, com permissoes minimas
--   * a role auth_reader em OficinaCadastroDb
--   * isolamento: remove usuarios gerenciados presentes em banco indevido
--
-- NAO cria tabelas funcionais, NAO executa migrations EF, NAO faz seed.
--
-- As sete senhas sao injetadas pelo script de execucao como literais T-SQL ja
-- escapados (aspas simples duplicadas). Os marcadores abaixo sao substituidos
-- antes da execucao e o sqlcmd roda com -x (substituicao de variaveis desligada),
-- de modo que nenhum valor de senha e reinterpretado como variavel:
--
--   $(CADASTRO_APP_PASSWORD_SQL)       $(CADASTRO_MIGRATOR_PASSWORD_SQL)
--   $(ESTOQUE_APP_PASSWORD_SQL)        $(ESTOQUE_MIGRATOR_PASSWORD_SQL)
--   $(ORDENS_APP_PASSWORD_SQL)         $(ORDENS_MIGRATOR_PASSWORD_SQL)
--   $(AUTH_READ_PASSWORD_SQL)
--
-- Compativel com Amazon RDS for SQL Server: nao usa recursos que exijam
-- sysadmin, acesso ao sistema operacional ou configuracao de instancia.
-- =============================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- -----------------------------------------------------------------------------
-- 0. Guarda: o bootstrap precisa rodar conectado ao banco master.
-- -----------------------------------------------------------------------------
IF DB_NAME() <> N'master'
BEGIN
    RAISERROR('bootstrap-databases: precisa estar conectado ao banco master.', 16, 1);
    RETURN;
END
GO

-- -----------------------------------------------------------------------------
-- 1. Criacao idempotente dos tres bancos (cada CREATE DATABASE em seu batch).
-- -----------------------------------------------------------------------------
IF DB_ID(N'OficinaCadastroDb') IS NULL
    CREATE DATABASE [OficinaCadastroDb];
GO

IF DB_ID(N'OficinaEstoqueDb') IS NULL
    CREATE DATABASE [OficinaEstoqueDb];
GO

IF DB_ID(N'OficinaOrdensServicoDb') IS NULL
    CREATE DATABASE [OficinaOrdensServicoDb];
GO

-- -----------------------------------------------------------------------------
-- 2. Criacao/atualizacao idempotente dos sete logins SQL.
--    Mantem a politica de senha padrao suportada pelo RDS (nao usa CHECK_POLICY
--    OFF). Nenhuma role de servidor ampla e concedida.
-- -----------------------------------------------------------------------------
IF SUSER_ID(N'cadastro_app') IS NULL
    CREATE LOGIN [cadastro_app] WITH PASSWORD = N'$(CADASTRO_APP_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [cadastro_app] WITH PASSWORD = N'$(CADASTRO_APP_PASSWORD_SQL)';
ALTER LOGIN [cadastro_app] ENABLE;
GO

IF SUSER_ID(N'cadastro_migrator') IS NULL
    CREATE LOGIN [cadastro_migrator] WITH PASSWORD = N'$(CADASTRO_MIGRATOR_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [cadastro_migrator] WITH PASSWORD = N'$(CADASTRO_MIGRATOR_PASSWORD_SQL)';
ALTER LOGIN [cadastro_migrator] ENABLE;
GO

IF SUSER_ID(N'estoque_app') IS NULL
    CREATE LOGIN [estoque_app] WITH PASSWORD = N'$(ESTOQUE_APP_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [estoque_app] WITH PASSWORD = N'$(ESTOQUE_APP_PASSWORD_SQL)';
ALTER LOGIN [estoque_app] ENABLE;
GO

IF SUSER_ID(N'estoque_migrator') IS NULL
    CREATE LOGIN [estoque_migrator] WITH PASSWORD = N'$(ESTOQUE_MIGRATOR_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [estoque_migrator] WITH PASSWORD = N'$(ESTOQUE_MIGRATOR_PASSWORD_SQL)';
ALTER LOGIN [estoque_migrator] ENABLE;
GO

IF SUSER_ID(N'ordens_app') IS NULL
    CREATE LOGIN [ordens_app] WITH PASSWORD = N'$(ORDENS_APP_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [ordens_app] WITH PASSWORD = N'$(ORDENS_APP_PASSWORD_SQL)';
ALTER LOGIN [ordens_app] ENABLE;
GO

IF SUSER_ID(N'ordens_migrator') IS NULL
    CREATE LOGIN [ordens_migrator] WITH PASSWORD = N'$(ORDENS_MIGRATOR_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [ordens_migrator] WITH PASSWORD = N'$(ORDENS_MIGRATOR_PASSWORD_SQL)';
ALTER LOGIN [ordens_migrator] ENABLE;
GO

IF SUSER_ID(N'auth_read') IS NULL
    CREATE LOGIN [auth_read] WITH PASSWORD = N'$(AUTH_READ_PASSWORD_SQL)';
ELSE
    ALTER LOGIN [auth_read] WITH PASSWORD = N'$(AUTH_READ_PASSWORD_SQL)';
ALTER LOGIN [auth_read] ENABLE;
GO

-- =============================================================================
-- 3. OficinaCadastroDb: usuarios, permissoes e isolamento.
-- =============================================================================
USE [OficinaCadastroDb];
GO

-- 3.1 Isolamento: remove usuarios gerenciados que NAO pertencem a este banco.
--     So remove nomes da allowlist gerenciada, apenas usuarios SQL (type 'S'),
--     nunca usuarios de sistema, administrativos ou desconhecidos.
DECLARE @managed TABLE (name sysname PRIMARY KEY);
INSERT INTO @managed (name) VALUES
    (N'cadastro_app'), (N'cadastro_migrator'), (N'auth_read'),
    (N'estoque_app'), (N'estoque_migrator'),
    (N'ordens_app'), (N'ordens_migrator');

DECLARE @allowed TABLE (name sysname PRIMARY KEY);
INSERT INTO @allowed (name) VALUES
    (N'cadastro_app'), (N'cadastro_migrator'), (N'auth_read');

DECLARE @foreignUser sysname;
DECLARE @schemaName sysname;
DECLARE @stmt nvarchar(max);

WHILE EXISTS (
    SELECT 1
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed)
)
BEGIN
    SELECT TOP 1 @foreignUser = p.name
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed);

    -- Reatribui schemas eventualmente possuidos pelo usuario antes do DROP.
    WHILE EXISTS (
        SELECT 1 FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser
    )
    BEGIN
        SELECT TOP 1 @schemaName = s.name FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser;
        SET @stmt = N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(@schemaName) + N' TO dbo;';
        EXEC sp_executesql @stmt;
    END

    SET @stmt = N'DROP USER ' + QUOTENAME(@foreignUser) + N';';
    EXEC sp_executesql @stmt;
    PRINT 'Isolamento OficinaCadastroDb: usuario indevido removido -> ' + @foreignUser;
END
GO

-- 3.2 Runtime: cadastro_app -> leitura + escrita + EXECUTE (sem DDL).
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'cadastro_app' AND type = 'S')
    CREATE USER [cadastro_app] FOR LOGIN [cadastro_app];
ELSE
    ALTER USER [cadastro_app] WITH LOGIN = [cadastro_app];   -- corrige SID orfao
IF IS_ROLEMEMBER('db_datareader', 'cadastro_app') = 0 ALTER ROLE [db_datareader] ADD MEMBER [cadastro_app];
IF IS_ROLEMEMBER('db_datawriter', 'cadastro_app') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [cadastro_app];
GRANT EXECUTE TO [cadastro_app];   -- compatibilidade com stored procedures (documentado)
GO

-- 3.3 Migrator: cadastro_migrator -> DDL + leitura + escrita + EXECUTE.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'cadastro_migrator' AND type = 'S')
    CREATE USER [cadastro_migrator] FOR LOGIN [cadastro_migrator];
ELSE
    ALTER USER [cadastro_migrator] WITH LOGIN = [cadastro_migrator];
IF IS_ROLEMEMBER('db_ddladmin', 'cadastro_migrator') = 0 ALTER ROLE [db_ddladmin] ADD MEMBER [cadastro_migrator];
IF IS_ROLEMEMBER('db_datareader', 'cadastro_migrator') = 0 ALTER ROLE [db_datareader] ADD MEMBER [cadastro_migrator];
IF IS_ROLEMEMBER('db_datawriter', 'cadastro_migrator') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [cadastro_migrator];
GRANT EXECUTE TO [cadastro_migrator];
GO

-- 3.4 auth_read: somente leitura no Cadastro, via role dedicada auth_reader.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'auth_read' AND type = 'S')
    CREATE USER [auth_read] FOR LOGIN [auth_read];
ELSE
    ALTER USER [auth_read] WITH LOGIN = [auth_read];
GRANT CONNECT TO [auth_read];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'auth_reader' AND type = 'R')
    CREATE ROLE [auth_reader];
IF IS_ROLEMEMBER('auth_reader', 'auth_read') = 0 ALTER ROLE [auth_reader] ADD MEMBER [auth_read];

-- Estrategia de leitura, idempotente mesmo antes das migrations do Cadastro:
--   preferencia 1: schema de autenticacao dedicado (GRANT SELECT ON SCHEMA::auth)
--   fallback  academico documentado: db_datareader (leitura em todo o banco)
IF EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'auth')
    GRANT SELECT ON SCHEMA::[auth] TO [auth_reader];
ELSE IF IS_ROLEMEMBER('db_datareader', 'auth_reader') = 0
    ALTER ROLE [db_datareader] ADD MEMBER [auth_reader];
GO

-- =============================================================================
-- 4. OficinaEstoqueDb: usuarios, permissoes e isolamento.
-- =============================================================================
USE [OficinaEstoqueDb];
GO

DECLARE @managed TABLE (name sysname PRIMARY KEY);
INSERT INTO @managed (name) VALUES
    (N'cadastro_app'), (N'cadastro_migrator'), (N'auth_read'),
    (N'estoque_app'), (N'estoque_migrator'),
    (N'ordens_app'), (N'ordens_migrator');

DECLARE @allowed TABLE (name sysname PRIMARY KEY);
INSERT INTO @allowed (name) VALUES
    (N'estoque_app'), (N'estoque_migrator');

DECLARE @foreignUser sysname;
DECLARE @schemaName sysname;
DECLARE @stmt nvarchar(max);

WHILE EXISTS (
    SELECT 1
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed)
)
BEGIN
    SELECT TOP 1 @foreignUser = p.name
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed);

    WHILE EXISTS (
        SELECT 1 FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser
    )
    BEGIN
        SELECT TOP 1 @schemaName = s.name FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser;
        SET @stmt = N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(@schemaName) + N' TO dbo;';
        EXEC sp_executesql @stmt;
    END

    SET @stmt = N'DROP USER ' + QUOTENAME(@foreignUser) + N';';
    EXEC sp_executesql @stmt;
    PRINT 'Isolamento OficinaEstoqueDb: usuario indevido removido -> ' + @foreignUser;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'estoque_app' AND type = 'S')
    CREATE USER [estoque_app] FOR LOGIN [estoque_app];
ELSE
    ALTER USER [estoque_app] WITH LOGIN = [estoque_app];
IF IS_ROLEMEMBER('db_datareader', 'estoque_app') = 0 ALTER ROLE [db_datareader] ADD MEMBER [estoque_app];
IF IS_ROLEMEMBER('db_datawriter', 'estoque_app') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [estoque_app];
GRANT EXECUTE TO [estoque_app];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'estoque_migrator' AND type = 'S')
    CREATE USER [estoque_migrator] FOR LOGIN [estoque_migrator];
ELSE
    ALTER USER [estoque_migrator] WITH LOGIN = [estoque_migrator];
IF IS_ROLEMEMBER('db_ddladmin', 'estoque_migrator') = 0 ALTER ROLE [db_ddladmin] ADD MEMBER [estoque_migrator];
IF IS_ROLEMEMBER('db_datareader', 'estoque_migrator') = 0 ALTER ROLE [db_datareader] ADD MEMBER [estoque_migrator];
IF IS_ROLEMEMBER('db_datawriter', 'estoque_migrator') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [estoque_migrator];
GRANT EXECUTE TO [estoque_migrator];
GO

-- =============================================================================
-- 5. OficinaOrdensServicoDb: usuarios, permissoes e isolamento.
-- =============================================================================
USE [OficinaOrdensServicoDb];
GO

DECLARE @managed TABLE (name sysname PRIMARY KEY);
INSERT INTO @managed (name) VALUES
    (N'cadastro_app'), (N'cadastro_migrator'), (N'auth_read'),
    (N'estoque_app'), (N'estoque_migrator'),
    (N'ordens_app'), (N'ordens_migrator');

DECLARE @allowed TABLE (name sysname PRIMARY KEY);
INSERT INTO @allowed (name) VALUES
    (N'ordens_app'), (N'ordens_migrator');

DECLARE @foreignUser sysname;
DECLARE @schemaName sysname;
DECLARE @stmt nvarchar(max);

WHILE EXISTS (
    SELECT 1
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed)
)
BEGIN
    SELECT TOP 1 @foreignUser = p.name
    FROM sys.database_principals p
    JOIN @managed m ON m.name = p.name
    WHERE p.type = 'S'
      AND p.name NOT IN (SELECT name FROM @allowed);

    WHILE EXISTS (
        SELECT 1 FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser
    )
    BEGIN
        SELECT TOP 1 @schemaName = s.name FROM sys.schemas s
        JOIN sys.database_principals p ON s.principal_id = p.principal_id
        WHERE p.name = @foreignUser;
        SET @stmt = N'ALTER AUTHORIZATION ON SCHEMA::' + QUOTENAME(@schemaName) + N' TO dbo;';
        EXEC sp_executesql @stmt;
    END

    SET @stmt = N'DROP USER ' + QUOTENAME(@foreignUser) + N';';
    EXEC sp_executesql @stmt;
    PRINT 'Isolamento OficinaOrdensServicoDb: usuario indevido removido -> ' + @foreignUser;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ordens_app' AND type = 'S')
    CREATE USER [ordens_app] FOR LOGIN [ordens_app];
ELSE
    ALTER USER [ordens_app] WITH LOGIN = [ordens_app];
IF IS_ROLEMEMBER('db_datareader', 'ordens_app') = 0 ALTER ROLE [db_datareader] ADD MEMBER [ordens_app];
IF IS_ROLEMEMBER('db_datawriter', 'ordens_app') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [ordens_app];
GRANT EXECUTE TO [ordens_app];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'ordens_migrator' AND type = 'S')
    CREATE USER [ordens_migrator] FOR LOGIN [ordens_migrator];
ELSE
    ALTER USER [ordens_migrator] WITH LOGIN = [ordens_migrator];
IF IS_ROLEMEMBER('db_ddladmin', 'ordens_migrator') = 0 ALTER ROLE [db_ddladmin] ADD MEMBER [ordens_migrator];
IF IS_ROLEMEMBER('db_datareader', 'ordens_migrator') = 0 ALTER ROLE [db_datareader] ADD MEMBER [ordens_migrator];
IF IS_ROLEMEMBER('db_datawriter', 'ordens_migrator') = 0 ALTER ROLE [db_datawriter] ADD MEMBER [ordens_migrator];
GRANT EXECUTE TO [ordens_migrator];
GO

USE [master];
GO

PRINT 'bootstrap-databases: concluido com sucesso.';
GO
