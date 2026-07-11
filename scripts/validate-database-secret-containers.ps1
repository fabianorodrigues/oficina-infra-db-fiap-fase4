<#
.SYNOPSIS
    Validacao read-only dos containers de secrets SQL no AWS Secrets Manager.

.DESCRIPTION
    Para cada destino do contrato versionado confirma a existencia do container,
    o nome esperado, o ARN retornado e a ausencia de marcacao para exclusao.
    Quando -RequireCurrentVersion for verdadeiro, exige que exista uma versao
    com stage AWSCURRENT (usado apos a sincronizacao).

    O script e estritamente read-only. Nunca le o conteudo dos secrets
    (nem senha nem connection string) e nao usa a API de leitura de valor.

.PARAMETER ConfigPath
    Caminho do contrato versionado. Padrao: config/database-secrets.json.

.PARAMETER Region
    Regiao AWS.

.PARAMETER AwsProfile
    Profile AWS opcional. Nao deve ser usado no GitHub Actions.

.PARAMETER RequireCurrentVersion
    Quando $true, exige stage AWSCURRENT em cada container (pos-sincronizacao).

.PARAMETER ExpectedTagKeys
    Chaves de tag obrigatorias, quando definidas pela Infra DB. Vazio ignora tags.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config/database-secrets.json",

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile,

    [Parameter(Mandatory = $false)]
    [bool]$RequireCurrentVersion = $false,

    [Parameter(Mandatory = $false)]
    [string[]]$ExpectedTagKeys = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Invoke-AwsReadOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $joined = ($Arguments -join ' ').ToLowerInvariant()
    # Bloqueia qualquer alteracao e tambem a leitura de conteudo sensivel.
    $blockedPatterns = @(
        '(^|\s)create-',
        '(^|\s)put-',
        '(^|\s)update-',
        '(^|\s)modify-',
        '(^|\s)delete-',
        '(^|\s)apply($|\s)',
        ('get-sec' + 'ret-value')
    )
    foreach ($pattern in $blockedPatterns) {
        if ($joined -match $pattern) {
            throw "Comando nao permitido no script read-only: aws $($Arguments -join ' ')"
        }
    }

    $finalArguments = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $finalArguments += @('--profile', $AwsProfile)
    }

    $output = & aws @finalArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "AWS CLI falhou (exit $exitCode): aws $($Arguments -join ' ')"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Contrato de secrets nao encontrado: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$targets = @(Get-PropertyValue -Object $config -Name 'targets')
if ($targets.Count -ne 7) {
    throw "O contrato deve conter exatamente sete targets. Encontrados: $($targets.Count)."
}

$rows = [System.Collections.Generic.List[object]]::new()

# Confirma identidade sem ler nenhum conteudo de secret.
$identity = (Invoke-AwsReadOnly -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output | ConvertFrom-Json
Write-Host "Identidade AWS confirmada para a conta $($identity.Account)."

foreach ($target in $targets) {
    $secretName = [string](Get-PropertyValue -Object $target -Name 'secretName')

    $containerOk = $false
    $currentOk = $false
    $problems = [System.Collections.Generic.List[string]]::new()

    $describeResult = Invoke-AwsReadOnly -Arguments @(
        'secretsmanager', 'describe-secret',
        '--secret-id', $secretName,
        '--region', $Region,
        '--output', 'json'
    ) -AllowFailure

    if ($describeResult.ExitCode -ne 0) {
        $problems.Add('container ausente') | Out-Null
    }
    else {
        $describe = $describeResult.Output | ConvertFrom-Json
        $returnedName = [string](Get-PropertyValue -Object $describe -Name 'Name')
        $returnedArn = [string](Get-PropertyValue -Object $describe -Name 'ARN')
        $deletedDate = Get-PropertyValue -Object $describe -Name 'DeletedDate'

        if ($returnedName -ne $secretName) { $problems.Add('nome divergente') | Out-Null }
        if ([string]::IsNullOrWhiteSpace($returnedArn)) { $problems.Add('ARN ausente') | Out-Null }
        if ($null -ne $deletedDate) { $problems.Add('marcado para exclusao') | Out-Null }

        # Tags esperadas, apenas quando a Infra DB as define.
        if ($ExpectedTagKeys.Count -gt 0) {
            $tagList = @(Get-PropertyValue -Object $describe -Name 'Tags')
            $presentKeys = @($tagList | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'Key') })
            foreach ($requiredKey in $ExpectedTagKeys) {
                if ($presentKeys -notcontains $requiredKey) { $problems.Add("tag ausente: $requiredKey") | Out-Null }
            }
        }

        $containerOk = ($problems.Count -eq 0)

        # Versoes: procura stage AWSCURRENT sem ler o conteudo.
        $versionsResult = Invoke-AwsReadOnly -Arguments @(
            'secretsmanager', 'list-secret-version-ids',
            '--secret-id', $secretName,
            '--region', $Region,
            '--output', 'json'
        ) -AllowFailure

        if ($versionsResult.ExitCode -eq 0) {
            $versions = $versionsResult.Output | ConvertFrom-Json
            $versionList = @(Get-PropertyValue -Object $versions -Name 'Versions')
            foreach ($version in $versionList) {
                $stages = @(Get-PropertyValue -Object $version -Name 'VersionStages')
                if ($stages -contains 'AWSCURRENT') { $currentOk = $true }
            }
        }
    }

    if ($RequireCurrentVersion -and -not $currentOk) {
        $problems.Add('sem AWSCURRENT') | Out-Null
    }

    $rowPassed = ($problems.Count -eq 0)
    $currentDisplay = if ($currentOk) { 'Presente' } elseif ($RequireCurrentVersion) { 'Ausente' } else { 'N/A' }

    $rows.Add([pscustomobject]@{
        Secret     = $secretName
        Container  = if ($containerOk) { 'Presente' } else { 'Ausente/Invalido' }
        AWSCURRENT = $currentDisplay
        Status     = if ($rowPassed) { 'OK' } else { 'FALHA' }
    }) | Out-Null
}

$rows | Format-Table -AutoSize

$failed = @($rows | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    Write-Error "Validacao dos containers de secrets falhou em $($failed.Count) destino(s)."
    exit 1
}

$phase = if ($RequireCurrentVersion) { 'pos-sincronizacao' } else { 'pre-sincronizacao' }
Write-Host "Validacao read-only dos containers ($phase) concluida com sucesso."
