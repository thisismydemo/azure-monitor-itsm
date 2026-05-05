#Requires -Modules Az.Accounts, Az.KeyVault, Az.LogicApp
<#
.SYNOPSIS
    Retrieves Logic App outbound IPs and adds them to the Key Vault network firewall.
    John Joyner's guide step 7.

.DESCRIPTION
    Logic Apps use a dynamic pool of outbound IPs (region-specific).
    This script queries both Logic Apps for their current outbound IP list,
    then adds each IP as an allowed network rule on the Key Vault.

    Run this after Logic App deployment, before enabling them.

.PARAMETER ResourceGroupName
    Resource group containing both Logic Apps and the Key Vault.

.PARAMETER KeyVaultName
    Key Vault name (default: itsm-kv).

.PARAMETER AlertLogicAppName
    Alert Logic App name (default: Azure-Monitor-Alert-ITSM-HTTP-API).

.PARAMETER CloseLogicAppName
    Close Logic App name (default: Azure-Monitor-Close-ITSM-HTTP-API).

.EXAMPLE
    .\Set-KeyVaultFirewall.ps1 -ResourceGroupName rg-azure-monitor-itsm
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $KeyVaultName = 'itsm-kv',
    [string] $AlertLogicAppName = 'Azure-Monitor-Alert-ITSM-HTTP-API',
    [string] $CloseLogicAppName = 'Azure-Monitor-Close-ITSM-HTTP-API'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }

# ── Collect outbound IPs from both Logic Apps ─────────────────────────────────
$allIps = [System.Collections.Generic.HashSet[string]]::new()

foreach ($laName in @($AlertLogicAppName, $CloseLogicAppName)) {
    Write-Host "Getting outbound IPs for Logic App: $laName"
    $la = Get-AzLogicApp -ResourceGroupName $ResourceGroupName -Name $laName -ErrorAction SilentlyContinue
    if (-not $la) {
        Write-Warning "Logic App '$laName' not found in $ResourceGroupName — skipping"
        continue
    }

    # Outbound IPs are on the Logic App properties
    foreach ($ip in $la.OutboundIpAddresses -split ',') {
        $clean = $ip.Trim()
        if ($clean) { $allIps.Add($clean) | Out-Null }
    }
    foreach ($ip in $la.AdditionalInformation.AdditionalProperties.outboundIPAddresses -split ',') {
        $clean = $ip.Trim()
        if ($clean) { $allIps.Add($clean) | Out-Null }
    }
}

if ($allIps.Count -eq 0) {
    Write-Warning 'No outbound IPs found. Ensure both Logic Apps are deployed before running this script.'
    exit 1
}

Write-Host "Found $($allIps.Count) unique outbound IPs"

# ── Add each IP to the Key Vault firewall ─────────────────────────────────────
$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName
Write-Host "Adding IPs to Key Vault firewall: $KeyVaultName"

foreach ($ip in $allIps) {
    Write-Host "  Adding: $ip/32"
    Add-AzKeyVaultNetworkRule -VaultName $KeyVaultName -IpAddressRange "$ip/32" | Out-Null
}

# Restrict default action to Deny (only allowlisted IPs can access)
Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -DefaultAction Deny | Out-Null

Write-Host ''
Write-Host '✅ Key Vault firewall updated.' -ForegroundColor Green
Write-Host '   Only Logic App outbound IPs can now reach the Key Vault.'
Write-Host ''
Write-Host 'IMPORTANT: If you run this from a machine NOT in the allowlist, you will lose'
Write-Host '   access to the Key Vault from your local terminal. Add your IP manually if needed:'
Write-Host "   Add-AzKeyVaultNetworkRule -VaultName $KeyVaultName -IpAddressRange <your-ip>/32"
