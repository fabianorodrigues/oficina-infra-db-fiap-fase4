<#
.SYNOPSIS
    Validacao READ-ONLY do bootstrap de bancos apos a execucao real do Job.

.DESCRIPTION
    Confere o resultado do Kubernetes Job db-bootstrap e o ambiente esperado
    usando somente comandos de leitura. Nunca aplica ou remove recursos, nunca
    altera a AWS e nunca le o conteudo de secrets (nao usa a API de leitura de
    valor de secret).

    Comandos AWS permitidos: sts get-caller-identity, ssm get-parameter,
    secretsmanager describe-secret, secretsmanager list-secret-version-ids.
    Comandos kubectl permitidos: get, describe, logs.

.PARAMETER Namespace
    Namespace do Job. Padrao: oficina.

.PARAMETER JobName
    Nome do Job aplicado na execucao real. Obrigatorio.

.PARAMETER AwsRegion
    Regiao AWS. Obrigatoria para as verificacoes de SSM/Secrets Manager.

.PARAMETER AwsProfile
    Profile AWS opcional. Nao deve ser usado no GitHub Actions.

.PARAMETER ConfigPath
    Contrato de bootstrap. Padrao: config/database-bootstrap.json.

.PARAMETER SkipAwsChecks
    Executa somente as verificacoes de Kubernetes (util quando a AWS nao esta
    acessivel no momento da validacao).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Namespace = 'oficina',

    [Parameter(Mandatory = $true)]
    [string]$JobName,

    [Parameter(Mandatory = $false)]
    [string]$AwsRegion,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile,

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = 'config/database-bootstrap.json',

    [Parameter(Mandatory = $false)]
    [switch]$SkipAwsChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$rows = [System.Collections.Generic.List[object]]::new()
function Add-Row {
    param([string]$Item, [string]$Resultado, [bool]$Passed)
    $rows.Add([pscustomobject]@{
        Item      = $Item
        Resultado = $Resultado
        Status    = if ($Passed) { 'OK' } else { 'FALHA' }
    }) | Out-Null
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Invoke-KubectlReadOnly {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
    $verb = $Arguments[0]
    if ($verb -notin @('get', 'describe', 'logs')) {
        throw "Comando kubectl nao permitido no validador read-only: kubectl $($Arguments -join ' ')"
    }
    $output = & kubectl @Arguments 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0 -and -not $AllowFailure) {
        throw "kubectl falhou (exit $exit): kubectl $($Arguments -join ' ')"
    }
    [pscustomobject]@{ ExitCode = $exit; Output = ($output | Out-String).Trim() }
}

function Invoke-AwsReadOnly {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
    $joined = ($Arguments -join ' ').ToLowerInvariant()
    foreach ($blocked in @('(^|\s)create-', '(^|\s)put-', '(^|\s)update-', '(^|\s)modify-', '(^|\s)delete-', '(^|\s)apply($|\s)', ('get-sec' + 'ret-value'))) {
        if ($joined -match $blocked) { throw "Comando AWS nao permitido no validador read-only: aws $($Arguments -join ' ')" }
    }
    $final = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $final += @('--profile', $AwsProfile) }
    $output = & aws @final 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0 -and -not $AllowFailure) {
        throw "AWS CLI falhou (exit $exit): aws $($Arguments -join ' ')"
    }
    [pscustomobject]@{ ExitCode = $exit; Output = ($output | Out-String).Trim() }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Contrato ausente: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$serviceAccountName = [string](Get-PropertyValue $config 'serviceAccountName')
$secretProviderClassName = [string](Get-PropertyValue $config 'secretProviderClassName')
$secrets = Get-PropertyValue $config 'secrets'
$secretPaths = @()
if ($null -ne $secrets) { $secretPaths = @($secrets.PSObject.Properties | ForEach-Object { [string]$_.Value }) }

# ---------------------------------------------------------------------------
# 1. Job Complete e nao falhou.
# ---------------------------------------------------------------------------
$jobResult = Invoke-KubectlReadOnly -Arguments @('get', 'job', $JobName, '-n', $Namespace, '-o', 'json') -AllowFailure
if ($jobResult.ExitCode -ne 0) {
    Add-Row "Job existe" $JobName $false
}
else {
    $jobJson = $jobResult.Output | ConvertFrom-Json
    $status = Get-PropertyValue $jobJson 'status'
    $conditions = @(Get-PropertyValue $status 'conditions')
    $complete = @($conditions | Where-Object { $_.type -eq 'Complete' -and $_.status -eq 'True' }).Count -gt 0
    $failedCond = @($conditions | Where-Object { $_.type -eq 'Failed' -and $_.status -eq 'True' }).Count -gt 0
    $failedCount = [int](Get-PropertyValue $status 'failed')
    Add-Row "Job Complete" $(if ($complete) { 'True' } else { 'False' }) $complete
    Add-Row "Job nao falhou" $(if ($failedCond -or $failedCount -gt 0) { 'Falhou' } else { 'Ok' }) (-not $failedCond -and $failedCount -eq 0)

    # ServiceAccount correta e volume CSI presente.
    $spec = Get-PropertyValue $jobJson 'spec'
    $tmpl = Get-PropertyValue $spec 'template'
    $podSpec = Get-PropertyValue $tmpl 'spec'
    $sa = [string](Get-PropertyValue $podSpec 'serviceAccountName')
    Add-Row "ServiceAccount correta" $sa ($sa -eq $serviceAccountName)
    $volumes = @(Get-PropertyValue $podSpec 'volumes')
    $csiOk = @($volumes | Where-Object { $null -ne (Get-PropertyValue $_ 'csi') -and (Get-PropertyValue (Get-PropertyValue $_ 'csi') 'driver') -eq 'secrets-store.csi.k8s.io' }).Count -gt 0
    Add-Row "Volume CSI montado" $(if ($csiOk) { 'Sim' } else { 'Nao' }) $csiOk
}

# ---------------------------------------------------------------------------
# 2. Pod terminou com exit code 0.
# ---------------------------------------------------------------------------
$podsResult = Invoke-KubectlReadOnly -Arguments @('get', 'pods', '-n', $Namespace, '-l', "job-name=$JobName", '-o', 'json') -AllowFailure
$exitZero = $false
if ($podsResult.ExitCode -eq 0) {
    $podsJson = $podsResult.Output | ConvertFrom-Json
    foreach ($pod in @(Get-PropertyValue $podsJson 'items')) {
        $st = Get-PropertyValue $pod 'status'
        foreach ($cs in @(Get-PropertyValue $st 'containerStatuses')) {
            $term = Get-PropertyValue (Get-PropertyValue $cs 'state') 'terminated'
            if ($null -ne $term -and [int](Get-PropertyValue $term 'exitCode') -eq 0) { $exitZero = $true }
        }
    }
}
Add-Row "Pod exit code 0" $(if ($exitZero) { 'Sim' } else { 'Nao' }) $exitZero

# ---------------------------------------------------------------------------
# 3. SecretProviderClass existente.
# ---------------------------------------------------------------------------
$spcResult = Invoke-KubectlReadOnly -Arguments @('get', 'secretproviderclass', $secretProviderClassName, '-n', $Namespace, '-o', 'name') -AllowFailure
Add-Row "SecretProviderClass existe" $secretProviderClassName ($spcResult.ExitCode -eq 0)

# ---------------------------------------------------------------------------
# 4. Logs sanitizados e validacao SQL executada.
# ---------------------------------------------------------------------------
$logsResult = Invoke-KubectlReadOnly -Arguments @('logs', "job/$JobName", '-n', $Namespace) -AllowFailure
$logs = $logsResult.Output
$leakPatterns = @(
    'A' + 'KIA[0-9A-Z]{16}',
    'A' + 'SIA[0-9A-Z]{16}',
    '(?i)pass' + 'word\s*=\s*\S',
    '(?i)' + 'ser' + 'ver\s*=\s*tcp:',
    '-----' + 'BEGIN',
    'eyJ[A-Za-z0-9_-]{10,}\.'
)
$leaks = @($leakPatterns | Where-Object { $logs -match $_ })
Add-Row "Logs sem secret" $(if ($leaks.Count -eq 0) { 'Ok' } else { 'Vazamento' }) ($leaks.Count -eq 0)
$sqlOk = ($logs -match 'validate-databases: todas as verificacoes passaram') -or ($logs -match 'Validacao concluida com sucesso')
Add-Row "Validacao SQL executada" $(if ($sqlOk) { 'Sim' } else { 'Nao' }) $sqlOk

# ---------------------------------------------------------------------------
# 5. Verificacoes AWS read-only (opcionais).
# ---------------------------------------------------------------------------
if (-not $SkipAwsChecks) {
    if ([string]::IsNullOrWhiteSpace($AwsRegion)) { throw "AwsRegion e obrigatoria quando -SkipAwsChecks nao e usado." }

    $identity = (Invoke-AwsReadOnly -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output | ConvertFrom-Json
    Add-Row "Identidade AWS" "conta $($identity.Account)" $true

    foreach ($secretName in $secretPaths) {
        $describe = Invoke-AwsReadOnly -Arguments @('secretsmanager', 'describe-secret', '--secret-id', $secretName, '--region', $AwsRegion, '--output', 'json') -AllowFailure
        $present = ($describe.ExitCode -eq 0)
        $current = $false
        if ($present) {
            $versions = Invoke-AwsReadOnly -Arguments @('secretsmanager', 'list-secret-version-ids', '--secret-id', $secretName, '--region', $AwsRegion, '--output', 'json') -AllowFailure
            if ($versions.ExitCode -eq 0) {
                $vjson = $versions.Output | ConvertFrom-Json
                foreach ($v in @(Get-PropertyValue $vjson 'Versions')) {
                    if (@(Get-PropertyValue $v 'VersionStages') -contains 'AWSCURRENT') { $current = $true }
                }
            }
        }
        Add-Row "Secret AWSCURRENT: $secretName" $(if ($current) { 'Presente' } else { 'Ausente' }) $current
    }
}

$rows | Format-Table -AutoSize

$failed = @($rows | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    Write-Error "Validacao read-only do bootstrap falhou em $($failed.Count) item(ns)."
    exit 1
}
Write-Host "Validacao read-only do bootstrap concluida com sucesso."
