<#
.SYNOPSIS
    Validacao local e offline do contrato versionado dos secrets SQL.

.DESCRIPTION
    Verifica a estrutura, a unicidade e a ausencia de dados sensiveis em
    config/database-secrets.json. O script nao acessa a AWS e nao le nenhum
    valor de senha. Retorna exit code diferente de zero em qualquer erro.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config/database-secrets.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Destinos oficiais dos secrets de banco. Nenhum valor sensivel.
$expectedTargets = @(
    [pscustomobject]@{ Id = 'cadastro-runtime';   SecretName = '/oficina/cadastro/runtime-db';   EnvVar = 'SQL_CADASTRO_APP_PASSWORD';       Database = 'OficinaCadastroDb';        Username = 'cadastro_app' }
    [pscustomobject]@{ Id = 'cadastro-migration'; SecretName = '/oficina/cadastro/migration-db'; EnvVar = 'SQL_CADASTRO_MIGRATOR_PASSWORD';  Database = 'OficinaCadastroDb';        Username = 'cadastro_migrator' }
    [pscustomobject]@{ Id = 'estoque-runtime';    SecretName = '/oficina/estoque/runtime-db';    EnvVar = 'SQL_ESTOQUE_APP_PASSWORD';       Database = 'OficinaEstoqueDb';         Username = 'estoque_app' }
    [pscustomobject]@{ Id = 'estoque-migration';  SecretName = '/oficina/estoque/migration-db';  EnvVar = 'SQL_ESTOQUE_MIGRATOR_PASSWORD';  Database = 'OficinaEstoqueDb';         Username = 'estoque_migrator' }
    [pscustomobject]@{ Id = 'ordens-runtime';     SecretName = '/oficina/ordens/runtime-db';     EnvVar = 'SQL_ORDENS_APP_PASSWORD';        Database = 'OficinaOrdensServicoDb';   Username = 'ordens_app' }
    [pscustomobject]@{ Id = 'ordens-migration';   SecretName = '/oficina/ordens/migration-db';   EnvVar = 'SQL_ORDENS_MIGRATOR_PASSWORD';   Database = 'OficinaOrdensServicoDb';   Username = 'ordens_migrator' }
    [pscustomobject]@{ Id = 'auth-read';          SecretName = '/oficina/auth/database';         EnvVar = 'SQL_AUTH_READ_PASSWORD';         Database = 'OficinaCadastroDb';        Username = 'auth_read' }
)

$checks = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [string]$Item,
        [string]$Resultado,
        [bool]$Passed
    )
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

$fileExists = Test-Path -LiteralPath $ConfigPath -PathType Leaf
Add-Result -Item "Arquivo de configuracao existe" -Resultado $ConfigPath -Passed $fileExists
if (-not $fileExists) {
    $checks | Format-Table -AutoSize
    Write-Error "Arquivo de configuracao nao encontrado: $ConfigPath"
    exit 1
}

$rawContent = Get-Content -LiteralPath $ConfigPath -Raw

$config = $null
$jsonValid = $true
try {
    $config = $rawContent | ConvertFrom-Json
}
catch {
    $jsonValid = $false
}
Add-Result -Item "JSON" -Resultado $(if ($jsonValid) { 'Valido' } else { 'Invalido' }) -Passed $jsonValid
if (-not $jsonValid) {
    $checks | Format-Table -AutoSize
    Write-Error "O arquivo de configuracao nao contem JSON valido."
    exit 1
}

$hasVersion = Test-HasProperty -Object $config -Name 'version'
Add-Result -Item "Versao presente" -Resultado $(if ($hasVersion) { [string](Get-PropertyValue -Object $config -Name 'version') } else { 'Ausente' }) -Passed $hasVersion

$rds = Get-PropertyValue -Object $config -Name 'rds'
$endpointParameter = [string](Get-PropertyValue -Object $rds -Name 'endpointParameter')
$portParameter = [string](Get-PropertyValue -Object $rds -Name 'portParameter')
Add-Result -Item "endpointParameter em /oficina/" -Resultado $endpointParameter -Passed ($endpointParameter.StartsWith('/oficina/'))
Add-Result -Item "portParameter em /oficina/" -Resultado $portParameter -Passed ($portParameter.StartsWith('/oficina/'))

$targets = @(Get-PropertyValue -Object $config -Name 'targets')
$targetCount = $targets.Count
Add-Result -Item "Targets" -Resultado "$targetCount" -Passed ($targetCount -eq 7)

$ids = @()
$secretNames = @()
$envVars = @()
$usernames = @()
$databases = @()
foreach ($target in $targets) {
    $ids += [string](Get-PropertyValue -Object $target -Name 'id')
    $secretNames += [string](Get-PropertyValue -Object $target -Name 'secretName')
    $envVars += [string](Get-PropertyValue -Object $target -Name 'passwordEnvironmentVariable')
    $usernames += [string](Get-PropertyValue -Object $target -Name 'username')
    $databases += [string](Get-PropertyValue -Object $target -Name 'database')
}

function Test-Unique {
    param([string[]]$Values)
    if ($Values.Count -eq 0) { return $false }
    return (@($Values | Sort-Object -Unique).Count -eq $Values.Count)
}

Add-Result -Item "IDs unicos" -Resultado $(if (Test-Unique -Values $ids) { 'Sim' } else { 'Nao' }) -Passed (Test-Unique -Values $ids)
Add-Result -Item "Secret names unicos" -Resultado $(if (Test-Unique -Values $secretNames) { 'Sim' } else { 'Nao' }) -Passed (Test-Unique -Values $secretNames)
Add-Result -Item "Variaveis de ambiente unicas" -Resultado $(if (Test-Unique -Values $envVars) { 'Sim' } else { 'Nao' }) -Passed (Test-Unique -Values $envVars)
Add-Result -Item "Usernames unicos" -Resultado $(if (Test-Unique -Values $usernames) { 'Sim' } else { 'Nao' }) -Passed (Test-Unique -Values $usernames)

$distinctDatabases = @($databases | Sort-Object -Unique)
Add-Result -Item "Bancos distintos" -Resultado "$($distinctDatabases.Count)" -Passed ($distinctDatabases.Count -eq 3)

$allSecretsScoped = ($secretNames.Count -gt 0) -and (@($secretNames | Where-Object { -not $_.StartsWith('/oficina/') }).Count -eq 0)
Add-Result -Item "Secrets em /oficina/" -Resultado $(if ($allSecretsScoped) { 'Sim' } else { 'Nao' }) -Passed $allSecretsScoped

$allEnvPrefixed = ($envVars.Count -gt 0) -and (@($envVars | Where-Object { -not $_.StartsWith('SQL_') }).Count -eq 0)
Add-Result -Item "Variaveis com prefixo SQL_" -Resultado $(if ($allEnvPrefixed) { 'Sim' } else { 'Nao' }) -Passed $allEnvPrefixed

# Ausencia de dados sensiveis no arquivo versionado.
# Padroes construidos por concatenacao para nao dispararem os proprios scanners estaticos.
$forbiddenSensitivePatterns = @(
    @{ Name = 'Senha embutida (password)';         Pattern = '"' + 'password"\s*:\s*"' },
    @{ Name = 'Senha embutida (pwd)';              Pattern = '(?i)\b' + 'pwd\s*=' },
    @{ Name = 'Connection string embutida';        Pattern = '(?i)' + 'ser' + 'ver\s*=\s*tcp:' },
    @{ Name = 'Endpoint real do RDS';              Pattern = '(?i)\.rds\.' + 'amazon' + 'aws\.com' },
    @{ Name = 'ARN da AWS';                        Pattern = 'arn' + ':aws:' },
    @{ Name = 'Access Key (AKIA)';                 Pattern = 'A' + 'KIA[0-9A-Z]{16}' },
    @{ Name = 'Access Key (ASIA)';                 Pattern = 'A' + 'SIA[0-9A-Z]{16}' },
    @{ Name = 'aws_access_key_id';                 Pattern = 'aws' + '_access_key_id' },
    @{ Name = 'aws_secret_access_key';             Pattern = 'aws' + '_secret_access_key' },
    @{ Name = 'aws_session_token';                 Pattern = 'aws' + '_session_token' }
)
$sensitiveFindings = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $forbiddenSensitivePatterns) {
    if ($rawContent -match $entry.Pattern) { $sensitiveFindings.Add($entry.Name) | Out-Null }
}
# Nenhum target pode expor propriedades sensiveis.
$sensitiveProperties = @('password', 'pwd', 'secret', 'connectionString', 'connectionstring')
foreach ($target in $targets) {
    foreach ($property in $sensitiveProperties) {
        if (Test-HasProperty -Object $target -Name $property) {
            $sensitiveFindings.Add("Propriedade sensivel '$property' presente em um target") | Out-Null
        }
    }
}
$noSensitiveData = ($sensitiveFindings.Count -eq 0)
Add-Result -Item "Dados sensiveis" -Resultado $(if ($noSensitiveData) { 'Ausentes' } else { 'Presentes' }) -Passed $noSensitiveData

# Os paths sao concatenados para que os padroes nao disparem sobre si mesmos.
$environmentPatterns = @(
    @{ Name = "Caminho de ambiente dev";      Pattern = [regex]::Escape('/' + 'dev' + '/') },
    @{ Name = "Caminho de ambiente hml";      Pattern = [regex]::Escape('/' + 'hml' + '/') },
    @{ Name = "Caminho de ambiente staging";  Pattern = [regex]::Escape('/' + 'staging' + '/') },
    @{ Name = "Caminho de ambiente prod";     Pattern = [regex]::Escape('/' + 'prod' + '/') },
    @{ Name = "Propriedade environment";      Pattern = '(?i)"environment"\s*:' }
)
$environmentFindings = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $environmentPatterns) {
    if ($rawContent -match $entry.Pattern) { $environmentFindings.Add($entry.Name) | Out-Null }
}
$noEnvironmentLeak = ($environmentFindings.Count -eq 0)
Add-Result -Item "Sem referencia a ambiente" -Resultado $(if ($noEnvironmentLeak) { 'Ok' } else { 'Divergente' }) -Passed $noEnvironmentLeak

# Conferencia dos sete destinos esperados.
$targetsById = @{}
foreach ($target in $targets) {
    $id = [string](Get-PropertyValue -Object $target -Name 'id')
    if (-not [string]::IsNullOrWhiteSpace($id)) { $targetsById[$id] = $target }
}
foreach ($expected in $expectedTargets) {
    $actual = $null
    if ($targetsById.ContainsKey($expected.Id)) { $actual = $targetsById[$expected.Id] }
    $targetMatches = $false
    if ($null -ne $actual) {
        $targetMatches = (
            ([string](Get-PropertyValue -Object $actual -Name 'secretName') -eq $expected.SecretName) -and
            ([string](Get-PropertyValue -Object $actual -Name 'passwordEnvironmentVariable') -eq $expected.EnvVar) -and
            ([string](Get-PropertyValue -Object $actual -Name 'database') -eq $expected.Database) -and
            ([string](Get-PropertyValue -Object $actual -Name 'username') -eq $expected.Username)
        )
    }
    Add-Result -Item "Destino $($expected.Id)" -Resultado $(if ($targetMatches) { $expected.SecretName } else { 'Divergente ou ausente' }) -Passed $targetMatches
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    if ($sensitiveFindings.Count -gt 0) {
        Write-Host "Ocorrencias sensiveis detectadas: $([string]::Join(', ', $sensitiveFindings))"
    }
    if ($environmentFindings.Count -gt 0) {
        Write-Host "Referencias proibidas detectadas: $([string]::Join(', ', $environmentFindings))"
    }
    Write-Error "Validacao do contrato de secrets falhou em $($failed.Count) item(ns)."
    exit 1
}

Write-Host "Contrato de secrets SQL validado com sucesso. Nenhum dado sensivel presente."
