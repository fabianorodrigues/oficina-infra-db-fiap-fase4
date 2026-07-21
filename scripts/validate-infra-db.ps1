param(
    [Parameter(Mandatory = $true)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$VpcName = "oficina",

    [Parameter(Mandatory = $false)]
    [string]$VpcId,

    [Parameter(Mandatory = $false)]
    [string]$RdsIdentifier = "oficina-sqlserver",

    [Parameter(Mandatory = $false)]
    [string]$ExpectedVpcCidr = "10.40.0.0/16",

    [Parameter(Mandatory = $false)]
    [string]$RdsAdminCidr,

    [Parameter(Mandatory = $false)]
    [string[]]$ExpectedSecretNames = @(
        "/oficina/cadastro/runtime-db",
        "/oficina/cadastro/migration-db",
        "/oficina/estoque/runtime-db",
        "/oficina/estoque/migration-db",
        "/oficina/ordens/runtime-db",
        "/oficina/ordens/migration-db",
        "/oficina/auth/database"
    ),

    [Parameter(Mandatory = $false)]
    [string[]]$ExpectedSsmParameterNames = @(
        "/oficina/infra/vpc/id",
        "/oficina/infra/subnets/public/1",
        "/oficina/infra/subnets/public/2",
        "/oficina/infra/subnets/private/1",
        "/oficina/infra/subnets/private/2",
        "/oficina/infra/rds/identifier",
        "/oficina/infra/rds/endpoint",
        "/oficina/infra/rds/port",
        "/oficina/infra/rds/security-group-id",
        "/oficina/infra/rds/master-secret-arn"
    ),

    [Parameter(Mandatory = $false)]
    [string]$AwsProfile
)

$ErrorActionPreference = 'Stop'

function Invoke-AwsReadOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowFailure
    )

    $joined = ($Arguments -join ' ').ToLowerInvariant()
    $blockedPatterns = @(
        '(^|\s)create-',
        '(^|\s)put-',
        '(^|\s)update-',
        '(^|\s)modify-',
        '(^|\s)delete-',
        '(^|\s)apply($|\s)'
    )
    foreach ($pattern in $blockedPatterns) {
        if ($joined -match $pattern) {
            throw "Comando de alteracao bloqueado no script read-only: aws $($Arguments -join ' ')"
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

function Get-TagValue {
    param(
        [object[]]$Tags,
        [string]$Key
    )
    $tag = @($Tags | Where-Object { $_.Key -eq $Key } | Select-Object -First 1)
    if ($tag.Count -eq 0) { return $null }
    return [string]$tag[0].Value
}

$checks = [System.Collections.Generic.List[object]]::new()

$identity = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @('sts', 'get-caller-identity', '--output', 'json')).Output
Write-Host "AWS identity validated for account $($identity.Account)."

if ([string]::IsNullOrWhiteSpace($VpcId)) {
    $vpcs = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
        'ec2', 'describe-vpcs',
        '--region', $Region,
        '--filters', "Name=tag:Name,Values=$VpcName",
        '--output', 'json'
    )).Output
    $vpc = @($vpcs.Vpcs | Select-Object -First 1)
}
else {
    $vpcs = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
        'ec2', 'describe-vpcs',
        '--region', $Region,
        '--vpc-ids', $VpcId,
        '--output', 'json'
    )).Output
    $vpc = @($vpcs.Vpcs | Select-Object -First 1)
}

Add-Check -Checks $checks -Name 'VPC existe' -Expected '1 VPC' -Actual "$(@($vpc).Count)" -Passed (@($vpc).Count -eq 1)
if (@($vpc).Count -eq 1) {
    $VpcId = [string]$vpc[0].VpcId
    Add-Check -Checks $checks -Name 'CIDR da VPC' -Expected $ExpectedVpcCidr -Actual ([string]$vpc[0].CidrBlock) -Passed ([string]$vpc[0].CidrBlock -eq $ExpectedVpcCidr)
}

$subnetsJson = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'ec2', 'describe-subnets',
    '--region', $Region,
    '--filters', "Name=vpc-id,Values=$VpcId",
    '--output', 'json'
)).Output
$subnets = @($subnetsJson.Subnets)
$publicSubnets = @($subnets | Where-Object { (Get-TagValue -Tags $_.Tags -Key 'Type') -eq 'public' })
$privateSubnets = @($subnets | Where-Object { (Get-TagValue -Tags $_.Tags -Key 'Type') -eq 'private' })
$azCount = @($subnets.AvailabilityZone | Sort-Object -Unique).Count
Add-Check -Checks $checks -Name 'Subnets publicas' -Expected '2' -Actual "$($publicSubnets.Count)" -Passed ($publicSubnets.Count -eq 2)
Add-Check -Checks $checks -Name 'Subnets privadas' -Expected '2' -Actual "$($privateSubnets.Count)" -Passed ($privateSubnets.Count -eq 2)
Add-Check -Checks $checks -Name 'Distribuicao em AZs' -Expected '2 AZs' -Actual "$azCount AZs" -Passed ($azCount -eq 2)

$igws = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'ec2', 'describe-internet-gateways',
    '--region', $Region,
    '--filters', "Name=attachment.vpc-id,Values=$VpcId",
    '--output', 'json'
)).Output
Add-Check -Checks $checks -Name 'Internet Gateway associado' -Expected '1' -Actual "$(@($igws.InternetGateways).Count)" -Passed (@($igws.InternetGateways).Count -eq 1)

$natGateways = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'ec2', 'describe-nat-gateways',
    '--region', $Region,
    '--filter', "Name=vpc-id,Values=$VpcId",
    '--output', 'json'
)).Output
$availableNat = @($natGateways.NatGateways | Where-Object { $_.State -eq 'available' })
Add-Check -Checks $checks -Name 'NAT Gateway disponivel' -Expected '1 available' -Actual "$($availableNat.Count) available" -Passed ($availableNat.Count -eq 1)

$routeTables = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'ec2', 'describe-route-tables',
    '--region', $Region,
    '--filters', "Name=vpc-id,Values=$VpcId",
    '--output', 'json'
)).Output
$publicSubnetIds = @($publicSubnets.SubnetId)
$privateSubnetIds = @($privateSubnets.SubnetId)
$publicRoutesOk = $false
$privateRoutesOk = $false
foreach ($rt in @($routeTables.RouteTables)) {
    $associatedSubnetIds = @($rt.Associations | Where-Object { $_.SubnetId } | ForEach-Object { $_.SubnetId })
    $hasIgwDefault = @($rt.Routes | Where-Object { $_.DestinationCidrBlock -eq '0.0.0.0/0' -and $_.GatewayId -like 'igw-*' }).Count -gt 0
    $hasNatDefault = @($rt.Routes | Where-Object { $_.DestinationCidrBlock -eq '0.0.0.0/0' -and $_.NatGatewayId -like 'nat-*' }).Count -gt 0
    if ($hasIgwDefault -and @($publicSubnetIds | Where-Object { $associatedSubnetIds -contains $_ }).Count -eq 2) { $publicRoutesOk = $true }
    if ($hasNatDefault -and @($privateSubnetIds | Where-Object { $associatedSubnetIds -contains $_ }).Count -eq 2) { $privateRoutesOk = $true }
}
Add-Check -Checks $checks -Name 'Rotas publicas' -Expected '0.0.0.0/0 via IGW' -Actual $(if ($publicRoutesOk) { 'Configuradas' } else { 'Ausentes ou divergentes' }) -Passed $publicRoutesOk
Add-Check -Checks $checks -Name 'Rotas privadas' -Expected '0.0.0.0/0 via NAT' -Actual $(if ($privateRoutesOk) { 'Configuradas' } else { 'Ausentes ou divergentes' }) -Passed $privateRoutesOk

$rdsJson = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'rds', 'describe-db-instances',
    '--region', $Region,
    '--db-instance-identifier', $RdsIdentifier,
    '--output', 'json'
)).Output
$rds = @($rdsJson.DBInstances | Select-Object -First 1)
Add-Check -Checks $checks -Name 'RDS existe' -Expected $RdsIdentifier -Actual "$(@($rds).Count)" -Passed (@($rds).Count -eq 1)
if (@($rds).Count -eq 1) {
    $rdsInstance = $rds[0]
    Add-Check -Checks $checks -Name 'RDS available' -Expected 'available' -Actual ([string]$rdsInstance.DBInstanceStatus) -Passed ([string]$rdsInstance.DBInstanceStatus -eq 'available')
    Add-Check -Checks $checks -Name 'RDS privado' -Expected 'PubliclyAccessible=False' -Actual "PubliclyAccessible=$($rdsInstance.PubliclyAccessible)" -Passed (-not [bool]$rdsInstance.PubliclyAccessible)
    Add-Check -Checks $checks -Name 'RDS criptografado' -Expected 'StorageEncrypted=True' -Actual "StorageEncrypted=$($rdsInstance.StorageEncrypted)" -Passed ([bool]$rdsInstance.StorageEncrypted)
    $rdsSubnetIds = @($rdsInstance.DBSubnetGroup.Subnets | ForEach-Object { $_.SubnetIdentifier })
    $rdsOnlyPrivate = @($rdsSubnetIds | Where-Object { $privateSubnetIds -contains $_ }).Count -eq 2
    Add-Check -Checks $checks -Name 'RDS em subnets privadas' -Expected '2 privadas' -Actual "$(@($rdsSubnetIds).Count) subnets" -Passed $rdsOnlyPrivate
    $masterSecretArn = [string]$rdsInstance.MasterUserSecret.SecretArn
    Add-Check -Checks $checks -Name 'Master secret ARN' -Expected 'Presente' -Actual $(if ([string]::IsNullOrWhiteSpace($masterSecretArn)) { 'Ausente' } else { 'Presente' }) -Passed (-not [string]::IsNullOrWhiteSpace($masterSecretArn))

    $sgIds = @($rdsInstance.VpcSecurityGroups | ForEach-Object { $_.VpcSecurityGroupId })
    $sgArguments = @(
        'ec2', 'describe-security-groups',
        '--region', $Region,
        '--group-ids'
    ) + $sgIds + @('--output', 'json')
    $sgJson = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments $sgArguments).Output
    $public1433 = $false
    $adminCidr1433 = $false
    foreach ($sg in @($sgJson.SecurityGroups)) {
        foreach ($permission in @($sg.IpPermissions)) {
            $fromPort = if ($null -eq $permission.FromPort) { -1 } else { [int]$permission.FromPort }
            $toPort = if ($null -eq $permission.ToPort) { -1 } else { [int]$permission.ToPort }
            $hasPublicCidr = @($permission.IpRanges | Where-Object { $_.CidrIp -eq '0.0.0.0/0' }).Count -gt 0
            $hasAdminCidr = -not [string]::IsNullOrWhiteSpace($RdsAdminCidr) -and @($permission.IpRanges | Where-Object { $_.CidrIp -eq $RdsAdminCidr }).Count -gt 0
            if ($fromPort -le 1433 -and $toPort -ge 1433 -and $hasPublicCidr) { $public1433 = $true }
            if ($fromPort -le 1433 -and $toPort -ge 1433 -and $hasAdminCidr) { $adminCidr1433 = $true }
        }
    }
    Add-Check -Checks $checks -Name 'Porta 1433 nao publica' -Expected 'Sem ingresso 0.0.0.0/0' -Actual $(if ($public1433) { 'Exposta' } else { 'Nao exposta' }) -Passed (-not $public1433)
    if (-not [string]::IsNullOrWhiteSpace($RdsAdminCidr)) {
        Add-Check -Checks $checks -Name 'CIDR admin SSMS' -Expected 'Regra 1433 presente' -Actual $(if ($adminCidr1433) { 'Configurada' } else { 'Ausente' }) -Passed $adminCidr1433
    }
}

$subnetGroup = ConvertFrom-JsonOutput -Text (Invoke-AwsReadOnly -Arguments @(
    'rds', 'describe-db-subnet-groups',
    '--region', $Region,
    '--db-subnet-group-name', 'oficina-db-subnet-group',
    '--output', 'json'
)).Output
Add-Check -Checks $checks -Name 'DB Subnet Group' -Expected 'Presente' -Actual "$(@($subnetGroup.DBSubnetGroups).Count)" -Passed (@($subnetGroup.DBSubnetGroups).Count -eq 1)

foreach ($secretName in $ExpectedSecretNames) {
    $secretResult = Invoke-AwsReadOnly -Arguments @(
        'secretsmanager', 'describe-secret',
        '--region', $Region,
        '--secret-id', $secretName,
        '--output', 'json'
    ) -AllowFailure
    Add-Check -Checks $checks -Name "Secret container $secretName" -Expected 'Presente' -Actual $(if ($secretResult.ExitCode -eq 0) { 'Presente' } else { 'Ausente' }) -Passed ($secretResult.ExitCode -eq 0)
}

foreach ($parameterName in $ExpectedSsmParameterNames) {
    $parameterResult = Invoke-AwsReadOnly -Arguments @(
        'ssm', 'get-parameter',
        '--region', $Region,
        '--name', $parameterName,
        '--output', 'json'
    ) -AllowFailure
    Add-Check -Checks $checks -Name "SSM Parameter $parameterName" -Expected 'Presente' -Actual $(if ($parameterResult.ExitCode -eq 0) { 'Presente' } else { 'Ausente' }) -Passed ($parameterResult.ExitCode -eq 0)
}

$checks | Format-Table -AutoSize

$failed = @($checks | Where-Object { $_.Status -ne 'OK' })
if ($failed.Count -gt 0) {
    Write-Error "Validacao read-only da infraestrutura DB falhou em $($failed.Count) requisito(s)."
    exit 1
}

Write-Host "Validacao read-only da infraestrutura DB concluida com sucesso."
