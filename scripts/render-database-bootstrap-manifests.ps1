<#
.SYNOPSIS
    Renderiza os manifests Kubernetes do bootstrap de bancos a partir dos
    templates versionados e do contrato config/database-bootstrap.json.

.DESCRIPTION
    Gera, em um diretorio de saida (tipicamente temporario), tres manifests:
    ServiceAccount, SecretProviderClass e Job. Substitui placeholders por
    valores nao sensiveis fornecidos por parametro. Nunca le valores de secret,
    nunca grava senhas, connection strings ou credenciais AWS e nunca altera os
    templates originais. Funciona em PowerShell 7 sem acessar a AWS.

    O endpoint e a porta do RDS sao valores nao sensiveis fornecidos pela
    pipeline (lidos do SSM) porque a identidade db-bootstrap possui apenas
    permissao de leitura no Secrets Manager, nao no SSM. Por isso -RdsHost e
    -RdsPort sao entradas adicionais ao minimo descrito na especificacao.

.PARAMETER ConfigPath
    Contrato de bootstrap. Padrao: config/database-bootstrap.json.

.PARAMETER TemplateDirectory
    Diretorio dos templates. Padrao: deploy/bootstrap.

.PARAMETER OutputDirectory
    Diretorio de saida dos manifests renderizados. Obrigatorio.

.PARAMETER JobName
    Nome unico do Job (rotulo RFC1123, <= 63). Obrigatorio.

.PARAMETER MasterSecretArn
    ARN do master secret gerenciado pelo RDS. Aceita ARN sintetico no modo local.

.PARAMETER Region
    Regiao AWS (ex.: us-east-1). Obrigatoria.

.PARAMETER SqlToolsImage
    Imagem versionada com sqlcmd. Nunca :latest. Obrigatoria.

.PARAMETER WorkloadIdentityMode
    'pod-identity' (padrao) ou 'irsa'.

.PARAMETER IrsaRoleArn
    Role ARN para o modo IRSA. Ignorado em pod-identity.

.PARAMETER RdsHost
    Endpoint do RDS (nao sensivel). Sintetico no modo local.

.PARAMETER RdsPort
    Porta do RDS. Padrao 1433.

.PARAMETER SqlEncryptTrustServerCert
    'true'/'false'. Encriptacao sempre ligada; controla apenas a validacao do
    certificado do servidor. Padrao 'true', pois o RDS usa certificado gerenciado pela AWS.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config/database-bootstrap.json",

    [Parameter(Mandatory = $false)]
    [string]$TemplateDirectory = "deploy/bootstrap",

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $true)]
    [string]$MasterSecretArn,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $true)]
    [string]$SqlToolsImage,

    [Parameter(Mandatory = $false)]
    [ValidateSet('pod-identity', 'irsa')]
    [string]$WorkloadIdentityMode = 'pod-identity',

    [Parameter(Mandatory = $false)]
    [string]$IrsaRoleArn,

    [Parameter(Mandatory = $false)]
    [string]$RdsHost = 'synthetic-rds.internal.invalid',

    [Parameter(Mandatory = $false)]
    [string]$RdsPort = '1433',

    [Parameter(Mandatory = $false)]
    [ValidateSet('true', 'false')]
    [string]$SqlEncryptTrustServerCert = 'true'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-Rfc1123Label {
    param([string]$Value)
    return ($Value -match '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') -and ($Value.Length -ge 1) -and ($Value.Length -le 63)
}

function Test-ArnLike {
    param([string]$Value)
    return ($Value -match '^arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:\d{12}:') -or ($Value -match '(?i)synthetic')
}

# ---------------------------------------------------------------------------
# 1. Validacao do contrato (reaproveita o validador dedicado quando presente).
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Contrato de bootstrap nao encontrado: $ConfigPath"
}
$configValidator = Join-Path -Path $PSScriptRoot -ChildPath 'validate-database-bootstrap-config.ps1'
if (Test-Path -LiteralPath $configValidator -PathType Leaf) {
    & $configValidator -ConfigPath $ConfigPath | Out-Null
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$namespace = [string](Get-PropertyValue $config 'namespace')
$serviceAccountName = [string](Get-PropertyValue $config 'serviceAccountName')
$configMapName = [string](Get-PropertyValue $config 'configMapName')
$secretProviderClassName = [string](Get-PropertyValue $config 'secretProviderClassName')
$job = Get-PropertyValue $config 'job'
$backoffLimit = [int](Get-PropertyValue $job 'backoffLimit')
$activeDeadline = [int](Get-PropertyValue $job 'activeDeadlineSeconds')
$ttl = [int](Get-PropertyValue $job 'ttlSecondsAfterFinished')

# ---------------------------------------------------------------------------
# 2. Validacao das entradas (nomes Kubernetes, ARN, regiao, imagem).
# ---------------------------------------------------------------------------
if (-not (Test-Rfc1123Label $JobName)) { throw "JobName invalido (rotulo RFC1123, <= 63): $JobName" }
if (-not (Test-Rfc1123Label $serviceAccountName)) { throw "serviceAccountName invalido: $serviceAccountName" }
if ($namespace -ne 'oficina') { throw "Namespace inesperado: $namespace" }
if ([string]::IsNullOrWhiteSpace($MasterSecretArn) -or -not (Test-ArnLike $MasterSecretArn)) {
    throw "MasterSecretArn ausente ou com formato invalido."
}
if ($Region -notmatch '^[a-z]{2}-[a-z]+-\d$') { throw "Region invalida: $Region" }
if ([string]::IsNullOrWhiteSpace($SqlToolsImage) -or $SqlToolsImage -notmatch ':' -or $SqlToolsImage -match ':latest$') {
    throw "SqlToolsImage deve ter tag/digest explicito e nunca :latest."
}
if ($RdsPort -notmatch '^\d+$' -or [int]$RdsPort -lt 1 -or [int]$RdsPort -gt 65535) {
    throw "RdsPort invalido: $RdsPort"
}

$usePodIdentity = if ($WorkloadIdentityMode -eq 'pod-identity') { 'true' } else { 'false' }
if ($WorkloadIdentityMode -eq 'irsa') {
    if ([string]::IsNullOrWhiteSpace($IrsaRoleArn) -or -not (Test-ArnLike $IrsaRoleArn)) {
        throw "IrsaRoleArn obrigatorio e valido no modo irsa."
    }
}

# ---------------------------------------------------------------------------
# 3. Preparacao do diretorio de saida.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$spcTemplatePath = Join-Path $TemplateDirectory 'secret-provider-class.template.yaml'
$jobTemplatePath = Join-Path $TemplateDirectory 'job.template.yaml'
$saTemplatePath = Join-Path $TemplateDirectory 'service-account.yaml'
foreach ($p in @($spcTemplatePath, $jobTemplatePath, $saTemplatePath)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Template ausente: $p" }
}

function Set-Placeholders {
    param([string]$Content, [hashtable]$Tokens)
    foreach ($key in $Tokens.Keys) {
        $Content = $Content.Replace($key, [string]$Tokens[$key])
    }
    return $Content
}

# ---------------------------------------------------------------------------
# 4. ServiceAccount (annotation apenas no modo IRSA).
# ---------------------------------------------------------------------------
$saContent = Get-Content -LiteralPath $saTemplatePath -Raw
if ($WorkloadIdentityMode -eq 'irsa') {
    $annotation = "  namespace: oficina`n  annotations:`n    eks.amazonaws.com/role-arn: $IrsaRoleArn"
    $saContent = $saContent -replace '(?m)^\s*namespace:\s*oficina\s*$', $annotation
}
$saOut = Join-Path $OutputDirectory 'service-account.yaml'
Set-Content -LiteralPath $saOut -Value $saContent -Encoding UTF8 -NoNewline

# ---------------------------------------------------------------------------
# 5. SecretProviderClass.
# ---------------------------------------------------------------------------
$spcContent = Get-Content -LiteralPath $spcTemplatePath -Raw
$spcContent = Set-Placeholders -Content $spcContent -Tokens @{
    '__SECRET_PROVIDER_CLASS_NAME__' = $secretProviderClassName
    '__AWS_REGION__'                 = $Region
    '__USE_POD_IDENTITY__'           = $usePodIdentity
    '__MASTER_SECRET_ARN__'          = $MasterSecretArn
}
$spcOut = Join-Path $OutputDirectory 'secret-provider-class.yaml'
Set-Content -LiteralPath $spcOut -Value $spcContent -Encoding UTF8 -NoNewline

# ---------------------------------------------------------------------------
# 6. Job.
# ---------------------------------------------------------------------------
$jobContent = Get-Content -LiteralPath $jobTemplatePath -Raw
$jobContent = Set-Placeholders -Content $jobContent -Tokens @{
    '__JOB_NAME__'                      = $JobName
    '__SERVICE_ACCOUNT_NAME__'          = $serviceAccountName
    '__SQL_TOOLS_IMAGE__'               = $SqlToolsImage
    '__SECRET_PROVIDER_CLASS_NAME__'    = $secretProviderClassName
    '__CONFIG_MAP_NAME__'               = $configMapName
    '__RDS_HOST__'                      = $RdsHost
    '__RDS_PORT__'                      = $RdsPort
    '__SQL_ENCRYPT_TRUST_SERVER_CERT__' = $SqlEncryptTrustServerCert
    '__BACKOFF_LIMIT__'                 = $backoffLimit
    '__ACTIVE_DEADLINE_SECONDS__'       = $activeDeadline
    '__TTL_SECONDS_AFTER_FINISHED__'    = $ttl
}
$jobOut = Join-Path $OutputDirectory 'job.yaml'
Set-Content -LiteralPath $jobOut -Value $jobContent -Encoding UTF8 -NoNewline

# ---------------------------------------------------------------------------
# 7. Verificacao final: nenhum placeholder pendente; nenhum valor sensivel.
# ---------------------------------------------------------------------------
$rendered = @($saOut, $spcOut, $jobOut)
foreach ($file in $rendered) {
    $text = Get-Content -LiteralPath $file -Raw
    if ($text -match '__[A-Z0-9_]+__') {
        throw "Placeholder pendente em $file : $($Matches[0])"
    }
    foreach ($pattern in @('A' + 'KIA[0-9A-Z]{16}', 'A' + 'SIA[0-9A-Z]{16}', 'aws' + '_secret_access_key', 'aws' + '_session_token')) {
        if ($text -match $pattern) { throw "Valor sensivel detectado no manifesto renderizado: $file" }
    }
}

Write-Host "Manifests renderizados em: $OutputDirectory"
Write-Host " - service-account.yaml (modo: $WorkloadIdentityMode)"
Write-Host " - secret-provider-class.yaml (usePodIdentity: $usePodIdentity, regiao: $Region)"
Write-Host " - job.yaml (job: $JobName, imagem: $SqlToolsImage)"
Write-Host "Endpoint/porta nao sensiveis aplicados: ${RdsHost}:${RdsPort}"
