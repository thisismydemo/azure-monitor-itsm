#Requires -Modules Az.Accounts, Az.ManagedServiceIdentity, Az.KeyVault, Az.Resources
<#
.SYNOPSIS
    Creates Azure prerequisites for the Azure Monitor → ServiceNow integration.
    John Joyner's guide steps 1–5: MI, Key Vault API connection (oauthMI), RBAC assignments.

.DESCRIPTION
    Creates:
    - User-Assigned Managed Identity (ITSM-MI) with Reader + Monitoring Contributor on sub
    - Key Vault API Connection using oauthMI (Managed Identity only — no SPN)
    - RBAC: ITSM-MI → Key Vault Secrets User

    Authentication: ALL Azure-side auth uses Managed Identity.
    No service principals or user credentials are created for Azure resources.

.PARAMETER ResourceGroupName
    Resource group for all ITSM resources (created if it doesn't exist).

.PARAMETER Location
    Azure region (default: eastus).

.PARAMETER ManagedIdentityName
    Name of the user-assigned managed identity (default: ITSM-MI).

.PARAMETER KeyVaultName
    Name of the Key Vault (default: itsm-kv).

.EXAMPLE
    .\New-Prerequisites.ps1 -ResourceGroupName rg-azure-monitor-itsm -Location eastus
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $Location = 'eastus',
    [string] $ManagedIdentityName = 'ITSM-MI',
    [string] $KeyVaultName = 'itsm-kv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Ensure logged in ──────────────────────────────────────────────────────────
$ctx = Get-AzContext
if (-not $ctx) {
    Write-Host 'Not logged in — running Connect-AzAccount...'
    Connect-AzAccount
    $ctx = Get-AzContext
}
$subscriptionId = $ctx.Subscription.Id
Write-Host "Using subscription: $($ctx.Subscription.Name) ($subscriptionId)"

# ── Resource Group ────────────────────────────────────────────────────────────
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Creating resource group: $ResourceGroupName in $Location"
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location | Out-Null
}

# ── User-Assigned Managed Identity ────────────────────────────────────────────
Write-Host "Creating managed identity: $ManagedIdentityName"
$mi = New-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName `
    -Name $ManagedIdentityName -Location $Location

Write-Host "  Principal ID : $($mi.PrincipalId)"
Write-Host "  Client ID    : $($mi.ClientId)"

# ── RBAC on subscription ──────────────────────────────────────────────────────
$subScope = "/subscriptions/$subscriptionId"

Write-Host 'Assigning Reader on subscription...'
New-AzRoleAssignment -ObjectId $mi.PrincipalId `
    -RoleDefinitionName 'Reader' -Scope $subScope -ErrorAction SilentlyContinue | Out-Null

Write-Host 'Assigning Monitoring Contributor on subscription...'
New-AzRoleAssignment -ObjectId $mi.PrincipalId `
    -RoleDefinitionName 'Monitoring Contributor' -Scope $subScope -ErrorAction SilentlyContinue | Out-Null

# ── Key Vault API Connection (oauthMI) ────────────────────────────────────────
# This is the connection the Logic Apps use to read Key Vault secrets.
# Connection type is oauthMI (Managed Identity — no SPN, no expiry).
Write-Host "Creating Key Vault API connection: itsm-keyvault-connection-mi"

$apiConnectionTemplate = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{}
    resources      = @(
        @{
            type       = 'Microsoft.Web/connections'
            apiVersion = '2016-06-01'
            name       = 'itsm-keyvault-connection-mi'
            location   = $Location
            properties = @{
                displayName = 'itsm-logic-app-to-keyvault'
                api         = @{
                    name = 'keyvault'
                    id   = "/subscriptions/$subscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/keyvault"
                }
                parameterValueSet = @{
                    name   = 'oauthMI'
                    values = @{
                        vaultName = @{ value = $KeyVaultName }
                    }
                }
            }
        }
    )
}

$templateJson = $apiConnectionTemplate | ConvertTo-Json -Depth 20
$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
$templateJson | Set-Content -Path $tempFile -Encoding UTF8

New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
    -TemplateFile $tempFile `
    -DeploymentName 'kv-api-connection' `
    -Mode Incremental | Out-Null

Remove-Item -Path $tempFile -Force

Write-Host ''
Write-Host '✅ Prerequisites created successfully.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Run Set-KeyVaultSecrets.ps1 to create the Key Vault and store SNOW credentials'
Write-Host '  2. Deploy the Logic Apps (bicep/terraform or ARM direct)'
Write-Host '  3. Run Set-KeyVaultFirewall.ps1 to restrict Key Vault access to Logic App outbound IPs'
