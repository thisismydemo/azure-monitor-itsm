#Requires -Modules Az.Accounts, Az.KeyVault, Az.Resources
<#
.SYNOPSIS
    Creates the Key Vault and stores ServiceNow credentials as secrets.
    John Joyner's guide steps 3–4.

.DESCRIPTION
    Creates itsm-kv (RBAC authorization model, soft-delete enabled) and stores:
    - ItsmApiIntegrationCode  → ServiceNow instance URL
    - ItsmApiUserName         → SNOW integration account username
    - ItsmApiSecret           → SNOW integration account password

    Grants Key Vault Secrets User to ITSM-MI and Secrets Officer to the deployer.

.PARAMETER ResourceGroupName
    Resource group containing the Key Vault.

.PARAMETER KeyVaultName
    Name of the Key Vault (default: itsm-kv).

.PARAMETER ManagedIdentityName
    Name of the ITSM-MI to grant Secrets User (default: ITSM-MI).

.PARAMETER SnowInstanceUrl
    ServiceNow instance base URL (e.g. https://dev123456.service-now.com).
    If omitted, you will be prompted securely.

.PARAMETER SnowUsername
    SNOW integration account username (prompted if omitted).

.PARAMETER SnowPassword
    SNOW integration account password (prompted as SecureString if omitted).

.EXAMPLE
    .\Set-KeyVaultSecrets.ps1 -ResourceGroupName rg-azure-monitor-itsm `
        -SnowInstanceUrl https://dev123456.service-now.com `
        -SnowUsername azure_monitor_svc
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $KeyVaultName = 'itsm-kv',
    [string] $ManagedIdentityName = 'ITSM-MI',
    [string] $Location = 'eastus',

    [string] $SnowInstanceUrl,
    [string] $SnowUsername,
    [SecureString] $SnowPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }

# Prompt for any missing SNOW credentials
if (-not $SnowInstanceUrl) {
    $SnowInstanceUrl = Read-Host 'ServiceNow instance URL (e.g. https://dev123456.service-now.com)'
}
if (-not $SnowUsername) {
    $SnowUsername = Read-Host 'ServiceNow integration username'
}
if (-not $SnowPassword) {
    $SnowPassword = Read-Host 'ServiceNow integration password' -AsSecureString
}

# ── Key Vault ─────────────────────────────────────────────────────────────────
$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $kv) {
    Write-Host "Creating Key Vault: $KeyVaultName"
    $kv = New-AzKeyVault -Name $KeyVaultName `
        -ResourceGroupName $ResourceGroupName `
        -Location $Location `
        -EnableRbacAuthorization `
        -SoftDeleteRetentionInDays 7
}

# ── RBAC for deployer (Secrets Officer) and MI (Secrets User) ─────────────────
$deployerObjectId = (Get-AzContext).Account.ExtendedProperties['HomeAccountId'] `
    ?? (Get-AzADUser -UserPrincipalName (Get-AzContext).Account.Id).Id

Write-Host 'Assigning Key Vault Secrets Officer to deployer...'
New-AzRoleAssignment -ObjectId $deployerObjectId `
    -RoleDefinitionName 'Key Vault Secrets Officer' `
    -Scope $kv.ResourceId -ErrorAction SilentlyContinue | Out-Null

$mi = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name $ManagedIdentityName
Write-Host "Assigning Key Vault Secrets User to $ManagedIdentityName..."
New-AzRoleAssignment -ObjectId $mi.PrincipalId `
    -RoleDefinitionName 'Key Vault Secrets User' `
    -Scope $kv.ResourceId -ErrorAction SilentlyContinue | Out-Null

# Brief delay to let RBAC propagate before writing secrets
Start-Sleep -Seconds 15

# ── Secrets ────────────────────────────────────────────────────────────────────
Write-Host 'Writing ItsmApiIntegrationCode...'
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiIntegrationCode' `
    -SecretValue (ConvertTo-SecureString $SnowInstanceUrl -AsPlainText -Force) | Out-Null

Write-Host 'Writing ItsmApiUserName...'
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiUserName' `
    -SecretValue (ConvertTo-SecureString $SnowUsername -AsPlainText -Force) | Out-Null

Write-Host 'Writing ItsmApiSecret...'
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiSecret' `
    -SecretValue $SnowPassword | Out-Null

Write-Host ''
Write-Host '✅ Key Vault secrets stored successfully.' -ForegroundColor Green
Write-Host "   Key Vault URI: $($kv.VaultUri)"
