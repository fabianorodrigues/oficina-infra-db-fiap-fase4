param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName,

    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile
)

$ErrorActionPreference = 'Stop'

$RequiredTags = [ordered]@{
    Project   = 'oficina'
    Purpose   = 'terraform-state'
    ManagedBy = 'github-actions'
}

function Invoke-AwsReadOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $blocked = @('put', 'create', 'delete', 'update')
    $joined = ($Arguments -join ' ').ToLowerInvariant()
    foreach ($word in $blocked) {
        if ($joined -match "(^|\s)$word-") {
            throw "Comando AWS de alteracao bloqueado no script read-only: aws $($Arguments -join ' ')"
        }
    }

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

function Add-Check {
    param(
        [System.Collections.Generic.List[object]]$Checks,
        [string]$Name,
        [string]$Expected,
        [string]$Actual,
        [bool]$Passed
    )

    $Checks.Add([pscustomobject]@{
        Validacao = $Name
        Esperado  = $Expected
        Atual     = $Actual
        Status    = if ($Passed) { 'OK' } else { 'FALHA' }
    }) | Out-Null
}

$checks = [System.Collections.Generic.List[object]]::new()

$identity = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output
Write-Host "Account ID: $($identity.Account)"
Write-Host "ARN: $($identity.Arn)"

$head = Invoke-AwsReadOnly -Arguments @('s3api', 'head-bucket', '--bucket', $BucketName) -AllowFailure
Add-Check -Checks $checks -Name 'Bucket existe' -Expected 'Acessivel' -Actual $(if ($head.ExitCode -eq 0) { 'Acessivel' } else { 'Inacessivel' }) -Passed ($head.ExitCode -eq 0)

if ($head.ExitCode -eq 0) {
    $location = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-location', '--bucket', $BucketName, '--output', 'json')).Output
    $actualRegion = if ($null -eq $location.LocationConstraint) { 'us-east-1' } else { [string]$location.LocationConstraint }
    Add-Check -Checks $checks -Name 'Regiao' -Expected $Region -Actual $actualRegion -Passed ($actualRegion -eq $Region)

    $versioning = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-versioning', '--bucket', $BucketName, '--output', 'json')).Output
    Add-Check -Checks $checks -Name 'Versionamento' -Expected 'Enabled' -Actual ([string]$versioning.Status) -Passed ([string]$versioning.Status -eq 'Enabled')

    $encryptionResult = Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-encryption', '--bucket', $BucketName, '--output', 'json') -AllowFailure
    $algorithm = 'Ausente'
    if ($encryptionResult.ExitCode -eq 0) {
        $encryption = ConvertFrom-JsonOutput -Text $encryptionResult.Output
        $algorithm = [string]$encryption.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm
    }
    Add-Check -Checks $checks -Name 'Criptografia padrao' -Expected 'AES256' -Actual $algorithm -Passed ($algorithm -eq 'AES256')

    $publicAccess = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('s3api', 'get-public-access-block', '--bucket', $BucketName, '--output', 'json')).Output
    $block = $publicAccess.PublicAccessBlockConfiguration
    $blockOk = $block.BlockPublicAcls -and $block.IgnorePublicAcls -and $block.BlockPublicPolicy -and $block.RestrictPublicBuckets
    Add-Check -Checks $checks -Name 'Public Access Block' -Expected 'Todos true' -Actual "BlockPublicAcls=$($block.BlockPublicAcls);IgnorePublicAcls=$($block.IgnorePublicAcls);BlockPublicPolicy=$($block.BlockPublicPolicy);RestrictPublicBuckets=$($block.RestrictPublicBuckets)" -Passed $blockOk

    $ownership = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-ownership-controls', '--bucket', $BucketName, '--output', 'json')).Output
    $objectOwnership = [string]$ownership.OwnershipControls.Rules[0].ObjectOwnership
    Add-Check -Checks $checks -Name 'Object Ownership' -Expected 'BucketOwnerEnforced' -Actual $objectOwnership -Passed ($objectOwnership -eq 'BucketOwnerEnforced')

    $tagging = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-tagging', '--bucket', $BucketName, '--output', 'json')).Output
    $actualTags = @{}
    foreach ($tag in $tagging.TagSet) {
        $actualTags[[string]$tag.Key] = [string]$tag.Value
    }
    foreach ($entry in $RequiredTags.GetEnumerator()) {
        $actualValue = if ($actualTags.ContainsKey($entry.Key)) { $actualTags[$entry.Key] } else { 'Ausente' }
        Add-Check -Checks $checks -Name "Tag $($entry.Key)" -Expected $entry.Value -Actual $actualValue -Passed ($actualValue -eq $entry.Value)
    }

    $policyResult = Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-policy', '--bucket', $BucketName, '--output', 'json') -AllowFailure
    $secureTransportOk = $false
    if ($policyResult.ExitCode -eq 0) {
        $policyWrapper = ConvertFrom-JsonOutput -Text $policyResult.Output
        $policy = [string]$policyWrapper.Policy | ConvertFrom-Json
        foreach ($statement in @($policy.Statement)) {
            $conditionValue = [string]$statement.Condition.Bool.'aws:SecureTransport'
            $resources = @($statement.Resource)
            if ($statement.Effect -eq 'Deny' -and $conditionValue -eq 'false' -and $resources -contains "arn:aws:s3:::$BucketName" -and $resources -contains "arn:aws:s3:::$BucketName/*") {
                $secureTransportOk = $true
            }
        }
    }
    Add-Check -Checks $checks -Name 'Politica SecureTransport' -Expected 'Deny aws:SecureTransport=false' -Actual $(if ($secureTransportOk) { 'Configurada' } else { 'Ausente ou divergente' }) -Passed $secureTransportOk

    $policyStatusResult = Invoke-AwsReadOnly -Arguments @('s3api', 'get-bucket-policy-status', '--bucket', $BucketName, '--output', 'json') -AllowFailure
    if ($policyStatusResult.ExitCode -eq 0) {
        $policyStatus = ConvertFrom-JsonOutput -Text $policyStatusResult.Output
        $isPublic = [bool]$policyStatus.PolicyStatus.IsPublic
        Add-Check -Checks $checks -Name 'Bucket publico' -Expected 'False' -Actual ([string]$isPublic) -Passed (-not $isPublic)
    }
    else {
        Add-Check -Checks $checks -Name 'Bucket publico' -Expected 'False' -Actual 'Policy status indisponivel' -Passed $false
    }
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    Write-Error "Validacao read-only falhou em $($failed.Count) requisito(s)."
    exit 1
}

Write-Host "Validacao read-only concluida com sucesso."
