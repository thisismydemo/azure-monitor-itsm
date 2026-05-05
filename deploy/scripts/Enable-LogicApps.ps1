#Requires -Modules Az.Accounts, Az.LogicApp
<#
.SYNOPSIS
    Enables both Logic Apps after all configuration is complete.
    John Joyner's guide step 14 prerequisite.

.DESCRIPTION
    Logic Apps are deployed DISABLED by design (zero-trust — prevents accidental
    execution before SNOW credentials and Key Vault firewall are configured).

    Run this script AFTER:
    1. Key Vault secrets are populated (Set-KeyVaultSecrets.ps1)
    2. Key Vault firewall is configured (Set-KeyVaultFirewall.ps1)
    3. Logic App parameters are customized (company ID, queue ID, etc.)
    4. SNOW Business Rule is configured with the Close Logic App webhook URL

.PARAMETER ResourceGroupName
    Resource group containing the Logic Apps.

.PARAMETER AlertLogicAppName
    Alert Logic App name (default: Azure-Monitor-Alert-ITSM-HTTP-API).

.PARAMETER CloseLogicAppName
    Close Logic App name (default: Azure-Monitor-Close-ITSM-HTTP-API).

.PARAMETER DisableInstead
    Switch to disable both Logic Apps (useful for maintenance windows).

.EXAMPLE
    .\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm

.EXAMPLE
    .\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm -DisableInstead
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $AlertLogicAppName = 'Azure-Monitor-Alert-ITSM-HTTP-API',
    [string] $CloseLogicAppName = 'Azure-Monitor-Close-ITSM-HTTP-API',

    [switch] $DisableInstead
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }

$action = if ($DisableInstead) { 'Disabling' } else { 'Enabling' }

foreach ($laName in @($AlertLogicAppName, $CloseLogicAppName)) {
    Write-Host "$action Logic App: $laName"
    $la = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $laName -ErrorAction SilentlyContinue
    if (-not $la) {
        Write-Warning "Logic App '$laName' not found — skipping"
        continue
    }

    if ($DisableInstead) {
        Set-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $laName -State 'Disabled' -Force | Out-Null
    } else {
        Set-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $laName -State 'Enabled' -Force | Out-Null
    }
    Write-Host "  ✔ $laName → $($DisableInstead ? 'Disabled' : 'Enabled')" -ForegroundColor $(if ($DisableInstead) { 'Yellow' } else { 'Green' })
}

if (-not $DisableInstead) {
    Write-Host ''
    Write-Host '✅ Both Logic Apps are now enabled.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'Run Test-Integration.ps1 to send a test alert and verify SNOW incident creation.'
}
