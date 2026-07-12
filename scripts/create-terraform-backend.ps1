param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RequiredTags = [ordered]@{
    Project   = 'oficina'
    Purpose   = 'terraform-state'
    ManagedBy = 'github-actions'
}

function Assert-ValidBucketName {
    param([string]$Name)

    $reservedPrefixes = @('xn--', 'sthree-', 'amzn-s3-demo-')
    $reservedSuffixes = @('-s3alias', '--ol-s3', '.mrap', '--x-s3', '--table-s3')

    if ($Name.Length -lt 3 -or $Name.Length -gt 63) { throw "BucketName deve ter entre 3 e 63 caracteres." }
    if ($Name -cne $Name.ToLowerInvariant()) { throw "BucketName nao pode conter letras maiusculas." }
    if ($Name -match '\s') { throw "BucketName nao pode conter espacos." }
    if ($Name -match '_') { throw "BucketName nao pode conter underscore." }
    if ($Name -match '<[^>]+>') { throw "BucketName nao pode conter placeholders." }
    if ($Name -notmatch '^[a-z0-9][a-z0-9.-]*[a-z0-9]$') { throw "BucketName deve iniciar e terminar com letra ou numero e usar apenas letras minusculas, numeros, ponto e hifen." }
    if ($Name -match '\.\.' -or $Name -match '\.-' -or $Name -match '-\.') { throw "BucketName nao pode conter sequencias invalidas com pontos e hifens." }
    if ($Name -match '^\d{1,3}(\.\d{1,3}){3}$') { throw "BucketName nao pode parecer endereco IP." }

    foreach ($prefix in $reservedPrefixes) {
        if ($Name.StartsWith($prefix, [System.StringComparison]::Ordinal)) { throw "BucketName usa prefixo reservado: $prefix" }
    }
    foreach ($suffix in $reservedSuffixes) {
        if ($Name.EndsWith($suffix, [System.StringComparison]::Ordinal)) { throw "BucketName usa sufixo reservado: $suffix" }
    }
}

function Invoke-AwsCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $finalArguments = @($Arguments)
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) {
        $finalArguments += @('--profile', $AwsProfile)
    }

    $output = & aws @finalArguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "AWS CLI falhou: aws $($Arguments -join ' ')"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

function ConvertFrom-JsonOutput {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return $Text | ConvertFrom-Json
}

function Get-BucketLocation {
    param([string]$Name)

    $result = Invoke-AwsCli -Arguments @('s3api', 'get-bucket-location', '--bucket', $Name, '--output', 'json')
    $json = ConvertFrom-JsonOutput -Text $result.Output
    if ($null -eq $json.LocationConstraint) { return 'us-east-1' }
    return [string]$json.LocationConstraint
}

function Write-JsonTempFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "terraform-backend-$([System.Guid]::NewGuid()).json")
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-CreateBucket {
    if ($Region -eq 'us-east-1') {
        Invoke-AwsCli -Arguments @('s3api', 'create-bucket', '--bucket', $BucketName, '--region', $Region) | Out-Null
        return
    }

    Invoke-AwsCli -Arguments @(
        's3api', 'create-bucket',
        '--bucket', $BucketName,
        '--region', $Region,
        '--create-bucket-configuration', "LocationConstraint=$Region"
    ) | Out-Null
}

function Set-Versioning {
    Invoke-AwsCli -Arguments @(
        's3api', 'put-bucket-versioning',
        '--bucket', $BucketName,
        '--versioning-configuration', 'Status=Enabled'
    ) | Out-Null
}

function Set-Encryption {
    $config = @{
        Rules = @(
            @{
                ApplyServerSideEncryptionByDefault = @{
                    SSEAlgorithm = 'AES256'
                }
                BucketKeyEnabled = $false
            }
        )
    }
    $path = Write-JsonTempFile -Value $config
    try {
        Invoke-AwsCli -Arguments @(
            's3api', 'put-bucket-encryption',
            '--bucket', $BucketName,
            '--server-side-encryption-configuration', "file://$path"
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Set-PublicAccessBlock {
    Invoke-AwsCli -Arguments @(
        's3api', 'put-public-access-block',
        '--bucket', $BucketName,
        '--public-access-block-configuration',
        'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
    ) | Out-Null
}

function Set-OwnershipControls {
    $controls = @{
        Rules = @(
            @{
                ObjectOwnership = 'BucketOwnerEnforced'
            }
        )
    }
    $path = Write-JsonTempFile -Value $controls
    try {
        Invoke-AwsCli -Arguments @(
            's3api', 'put-bucket-ownership-controls',
            '--bucket', $BucketName,
            '--ownership-controls', "file://$path"
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Set-RequiredTags {
    $tagSet = @()
    foreach ($entry in $RequiredTags.GetEnumerator()) {
        $tagSet += @{ Key = $entry.Key; Value = $entry.Value }
    }

    $tagging = @{ TagSet = $tagSet }
    $path = Write-JsonTempFile -Value $tagging
    try {
        Invoke-AwsCli -Arguments @(
            's3api', 'put-bucket-tagging',
            '--bucket', $BucketName,
            '--tagging', "file://$path"
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Set-SecureTransportPolicy {
    $policy = @{
        Version   = '2012-10-17'
        Statement = @(
            @{
                Sid       = 'DenyInsecureTransport'
                Effect    = 'Deny'
                Principal = '*'
                Action    = 's3:*'
                Resource  = @(
                    "arn:aws:s3:::$BucketName",
                    "arn:aws:s3:::$BucketName/*"
                )
                Condition = @{
                    Bool = @{
                        'aws:SecureTransport' = 'false'
                    }
                }
            }
        )
    }

    $path = Write-JsonTempFile -Value $policy
    try {
        Invoke-AwsCli -Arguments @(
            's3api', 'put-bucket-policy',
            '--bucket', $BucketName,
            '--policy', "file://$path"
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

Assert-ValidBucketName -Name $BucketName

if ($DryRun) {
    Write-Host "DryRun habilitado. Nenhuma chamada AWS sera executada."
    Write-Host "Bucket: $BucketName"
    Write-Host "Regiao: $Region"
    Write-Host "Validacao de nome do bucket: OK"
    if ($Region -eq 'us-east-1') {
        Write-Host "Criacao planejada: us-east-1 sem LocationConstraint"
    }
    else {
        Write-Host "Criacao planejada: regiao $Region com LocationConstraint=$Region"
    }
    Write-Host "Configuracoes planejadas: versionamento, SSE-S3 AES256, public access block, ownership, tags e politica SecureTransport."
    Write-Host "Status final: DRY_RUN_OK"
    exit 0
}

$identityResult = Invoke-AwsCli -Arguments @('sts', 'get-caller-identity', '--output', 'json')
$identity = ConvertFrom-JsonOutput -Text $identityResult.Output
$accountId = [string]$identity.Account
$arn = [string]$identity.Arn

Write-Host "Identidade AWS autenticada."
Write-Host "Account ID: $accountId"
Write-Host "ARN: $arn"

$head = Invoke-AwsCli -Arguments @('s3api', 'head-bucket', '--bucket', $BucketName) -AllowFailure
if ($head.ExitCode -ne 0) {
    Write-Host "Bucket nao encontrado ou inacessivel. Criando bucket solicitado."
    Invoke-CreateBucket
}
else {
    Write-Host "Bucket existente acessivel. Validando regiao e reconciliando configuracoes."
}

$actualRegion = Get-BucketLocation -Name $BucketName
if ($actualRegion -ne $Region) {
    throw "Bucket existe na regiao '$actualRegion', mas a regiao esperada e '$Region'."
}

Set-Versioning
Set-Encryption
Set-PublicAccessBlock
Set-OwnershipControls
Set-RequiredTags
Set-SecureTransportPolicy

Write-Host "Bucket: $BucketName"
Write-Host "Regiao: $Region"
Write-Host "Account ID: $accountId"
Write-Host "ARN do bucket: arn:aws:s3:::$BucketName"
Write-Host "Configuracoes aplicadas: versionamento Enabled, SSE-S3 AES256, Public Access Block total, BucketOwnerEnforced, tags obrigatorias, SecureTransport deny."
Write-Host "Status final: OK"
