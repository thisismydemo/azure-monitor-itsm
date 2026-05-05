#Requires -Modules Az.Accounts, Az.ManagedServiceIdentity, Az.KeyVault, Az.Resources, Az.LogicApp, Az.Monitor
<#
.SYNOPSIS
    Full end-to-end deployment orchestrator for the Azure Monitor → ServiceNow integration.
    Calls all sub-scripts in John Joyner's guide order.

.DESCRIPTION
    Deployment steps:
    1.  New-Prerequisites.ps1   — Create ITSM-MI, RBAC, Key Vault API connection
    2.  Set-KeyVaultSecrets.ps1 — Create itsm-kv and store SNOW credentials
    3.  Deploy Logic Apps + Action Group via Bicep, Terraform, or ARM templates
    4.  Set-KeyVaultFirewall.ps1 — Restrict KV to Logic App outbound IPs
    5.  Enable-LogicApps.ps1   — Enable both Logic Apps
    6.  Test-Integration.ps1   — Smoke test (optional with -SkipTest)

    NOTE: SNOW Business Rule (step 13) must be configured manually in SNOW.
    See docs/servicenow-pdi-setup.md and src/servicenow/snow-automation-rule-script.js.

.PARAMETER ResourceGroupName
    Resource group name (created if it doesn't exist).

.PARAMETER Location
    Azure region (default: eastus).

.PARAMETER SnowInstanceUrl
    ServiceNow instance base URL.

.PARAMETER SnowUsername
    ServiceNow integration account username.

.PARAMETER SnowPassword
    ServiceNow integration account password (SecureString).

.PARAMETER DeploymentMethod
    IaC method to deploy Logic Apps: Bicep, Terraform, or ARM (default: Bicep).

.PARAMETER DeployerObjectId
    AAD Object ID of the deploying identity (default: current user).

.PARAMETER SkipTest
    Skip the end-to-end integration test.

.EXAMPLE
    .\Deploy-Solution.ps1 -ResourceGroupName rg-azure-monitor-itsm `
        -SnowInstanceUrl https://dev123456.service-now.com `
        -SnowUsername azure_monitor_svc -DeploymentMethod Bicep

.EXAMPLE
    # CI/CD — pass credentials as secure strings from pipeline variables
    $pw = ConvertTo-SecureString $env:SNOW_PASSWORD -AsPlainText -Force
    .\Deploy-Solution.ps1 -ResourceGroupName rg-prod-itsm `
        -SnowInstanceUrl $env:SNOW_URL -SnowUsername $env:SNOW_USER `
        -SnowPassword $pw -DeploymentMethod Terraform -SkipTest
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $Location = 'eastus',

    [Parameter(Mandatory)]
    [string] $SnowInstanceUrl,

    [Parameter(Mandatory)]
    [string] $SnowUsername,

    [SecureString] $SnowPassword,

    [ValidateSet('Bicep', 'Terraform', 'ARM')]
    [string] $DeploymentMethod = 'Bicep',

    [string] $DeployerObjectId,

    [switch] $SkipTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsDir = $PSScriptRoot

# ── Login ─────────────────────────────────────────────────────────────────────
$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }
Write-Host "Deploying to: $($ctx.Subscription.Name) | $ResourceGroupName | $Location"

# Prompt for password if not supplied
if (-not $SnowPassword) {
    $SnowPassword = Read-Host 'ServiceNow integration password' -AsSecureString
}

if (-not $DeployerObjectId) {
    $DeployerObjectId = (Get-AzADUser -UserPrincipalName $ctx.Account.Id -ErrorAction SilentlyContinue)?.Id `
        ?? $ctx.Account.ExtendedProperties['HomeAccountId']
}

$commonParams = @{
    ResourceGroupName = $ResourceGroupName
}

# ── Step 1 & 2: MI + KV prerequisites ────────────────────────────────────────
Write-Host ''
Write-Host '═══ Step 1: Creating prerequisites (MI, RBAC, KV API connection) ═══'
& "$ScriptsDir\New-Prerequisites.ps1" @commonParams -Location $Location

Write-Host ''
Write-Host '═══ Step 2: Creating Key Vault and storing SNOW credentials ═══'
& "$ScriptsDir\Set-KeyVaultSecrets.ps1" @commonParams -Location $Location `
    -SnowInstanceUrl $SnowInstanceUrl -SnowUsername $SnowUsername -SnowPassword $SnowPassword

# ── Step 3: Deploy Logic Apps + Action Group ──────────────────────────────────
Write-Host ''
Write-Host "═══ Step 3: Deploying Logic Apps via $DeploymentMethod ═══"

$repoRoot = Split-Path -Parent $ScriptsDir | Split-Path -Parent
$miId = (Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name 'ITSM-MI').Id
$kvConnId = "/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/itsm-keyvault-connection-mi"

switch ($DeploymentMethod) {
    'Bicep' {
        $bicepMain = Join-Path $repoRoot 'deploy\bicep\main.bicep'
        $snowPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SnowPassword))
        New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
            -TemplateFile $bicepMain `
            -location $Location `
            -deployerObjectId $DeployerObjectId `
            -snowInstanceUrl $SnowInstanceUrl `
            -snowUsername $SnowUsername `
            -snowPassword $snowPassPlain `
            -Mode Incremental | Out-Null
        $snowPassPlain = $null
    }
    'Terraform' {
        $tfDir = Join-Path $repoRoot 'deploy\terraform'
        Push-Location $tfDir
        try {
            $env:TF_VAR_resource_group_name = $ResourceGroupName
            $env:TF_VAR_location = $Location
            $env:TF_VAR_snow_instance_url = $SnowInstanceUrl
            $env:TF_VAR_snow_username = $SnowUsername
            $env:TF_VAR_snow_password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SnowPassword))
            terraform init -reconfigure
            terraform apply -auto-approve
        } finally {
            Remove-Item env:TF_VAR_snow_password -ErrorAction SilentlyContinue
            Pop-Location
        }
    }
    'ARM' {
        # Deploy John Joyner's ARM templates directly
        foreach ($template in @('Azure-Monitor-Alert-ITSM-HTTP-API.json', 'Azure-Monitor-Close-ITSM-HTTP-API.json')) {
            $templatePath = Join-Path $repoRoot "src\arm\$template"
            New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                -TemplateFile $templatePath `
                -userAssignedIdentities_ITSM_MI_externalid $miId `
                -connections_keyvault_externalid $kvConnId `
                -Mode Incremental | Out-Null
        }
    }
}

# ── Step 4: Key Vault firewall ────────────────────────────────────────────────
Write-Host ''
Write-Host '═══ Step 4: Restricting Key Vault to Logic App outbound IPs ═══'
& "$ScriptsDir\Set-KeyVaultFirewall.ps1" @commonParams

# ── Step 5: Enable Logic Apps ─────────────────────────────────────────────────
Write-Host ''
Write-Host '═══ Step 5: Enabling Logic Apps ═══'
& "$ScriptsDir\Enable-LogicApps.ps1" @commonParams

# ── Step 6: Smoke test ────────────────────────────────────────────────────────
if (-not $SkipTest) {
    Write-Host ''
    Write-Host '═══ Step 6: Running end-to-end integration test ═══'
    & "$ScriptsDir\Test-Integration.ps1" @commonParams
}

Write-Host ''
Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  DEPLOYMENT COMPLETE' -ForegroundColor Cyan
Write-Host '══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host 'Manual step remaining (ServiceNow side):'
Write-Host '  1. Create SNOW integration user with itil + rest_service roles'
Write-Host '  2. Add the Business Rule from src/servicenow/snow-automation-rule-script.js'
Write-Host '     Replace <CLOSE-LOGIC-APP-WEBHOOK-URL> with the Close Logic App trigger URL'
Write-Host '  3. Associate the Action Group (ag-azure-monitor-itsm) with your alert rules'
Write-Host ''
Write-Host 'See docs/deployment-guide.md for complete instructions.'
