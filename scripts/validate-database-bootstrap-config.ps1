<#
.SYNOPSIS
    Validacao local e offline do contrato de bootstrap dos bancos SQL.

.DESCRIPTION
    Verifica a estrutura, a unicidade, os limites e a ausencia de dados
    sensiveis em config/database-bootstrap.json, e valida a consistencia com o
    contrato de sincronizacao config/database-secrets.json e com os metadados
    necessarios para os Jobs Kubernetes. Nao acessa a AWS e nao le nenhum valor
    de senha. Retorna exit code diferente de zero em qualquer erro.

.PARAMETER ConfigPath
    Caminho do contrato de bootstrap. Padrao: config/database-bootstrap.json.

.PARAMETER SecretsConfigPath
    Caminho do contrato de secrets. Padrao: config/database-secrets.json.

.PARAMETER DockerfilePath
    Dockerfile usado para publicar a imagem do bootstrap.

.PARAMETER AdminProvisionSqlPath
    Script SQL usado para criar ou atualizar o administrador inicial.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config/database-bootstrap.json",

    [Parameter(Mandatory = $false)]
    [string]$SecretsConfigPath = "config/database-secrets.json",

    [Parameter(Mandatory = $false)]
    [string]$DockerfilePath = "Dockerfile.bootstrap",

    [Parameter(Mandatory = $false)]
    [string]$AdminProvisionSqlPath = "scripts/provision-admin-user.sql"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Contrato canonico dos sete destinos de banco, sem valores sensiveis:
# (login, chave em secrets{}, path do secret, banco, papel)
$expected = @(
    [pscustomobject]@{ Login = 'cadastro_app';       SecretKey = 'cadastroRuntime';   Secret = '/oficina/cadastro/runtime-db';   Database = 'OficinaCadastroDb';        Role = 'runtime' }
    [pscustomobject]@{ Login = 'cadastro_migrator';  SecretKey = 'cadastroMigration'; Secret = '/oficina/cadastro/migration-db'; Database = 'OficinaCadastroDb';        Role = 'migrator' }
    [pscustomobject]@{ Login = 'estoque_app';        SecretKey = 'estoqueRuntime';    Secret = '/oficina/estoque/runtime-db';    Database = 'OficinaEstoqueDb';         Role = 'runtime' }
    [pscustomobject]@{ Login = 'estoque_migrator';   SecretKey = 'estoqueMigration';  Secret = '/oficina/estoque/migration-db';  Database = 'OficinaEstoqueDb';         Role = 'migrator' }
    [pscustomobject]@{ Login = 'ordens_app';         SecretKey = 'ordensRuntime';     Secret = '/oficina/ordens/runtime-db';     Database = 'OficinaOrdensServicoDb';   Role = 'runtime' }
    [pscustomobject]@{ Login = 'ordens_migrator';    SecretKey = 'ordensMigration';   Secret = '/oficina/ordens/migration-db';   Database = 'OficinaOrdensServicoDb';   Role = 'migrator' }
    [pscustomobject]@{ Login = 'auth_read';          SecretKey = 'authDatabase';      Secret = '/oficina/auth/database';         Database = 'OficinaCadastroDb';        Role = 'readonly' }
)

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Item, [string]$Resultado, [bool]$Passed)
    $checks.Add([pscustomobject]@{
        Item      = $Item
        Resultado = $Resultado
        Status    = if ($Passed) { 'OK' } else { 'FALHA' }
    }) | Out-Null
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if (-not (Test-HasProperty -Object $Object -Name $Name)) { return $null }
    return $Object.PSObject.Properties[$Name].Value
}

function Test-Unique {
    param([string[]]$Values)
    if ($Values.Count -eq 0) { return $false }
    return (@($Values | Sort-Object -Unique).Count -eq $Values.Count)
}

$fileExists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
Add-Result "Contrato de bootstrap existe" $ConfigPath $fileExists
if (-not $fileExists) {
    $checks | Format-Table -AutoSize
    Write-Error "Contrato de bootstrap nao encontrado: $ConfigPath"
    exit 1
}

$rawContent = Get-Content -LiteralPath $ConfigPath -Raw
$config = $null
$jsonValid = $true
try { $config = $rawContent | ConvertFrom-Json } catch { $jsonValid = $false }
Add-Result "JSON valido" $(if ($jsonValid) { 'Sim' } else { 'Nao' }) $jsonValid
if (-not $jsonValid) {
    $checks | Format-Table -AutoSize
    Write-Error "O contrato de bootstrap nao contem JSON valido."
    exit 1
}

$jobName = [string](Get-PropertyValue -Object $config -Name 'jobName')
$containerName = [string](Get-PropertyValue -Object $config -Name 'containerName')
Add-Result "Job name" $jobName ($jobName -eq 'oficina-db-bootstrap')
Add-Result "Container name" $containerName ($containerName -eq 'db-bootstrap')

# O runtime anterior nao pode sobreviver no contrato.
$hasRetiredBlocks = (Test-HasProperty -Object $config -Name 'ecs') -or (Test-HasProperty -Object $config -Name 'runTask') -or (Test-HasProperty -Object $config -Name 'taskFamily')
Add-Result "Sem blocos do runtime anterior" $(if ($hasRetiredBlocks) { 'Presentes' } else { 'Ok' }) (-not $hasRetiredBlocks)

$rds = Get-PropertyValue -Object $config -Name 'rds'
$k8s = Get-PropertyValue -Object $config -Name 'kubernetes'
$ssmParams = @(
    [string](Get-PropertyValue -Object $rds -Name 'endpointParameter'),
    [string](Get-PropertyValue -Object $rds -Name 'portParameter'),
    [string](Get-PropertyValue -Object $rds -Name 'masterSecretArnParameter'),
    [string](Get-PropertyValue -Object $k8s -Name 'namespaceParameter'),
    [string](Get-PropertyValue -Object $k8s -Name 'instanceIdParameter'),
    [string](Get-PropertyValue -Object $k8s -Name 'imageRepositoryParameter')
)
$allParamsScoped = (@($ssmParams | Where-Object { [string]::IsNullOrWhiteSpace($_) -or -not $_.StartsWith('/oficina/') }).Count -eq 0)
Add-Result "Parametros SSM em /oficina/" $(if ($allParamsScoped) { 'Sim' } else { 'Nao' }) $allParamsScoped

# Confere os paths publicados pelas stacks infra-db e platform.
Add-Result "endpointParameter" $ssmParams[0] ($ssmParams[0] -eq '/oficina/infra/rds/endpoint')
Add-Result "portParameter" $ssmParams[1] ($ssmParams[1] -eq '/oficina/infra/rds/port')
Add-Result "masterSecretArnParameter" $ssmParams[2] ($ssmParams[2] -eq '/oficina/infra/rds/master-secret-arn')
Add-Result "namespaceParameter" $ssmParams[3] ($ssmParams[3] -eq '/oficina/infra/k8s/namespace')
Add-Result "instanceIdParameter" $ssmParams[4] ($ssmParams[4] -eq '/oficina/infra/k8s/instance-id')
Add-Result "imageRepositoryParameter" $ssmParams[5] ($ssmParams[5] -eq '/oficina/infra/ecr/db-bootstrap')

# Os tres manifests precisam existir no repositorio: um caminho quebrado so
# apareceria no meio do deploy remoto.
$manifestKeys = @('bootstrapManifest', 'adminProvisionManifest', 'isolationManifest')
$manifestPaths = @()
foreach ($key in $manifestKeys) {
    $manifestPath = [string](Get-PropertyValue -Object $k8s -Name $key)
    $manifestPaths += $manifestPath
    $exists = (-not [string]::IsNullOrWhiteSpace($manifestPath)) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    Add-Result "Manifest $key" $manifestPath $exists
}
Add-Result "Manifests unicos" $(if (Test-Unique -Values $manifestPaths) { 'Sim' } else { 'Nao' }) (Test-Unique -Values $manifestPaths)

$cpuRequest = [string](Get-PropertyValue -Object $k8s -Name 'cpuRequest')
$memoryRequest = [string](Get-PropertyValue -Object $k8s -Name 'memoryRequest')
$cpuLimit = [string](Get-PropertyValue -Object $k8s -Name 'cpuLimit')
$memoryLimit = [string](Get-PropertyValue -Object $k8s -Name 'memoryLimit')
Add-Result "CPU request" $cpuRequest ($cpuRequest -match '^\d+m?$')
Add-Result "Memoria request" $memoryRequest ($memoryRequest -match '^\d+(Mi|Gi)$')
Add-Result "CPU limit" $cpuLimit ($cpuLimit -match '^\d+m?$')
Add-Result "Memoria limit" $memoryLimit ($memoryLimit -match '^\d+(Mi|Gi)$')

$secrets = Get-PropertyValue -Object $config -Name 'secrets'
$secretPaths = @()
if ($null -ne $secrets) { $secretPaths = @($secrets.PSObject.Properties | ForEach-Object { [string]$_.Value }) }
Add-Result "Sete secrets" "$($secretPaths.Count)" ($secretPaths.Count -eq 7)
Add-Result "Secrets unicos" $(if (Test-Unique -Values $secretPaths) { 'Sim' } else { 'Nao' }) (Test-Unique -Values $secretPaths)
$secretsScoped = ($secretPaths.Count -gt 0) -and (@($secretPaths | Where-Object { -not $_.StartsWith('/oficina/') }).Count -eq 0)
Add-Result "Secrets em /oficina/" $(if ($secretsScoped) { 'Sim' } else { 'Nao' }) $secretsScoped

# Confere cada chave->path esperada.
foreach ($e in $expected) {
    $actual = [string](Get-PropertyValue -Object $secrets -Name $e.SecretKey)
    Add-Result "secrets.$($e.SecretKey)" $(if ($actual -eq $e.Secret) { $actual } else { 'Divergente/ausente' }) ($actual -eq $e.Secret)
}

# Databases: tres, unicos, com logins corretos.
$databases = @(Get-PropertyValue -Object $config -Name 'databases')
Add-Result "Tres bancos" "$($databases.Count)" ($databases.Count -eq 3)
$dbNames = @($databases | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'name') })
Add-Result "Bancos unicos" $(if (Test-Unique -Values $dbNames) { 'Sim' } else { 'Nao' }) (Test-Unique -Values $dbNames)

$allLogins = [System.Collections.Generic.List[string]]::new()
foreach ($db in $databases) {
    $rl = [string](Get-PropertyValue -Object $db -Name 'runtimeLogin')
    $ml = [string](Get-PropertyValue -Object $db -Name 'migratorLogin')
    if ($rl) { $allLogins.Add($rl) | Out-Null }
    if ($ml) { $allLogins.Add($ml) | Out-Null }
    foreach ($ro in @(Get-PropertyValue -Object $db -Name 'readOnlyLogins')) {
        if ($ro) { $allLogins.Add([string]$ro) | Out-Null }
    }
}
Add-Result "Sete logins" "$($allLogins.Count)" ($allLogins.Count -eq 7)
Add-Result "Logins unicos" $(if (Test-Unique -Values $allLogins.ToArray()) { 'Sim' } else { 'Nao' }) (Test-Unique -Values $allLogins.ToArray())

# Confere papel de cada login esperado no banco correto.
$dbByName = @{}
foreach ($db in $databases) { $dbByName[[string](Get-PropertyValue -Object $db -Name 'name')] = $db }
foreach ($e in $expected) {
    $ok = $false
    if ($dbByName.ContainsKey($e.Database)) {
        $db = $dbByName[$e.Database]
        switch ($e.Role) {
            'runtime'  { $ok = ([string](Get-PropertyValue -Object $db -Name 'runtimeLogin') -eq $e.Login) }
            'migrator' { $ok = ([string](Get-PropertyValue -Object $db -Name 'migratorLogin') -eq $e.Login) }
            'readonly' { $ok = (@(Get-PropertyValue -Object $db -Name 'readOnlyLogins') -contains $e.Login) }
        }
    }
    Add-Result "Login $($e.Login) ($($e.Role)) em $($e.Database)" $(if ($ok) { 'OK' } else { 'Divergente' }) $ok
}

$job = Get-PropertyValue -Object $config -Name 'job'
$startedBy = [string](Get-PropertyValue -Object $job -Name 'startedBy')
$timeout = [int](Get-PropertyValue -Object $job -Name 'timeoutSeconds')
Add-Result "startedBy database-bootstrap" $startedBy ($startedBy -eq 'database-bootstrap')
Add-Result "timeoutSeconds > 0" "$timeout" ($timeout -gt 0)

# Ausencia de dados sensiveis e de referencias proibidas no arquivo.
# Padroes concatenados para nao dispararem sobre si mesmos.
$forbidden = @(
    @{ Name = 'Senha embutida';            Pattern = '(?i)"' + 'password"\s*:\s*"' },
    @{ Name = 'Connection string';         Pattern = '(?i)' + 'ser' + 'ver\s*=\s*tcp:' },
    @{ Name = 'Endpoint real do RDS';      Pattern = '(?i)\.rds\.' + 'amazon' + 'aws\.com' },
    @{ Name = 'ARN real';                  Pattern = 'arn' + ':aws:' },
    @{ Name = 'Access Key (AKIA)';         Pattern = 'A' + 'KIA[0-9A-Z]{16}' },
    @{ Name = 'Access Key (ASIA)';         Pattern = 'A' + 'SIA[0-9A-Z]{16}' },
    @{ Name = 'aws_access_key_id';         Pattern = 'aws' + '_access_key_id' },
    @{ Name = 'aws_secret_access_key';     Pattern = 'aws' + '_secret_access_key' },
    @{ Name = 'aws_session_token';         Pattern = 'aws' + '_session_token' }
)
$sensitiveFindings = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $forbidden) {
    if ($rawContent -match $entry.Pattern) { $sensitiveFindings.Add($entry.Name) | Out-Null }
}
Add-Result "Sem dados sensiveis" $(if ($sensitiveFindings.Count -eq 0) { 'Ok' } else { 'Presentes' }) ($sensitiveFindings.Count -eq 0)

$envPatterns = @(
    @{ Name = 'ambiente dev';     Pattern = [regex]::Escape('/' + 'dev' + '/') },
    @{ Name = 'ambiente hml';     Pattern = [regex]::Escape('/' + 'hml' + '/') },
    @{ Name = 'ambiente prod';    Pattern = [regex]::Escape('/' + 'prod' + '/') },
    @{ Name = 'sufixo -dev';      Pattern = '(?<![A-Za-z0-9])-' + 'dev' + '(?![A-Za-z0-9])' },
    @{ Name = 'sufixo -hml';      Pattern = '(?<![A-Za-z0-9])-' + 'hml' + '(?![A-Za-z0-9])' },
    @{ Name = 'sufixo -prod';     Pattern = '(?<![A-Za-z0-9])-' + 'prod' + '(?![A-Za-z0-9])' }
)
$envFindings = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $envPatterns) {
    if ($rawContent -match $entry.Pattern) { $envFindings.Add($entry.Name) | Out-Null }
}
Add-Result "Sem referencia a ambiente" $(if ($envFindings.Count -eq 0) { 'Ok' } else { 'Divergente' }) ($envFindings.Count -eq 0)

# Consistencia com config/database-secrets.json.
$secretsFileExists = Test-Path -LiteralPath $SecretsConfigPath -PathType Leaf
Add-Result "Contrato de secrets existe" $SecretsConfigPath $secretsFileExists
if ($secretsFileExists) {
    $secretsConfig = Get-Content -LiteralPath $SecretsConfigPath -Raw | ConvertFrom-Json
    $targets = @(Get-PropertyValue -Object $secretsConfig -Name 'targets')
    Add-Result "Secrets contract: 7 targets" "$($targets.Count)" ($targets.Count -eq 7)

    $targetBySecret = @{}
    foreach ($t in $targets) {
        $sn = [string](Get-PropertyValue -Object $t -Name 'secretName')
        if ($sn) { $targetBySecret[$sn] = $t }
    }

    foreach ($e in $expected) {
        $match = $false
        if ($targetBySecret.ContainsKey($e.Secret)) {
            $t = $targetBySecret[$e.Secret]
            $match = (
                ([string](Get-PropertyValue -Object $t -Name 'username') -eq $e.Login) -and
                ([string](Get-PropertyValue -Object $t -Name 'database') -eq $e.Database)
            )
        }
        Add-Result "Sync coerente: $($e.Login)" $(if ($match) { $e.Secret } else { 'Divergente/ausente' }) $match
    }

    # Nenhum target extra ou ausente em relacao ao bootstrap.
    $syncSecretNames = @($targets | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'secretName') } | Sort-Object)
    $bootstrapSecretNames = @($expected | ForEach-Object { $_.Secret } | Sort-Object)
    $sameSet = ($syncSecretNames.Count -eq $bootstrapSecretNames.Count) -and (@(Compare-Object $syncSecretNames $bootstrapSecretNames).Count -eq 0)
    Add-Result "Conjunto de secrets identico" $(if ($sameSet) { 'Sim' } else { 'Divergente' }) $sameSet

    # Parametros SSM de endpoint/porta coerentes entre os dois contratos.
    $syncRds = Get-PropertyValue -Object $secretsConfig -Name 'rds'
    $syncEndpoint = [string](Get-PropertyValue -Object $syncRds -Name 'endpointParameter')
    $syncPort = [string](Get-PropertyValue -Object $syncRds -Name 'portParameter')
    Add-Result "Endpoint param coerente" $syncEndpoint ($syncEndpoint -eq $ssmParams[0])
    Add-Result "Port param coerente" $syncPort ($syncPort -eq $ssmParams[1])
}

$dockerfileExists = Test-Path -LiteralPath $DockerfilePath -PathType Leaf
Add-Result "Dockerfile bootstrap existe" $DockerfilePath $dockerfileExists

$adminSqlExists = Test-Path -LiteralPath $AdminProvisionSqlPath -PathType Leaf
Add-Result "SQL admin provision existe" $AdminProvisionSqlPath $adminSqlExists
if ($adminSqlExists) {
    $adminSql = Get-Content -LiteralPath $AdminProvisionSqlPath -Raw
    $requiredSetOptions = @(
        [pscustomobject]@{ Name = 'ANSI_NULLS'; Value = 'ON' },
        [pscustomobject]@{ Name = 'ANSI_PADDING'; Value = 'ON' },
        [pscustomobject]@{ Name = 'ANSI_WARNINGS'; Value = 'ON' },
        [pscustomobject]@{ Name = 'ARITHABORT'; Value = 'ON' },
        [pscustomobject]@{ Name = 'CONCAT_NULL_YIELDS_NULL'; Value = 'ON' },
        [pscustomobject]@{ Name = 'QUOTED_IDENTIFIER'; Value = 'ON' },
        [pscustomobject]@{ Name = 'NUMERIC_ROUNDABORT'; Value = 'OFF' }
    )

    foreach ($option in $requiredSetOptions) {
        $pattern = "(?im)^\s*SET\s+$($option.Name)\s+$($option.Value)\s*;"
        $hasOption = $adminSql -match $pattern
        Add-Result "Admin SQL SET $($option.Name)" $option.Value $hasOption
    }
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    if ($sensitiveFindings.Count -gt 0) { Write-Host "Ocorrencias sensiveis: $([string]::Join(', ', $sensitiveFindings))" }
    if ($envFindings.Count -gt 0) { Write-Host "Referencias proibidas: $([string]::Join(', ', $envFindings))" }
    Write-Error "Validacao do contrato de bootstrap falhou em $($failed.Count) item(ns)."
    exit 1
}

Write-Host "Contrato de bootstrap validado com sucesso. Nenhum dado sensivel presente."
