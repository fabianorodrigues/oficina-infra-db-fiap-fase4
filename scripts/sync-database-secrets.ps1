<#
.SYNOPSIS
    Sincroniza as sete senhas SQL nos containers do AWS Secrets Manager.

.DESCRIPTION
    Le cada senha exclusivamente de environment variable, monta um payload JSON
    por destino usando um connection string builder seguro do .NET e grava o
    valor com aws secretsmanager put-secret-value em containers ja existentes.

    O script nunca imprime senhas, connection strings ou o payload. Endpoint e
    porta do RDS sao obtidos do SSM Parameter Store. Nenhum container e criado,
    atualizado ou removido: somente put-secret-value em containers existentes.

    Compativel com PowerShell 7 (Windows e Linux) e com Windows PowerShell 5.1.

.PARAMETER ConfigPath
    Caminho do contrato versionado. Padrao: config/database-secrets.json.

.PARAMETER Region
    Regiao AWS. Obrigatoria fora do modo DryRun.

.PARAMETER AwsProfile
    Profile AWS opcional. Nao deve ser usado no GitHub Actions.

.PARAMETER DryRun
    Constroi os payloads em memoria sem acessar a AWS. Exige ServerOverride e
    PortOverride e usa somente passwords sinteticas de environment variables.

.PARAMETER ServerOverride
    Endpoint sintetico. Aceito somente com -DryRun.

.PARAMETER PortOverride
    Porta sintetica. Aceito somente com -DryRun.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath = "config/database-secrets.json",

    [Parameter(Mandatory = $false)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$ServerOverride,

    [Parameter(Mandatory = $false)]
    [int]$PortOverride
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Deteccao de plataforma compativel com 5.1 e 7.
# ---------------------------------------------------------------------------
$isWindowsPlatform = $true
if (Test-Path -Path 'variable:IsWindows') { $isWindowsPlatform = [bool]$IsWindows }

$inGitHubActions = ($env:GITHUB_ACTIONS -eq 'true')

# ---------------------------------------------------------------------------
# Funcoes auxiliares.
# ---------------------------------------------------------------------------
function Add-GitHubMask {
    param([string]$Value)
    if ($inGitHubActions -and -not [string]::IsNullOrEmpty($Value)) {
        Write-Host "::add-mask::$Value"
    }
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

function Invoke-Aws {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    # Rede de seguranca: somente put-secret-value e permitido como alteracao.
    $joined = ($Arguments -join ' ')
    $isAllowedWrite = ($joined -match '^secretsmanager\s+put-secret-value(\s|$)')
    if (-not $isAllowedWrite) {
        foreach ($blocked in @('create-', 'update-', 'delete-', 'modify-', '(^|\s)put-')) {
            if ($joined -match $blocked) {
                throw "Comando de alteracao nao permitido neste script: aws $joined"
            }
        }
    }

    $finalArguments = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $finalArguments += @('--profile', $AwsProfile)
    }

    $output = & aws @finalArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "AWS CLI falhou (exit $exitCode): aws $joined"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function Get-ValidatedPassword {
    param([string]$EnvironmentVariable)

    $value = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
    $failureMessage = "A variavel $EnvironmentVariable esta ausente ou nao atende aos requisitos."

    if ([string]::IsNullOrEmpty($value)) { throw $failureMessage }
    if ($value.Length -lt 20) { throw $failureMessage }
    if ($value.Contains("`r")) { throw $failureMessage }
    if ($value.Contains("`n")) { throw $failureMessage }
    if ($value.Contains("`0")) { throw $failureMessage }

    # Mascara imediatamente antes de qualquer uso posterior.
    Add-GitHubMask -Value $value
    return $value
}

function New-SqlConnectionString {
    param(
        [string]$Server,
        [int]$Port,
        [string]$Database,
        [string]$Username,
        [string]$Password,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate,
        [int]$ConnectTimeoutSeconds
    )

    # DbConnectionStringBuilder faz o escaping seguro de ; = < > aspas e espacos.
    # Disponivel em .NET Core (pwsh 7 Linux/Windows) e no .NET Framework (5.1),
    # sem exigir pacote adicional no repositorio.
    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    $builder['Server'] = "tcp:$Server,$Port"
    $builder['Database'] = $Database
    $builder['User ID'] = $Username
    $builder['Password'] = $Password
    $builder['Encrypt'] = $Encrypt
    $builder['TrustServerCertificate'] = $TrustServerCertificate
    $builder['Connect Timeout'] = $ConnectTimeoutSeconds
    return $builder.ConnectionString
}

function New-SecretPayloadJson {
    param(
        [string]$Server,
        [int]$Port,
        [string]$Database,
        [string]$Username,
        [string]$Password,
        [bool]$Encrypt,
        [bool]$TrustServerCertificate,
        [int]$ConnectTimeoutSeconds,
        [string]$ConnectionString
    )

    $payload = [ordered]@{
        Server                   = $Server
        Port                     = $Port
        Database                 = $Database
        UserId                   = $Username
        Password                 = $Password
        Encrypt                  = $Encrypt
        TrustServerCertificate   = $TrustServerCertificate
        ConnectionTimeoutSeconds = $ConnectTimeoutSeconds
        ConnectionString         = $ConnectionString
    }
    return ($payload | ConvertTo-Json -Depth 5 -Compress)
}

function Get-IdempotencyToken {
    param(
        [string]$SecretName,
        [string]$PayloadJson
    )
    $tokenInput = "$SecretName`n$PayloadJson"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($tokenInput)
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return -join ($hash | ForEach-Object { $_.ToString('x2') })
}

# ---------------------------------------------------------------------------
# 1. Carregar e validar o contrato.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Contrato de secrets nao encontrado: $ConfigPath"
}

$configValidator = Join-Path -Path $PSScriptRoot -ChildPath 'validate-database-secrets-config.ps1'
if (Test-Path -LiteralPath $configValidator -PathType Leaf) {
    # O validador lanca erro terminante em qualquer divergencia, abortando a sincronizacao.
    & $configValidator -ConfigPath $ConfigPath | Out-Null
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$targets = @(Get-PropertyValue -Object $config -Name 'targets')
if ($targets.Count -ne 7) {
    throw "O contrato deve conter exatamente sete targets. Encontrados: $($targets.Count)."
}

$connection = Get-PropertyValue -Object $config -Name 'connection'
$encrypt = [bool](Get-PropertyValue -Object $connection -Name 'encrypt')
$trustServerCertificate = [bool](Get-PropertyValue -Object $connection -Name 'trustServerCertificate')
$connectTimeoutSeconds = [int](Get-PropertyValue -Object $connection -Name 'connectTimeoutSeconds')

$rds = Get-PropertyValue -Object $config -Name 'rds'
$endpointParameter = [string](Get-PropertyValue -Object $rds -Name 'endpointParameter')
$portParameter = [string](Get-PropertyValue -Object $rds -Name 'portParameter')

# ---------------------------------------------------------------------------
# Validacao de parametros mutuamente exclusivos.
# ---------------------------------------------------------------------------
$hasServerOverride = -not [string]::IsNullOrWhiteSpace($ServerOverride)
$hasPortOverride = $PSBoundParameters.ContainsKey('PortOverride')

if (-not $DryRun) {
    if ($hasServerOverride -or $hasPortOverride) {
        throw "ServerOverride e PortOverride sao aceitos somente com -DryRun."
    }
    if ([string]::IsNullOrWhiteSpace($Region)) {
        throw "O parametro -Region e obrigatorio fora do modo DryRun."
    }
}

# ---------------------------------------------------------------------------
# Resolucao de endpoint e porta.
# ---------------------------------------------------------------------------
$server = $null
$port = 0
$awsCallsExecuted = 0

if ($DryRun) {
    if (-not $hasServerOverride) { throw "-ServerOverride e obrigatorio no modo DryRun." }
    if (-not $hasPortOverride) { throw "-PortOverride e obrigatorio no modo DryRun." }
    $server = $ServerOverride
    $port = $PortOverride
}
else {
    # 2. Confirmar identidade AWS.
    $identity = (Invoke-Aws -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output | ConvertFrom-Json
    $awsCallsExecuted++
    Write-Host "Identidade AWS confirmada para a conta $($identity.Account)."

    # 3. Endpoint pelo SSM.
    $endpointJson = (Invoke-Aws -Arguments @('ssm', 'get-parameter', '--name', $endpointParameter, '--region', $Region, '--output', 'json')).Output | ConvertFrom-Json
    $awsCallsExecuted++
    $server = [string]$endpointJson.Parameter.Value

    # 4. Porta pelo SSM.
    $portJson = (Invoke-Aws -Arguments @('ssm', 'get-parameter', '--name', $portParameter, '--region', $Region, '--output', 'json')).Output | ConvertFrom-Json
    $awsCallsExecuted++
    $portRaw = [string]$portJson.Parameter.Value

    # 5. Endpoint nao vazio.
    if ([string]::IsNullOrWhiteSpace($server)) {
        throw "O endpoint do RDS retornado pelo SSM ($endpointParameter) esta vazio."
    }
    # 6. Porta numerica.
    $parsedPort = 0
    if (-not [int]::TryParse($portRaw, [ref]$parsedPort) -or $parsedPort -lt 1 -or $parsedPort -gt 65535) {
        throw "A porta do RDS retornada pelo SSM ($portParameter) nao e um numero valido."
    }
    $port = $parsedPort
}

# ---------------------------------------------------------------------------
# 7. Validar os sete containers antes de qualquer escrita (somente modo real).
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    foreach ($target in $targets) {
        $secretName = [string](Get-PropertyValue -Object $target -Name 'secretName')
        $describe = (Invoke-Aws -Arguments @('secretsmanager', 'describe-secret', '--secret-id', $secretName, '--region', $Region, '--output', 'json')).Output | ConvertFrom-Json
        $awsCallsExecuted++
        $deletedDate = Get-PropertyValue -Object $describe -Name 'DeletedDate'
        if ($null -ne $deletedDate) {
            throw "O container $secretName esta marcado para exclusao. Corrija na Infra DB antes de sincronizar."
        }
    }
}

# ---------------------------------------------------------------------------
# 8-16. Construcao dos payloads e sincronizacao.
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()
$payloadCount = 0

foreach ($target in $targets) {
    $secretName = [string](Get-PropertyValue -Object $target -Name 'secretName')
    $database = [string](Get-PropertyValue -Object $target -Name 'database')
    $username = [string](Get-PropertyValue -Object $target -Name 'username')
    $envVar = [string](Get-PropertyValue -Object $target -Name 'passwordEnvironmentVariable')

    # 8-9. Ler e mascarar a senha.
    $password = Get-ValidatedPassword -EnvironmentVariable $envVar

    # 10. Connection string com builder seguro.
    $connectionString = New-SqlConnectionString `
        -Server $server -Port $port -Database $database -Username $username `
        -Password $password -Encrypt $encrypt -TrustServerCertificate $trustServerCertificate `
        -ConnectTimeoutSeconds $connectTimeoutSeconds
    Add-GitHubMask -Value $connectionString

    # 11. Payload JSON em memoria.
    $payloadJson = New-SecretPayloadJson `
        -Server $server -Port $port -Database $database -Username $username `
        -Password $password -Encrypt $encrypt -TrustServerCertificate $trustServerCertificate `
        -ConnectTimeoutSeconds $connectTimeoutSeconds -ConnectionString $connectionString
    $payloadCount++

    # 12. Token idempotente derivado do payload completo.
    $clientRequestToken = Get-IdempotencyToken -SecretName $secretName -PayloadJson $payloadJson

    $versionId = ''
    $status = 'DryRun'

    if (-not $DryRun) {
        $tempDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("oficina-secret-" + [System.Guid]::NewGuid().ToString('N'))
        $tempFile = Join-Path -Path $tempDirectory -ChildPath 'payload.json'
        try {
            New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
            if (-not $isWindowsPlatform) {
                try { & chmod 700 $tempDirectory 2>$null } catch { }
            }

            # 3. Permissao restritiva no arquivo, quando suportado.
            [System.IO.File]::WriteAllText($tempFile, $payloadJson, [System.Text.UTF8Encoding]::new($false))
            if (-not $isWindowsPlatform) {
                try { & chmod 600 $tempFile 2>$null } catch { }
            }

            # 13. put-secret-value com --secret-string file:// e token idempotente.
            $putResult = (Invoke-Aws -Arguments @(
                'secretsmanager', 'put-secret-value',
                '--secret-id', $secretName,
                '--secret-string', "file://$tempFile",
                '--client-request-token', $clientRequestToken,
                '--region', $Region,
                '--output', 'json'
            )).Output | ConvertFrom-Json
            $awsCallsExecuted++

            # 15. Validar somente ARN, Name e VersionId (sem ler o conteudo).
            $returnedArn = [string](Get-PropertyValue -Object $putResult -Name 'ARN')
            $returnedName = [string](Get-PropertyValue -Object $putResult -Name 'Name')
            $versionId = [string](Get-PropertyValue -Object $putResult -Name 'VersionId')
            if ([string]::IsNullOrWhiteSpace($returnedArn) -or [string]::IsNullOrWhiteSpace($returnedName) -or [string]::IsNullOrWhiteSpace($versionId)) {
                throw "Resposta inesperada de put-secret-value para $secretName."
            }
            if ($returnedName -ne $secretName) {
                throw "Nome retornado ($returnedName) diverge do esperado ($secretName)."
            }
            $status = 'Sincronizado'
        }
        finally {
            # 5-6. Limpeza garantida do arquivo e do diretorio temporario.
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $tempDirectory) { Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # Nunca imprimir payload, senha ou connection string. Apenas metadados.
    $results.Add([pscustomobject]@{
        Secret    = $secretName
        Database  = $database
        Username  = $username
        VersionId = if ([string]::IsNullOrWhiteSpace($versionId)) { '-' } else { $versionId }
        Status    = $status
    }) | Out-Null

    # Liberar a referencia em texto plano da senha.
    $password = $null
    $connectionString = $null
    $payloadJson = $null
}

# ---------------------------------------------------------------------------
# 17. Resumo sanitizado.
# ---------------------------------------------------------------------------
$results | Format-Table -AutoSize

if ($DryRun) {
    Write-Host "DryRun aprovado."
    Write-Host "$payloadCount payloads construidos."
    Write-Host "0 chamadas AWS executadas."
    Write-Host "0 valores sensiveis exibidos."
}
else {
    Write-Host "Sincronizacao concluida. $payloadCount payloads processados em $awsCallsExecuted chamadas AWS."
    Write-Host "0 valores sensiveis exibidos."
}
