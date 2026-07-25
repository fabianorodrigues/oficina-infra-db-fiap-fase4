-- =============================================================================
-- provision-admin-user.sql
-- -----------------------------------------------------------------------------
-- Provisiona EXCLUSIVAMENTE o usuario Admin inicial da Oficina em
-- OficinaCadastroDb.dbo.Funcionarios, a partir do CPF e da senha guardados nos
-- GitHub Secrets ADMIN_INICIAL_CPF e ADMIN_INICIAL_PASSWORD.
-- =============================================================================

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- -----------------------------------------------------------------------------
-- 0. Guarda: o banco de cadastro precisa existir (bootstrap ja executado).
-- -----------------------------------------------------------------------------
IF DB_ID(N'OficinaCadastroDb') IS NULL
BEGIN
    RAISERROR('provision-admin-user: OficinaCadastroDb nao existe. Rode o bootstrap dos bancos antes.', 16, 1);
    RETURN;
END
GO

USE [OficinaCadastroDb];
GO

-- -----------------------------------------------------------------------------
-- 1. Guarda: a tabela funcional precisa existir (migrations do Cadastro aplicadas).
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.Funcionarios', N'U') IS NULL
BEGIN
    RAISERROR('provision-admin-user: dbo.Funcionarios nao existe. Aplique as migrations do Cadastro primeiro.', 16, 1);
    RETURN;
END
GO

-- -----------------------------------------------------------------------------
-- 2. Validacao dos valores injetados e provisionamento do unico registro alvo.
-- -----------------------------------------------------------------------------
DECLARE @Cpf         nvarchar(11)  = N'$(ADMIN_CPF_SQL)';
DECLARE @Nome        nvarchar(150) = N'$(ADMIN_NOME_SQL)';
DECLARE @SenhaHash   nvarchar(500) = N'$(ADMIN_SENHA_HASH_SQL)';
DECLARE @PerfilAdmin int = 2;  -- PerfilUsuarioInterno.Admin
DECLARE @Linhas      int = 0;

IF LEN(@Cpf) <> 11 OR @Cpf LIKE N'%[^0-9]%'
BEGIN
    RAISERROR('provision-admin-user: CPF do admin inicial invalido (esperado 11 digitos).', 16, 1);
    RETURN;
END

IF LEN(@Nome) = 0
BEGIN
    RAISERROR('provision-admin-user: nome do admin inicial vazio.', 16, 1);
    RETURN;
END

-- Formato do hash: PBKDF2-SHA256$<iteracoes>$<salt>$<hash>, iteracoes >= 100000.
IF LEFT(@SenhaHash, 14) <> N'PBKDF2-SHA256$'
BEGIN
    RAISERROR('provision-admin-user: hash de senha nao usa o algoritmo PBKDF2-SHA256 esperado.', 16, 1);
    RETURN;
END

DECLARE @Resto nvarchar(500) = SUBSTRING(@SenhaHash, 15, 500);
DECLARE @PosSeparador int = CHARINDEX(N'$', @Resto);

IF @PosSeparador < 2
BEGIN
    RAISERROR('provision-admin-user: hash de senha malformado, contagem de iteracoes ausente.', 16, 1);
    RETURN;
END

DECLARE @IteracoesTexto nvarchar(20) = LEFT(@Resto, @PosSeparador - 1);

IF LEN(@IteracoesTexto) > 9 OR @IteracoesTexto LIKE N'%[^0-9]%'
BEGIN
    RAISERROR('provision-admin-user: contagem de iteracoes do hash nao e numerica.', 16, 1);
    RETURN;
END

IF CAST(@IteracoesTexto AS int) < 100000
BEGIN
    RAISERROR('provision-admin-user: hash de senha com menos de 100000 iteracoes e recusado pelo verificador.', 16, 1);
    RETURN;
END

BEGIN TRANSACTION;

IF EXISTS (SELECT 1 FROM dbo.Funcionarios WHERE Cpf = @Cpf)
BEGIN
    UPDATE dbo.Funcionarios
       SET Nome      = @Nome,
           SenhaHash = @SenhaHash,
           Perfil    = @PerfilAdmin,
           Ativo     = 1
     WHERE Cpf = @Cpf;

    SET @Linhas = @@ROWCOUNT;
    PRINT 'provision-admin-user: admin inicial ja existia e foi atualizado.';
END
ELSE
BEGIN
    INSERT INTO dbo.Funcionarios (Id, Nome, Cpf, SenhaHash, Perfil, Ativo, DataCriacao)
    VALUES (NEWID(), @Nome, @Cpf, @SenhaHash, @PerfilAdmin, 1, SYSDATETIMEOFFSET());

    SET @Linhas = @@ROWCOUNT;
    PRINT 'provision-admin-user: admin inicial criado.';
END

IF @Linhas <> 1
BEGIN
    ROLLBACK TRANSACTION;
    RAISERROR('provision-admin-user: operacao afetou um numero inesperado de linhas. Nada foi gravado.', 16, 1);
    RETURN;
END

COMMIT TRANSACTION;
GO

-- -----------------------------------------------------------------------------
-- 3. Verificacao read-only: exatamente um Admin ativo com o CPF alvo.
-- -----------------------------------------------------------------------------
DECLARE @CpfConferencia nvarchar(11) = N'$(ADMIN_CPF_SQL)';
DECLARE @Confirmados int;

SELECT @Confirmados = COUNT(*)
  FROM dbo.Funcionarios
 WHERE Cpf = @CpfConferencia AND Perfil = 2 AND Ativo = 1;

IF @Confirmados <> 1
BEGIN
    RAISERROR('provision-admin-user: verificacao final falhou, admin inicial nao esta ativo.', 16, 1);
    RETURN;
END

PRINT 'provision-admin-user: verificacao concluida, admin inicial ativo.';
GO
