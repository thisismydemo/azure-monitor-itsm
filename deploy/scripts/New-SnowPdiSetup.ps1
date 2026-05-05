#Requires -Version 7.0
<#
.SYNOPSIS
    Sets up a ServiceNow Personal Developer Instance (PDI) for testing the
    Azure Monitor → ServiceNow integration.

.DESCRIPTION
    Automates the SNOW-side setup via Table API:
    1. Creates the integration service account (azure_monitor_svc)
    2. Assigns roles: itil, rest_service
    3. Verifies the account can create an incident
    4. Verifies the account can update/close an incident
    5. Optionally imports the Business Rule script (see snow-automation-rule-script.js)

    PDI sign-up: https://developer.servicenow.com
    This script expects an admin account on the PDI.

.PARAMETER SnowInstanceUrl
    Your PDI base URL (e.g. https://dev123456.service-now.com).

.PARAMETER AdminUsername
    PDI admin username (usually 'admin').

.PARAMETER AdminPassword
    PDI admin password (SecureString — prompted if omitted).

.PARAMETER ServiceAccountUsername
    Username for the new integration account (default: azure_monitor_svc).

.PARAMETER ServiceAccountPassword
    Password for the new integration account (SecureString — prompted if omitted).

.PARAMETER CloseLogicAppWebhookUrl
    Webhook URL of the Close Logic App. If provided, the Business Rule is
    automatically created in SNOW pointing to this URL.

.EXAMPLE
    .\New-SnowPdiSetup.ps1 -SnowInstanceUrl https://dev123456.service-now.com `
        -AdminUsername admin

.EXAMPLE
    .\New-SnowPdiSetup.ps1 -SnowInstanceUrl https://dev123456.service-now.com `
        -AdminUsername admin `
        -CloseLogicAppWebhookUrl https://prod-xx.logic.azure.com:443/workflows/...
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SnowInstanceUrl,

    [string] $AdminUsername = 'admin',
    [SecureString] $AdminPassword,

    [string] $ServiceAccountUsername = 'azure_monitor_svc',
    [SecureString] $ServiceAccountPassword,

    [string] $CloseLogicAppWebhookUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Prompt for missing credentials ────────────────────────────────────────────
if (-not $AdminPassword) {
    $AdminPassword = Read-Host "PDI admin password for $AdminUsername" -AsSecureString
}
if (-not $ServiceAccountPassword) {
    $ServiceAccountPassword = Read-Host "Password for new account '$ServiceAccountUsername'" -AsSecureString
}

$adminCreds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(
    "${AdminUsername}:$([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)))"))

$svcPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServiceAccountPassword))

$headers = @{
    Authorization  = "Basic $adminCreds"
    Accept         = 'application/json'
    'Content-Type' = 'application/json'
}

function Invoke-SnowApi {
    param([string]$Method, [string]$Path, [hashtable]$Body)
    $uri = "$SnowInstanceUrl/api/now/$Path"
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    Invoke-RestMethod @params
}

# ── Step 1: Create integration service account ────────────────────────────────
Write-Host "Creating service account: $ServiceAccountUsername"
$userBody = @{
    user_name   = $ServiceAccountUsername
    first_name  = 'Azure Monitor'
    last_name   = 'Integration'
    email       = "$ServiceAccountUsername@example.com"
    user_password = $svcPassPlain
    active      = 'true'
}
$svcPassPlain = $null

$userResponse = Invoke-SnowApi -Method POST -Path 'table/sys_user' -Body $userBody
$userSysId = $userResponse.result.sys_id
Write-Host "  User sys_id: $userSysId"

# ── Step 2: Assign roles ──────────────────────────────────────────────────────
Write-Host 'Assigning roles: itil, rest_service'

foreach ($roleName in @('itil', 'rest_service')) {
    $roleSearch = Invoke-SnowApi -Method GET -Path "table/sys_user_role?sysparm_query=name=$roleName&sysparm_limit=1"
    $roleSysId = $roleSearch.result[0].sys_id
    if (-not $roleSysId) {
        Write-Warning "  Role '$roleName' not found in SNOW — skipping"
        continue
    }

    Invoke-SnowApi -Method POST -Path 'table/sys_user_has_role' -Body @{
        user = $userSysId
        role = $roleSysId
    } | Out-Null

    Write-Host "  ✔ Assigned: $roleName"
}

# ── Step 3: Test incident creation ───────────────────────────────────────────
Write-Host 'Testing incident creation...'
$svcCreds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(
    "$ServiceAccountUsername:$(Read-Host "Enter password for '$ServiceAccountUsername' to verify" -MaskInput)"))
$testHeaders = @{
    Authorization  = "Basic $svcCreds"
    Accept         = 'application/json'
    'Content-Type' = 'application/json'
}

$testIncident = @{
    short_description = 'Azure Monitor PDI test — azure-monitor-itsm'
    description       = 'Created by New-SnowPdiSetup.ps1 integration test'
    impact            = '2'
    urgency           = '2'
    category          = 'software'
    correlation_id    = '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.AlertsManagement/alerts/pdi-test'
}

$incResponse = Invoke-RestMethod -Uri "$SnowInstanceUrl/api/now/table/incident" `
    -Method POST -Headers $testHeaders -Body ($testIncident | ConvertTo-Json)

$incSysId = $incResponse.result.sys_id
$incNumber = $incResponse.result.number
Write-Host "  ✔ Created incident: $incNumber (sys_id: $incSysId)"

# ── Step 4: Test incident update/close ───────────────────────────────────────
Write-Host 'Testing incident close...'
Invoke-RestMethod -Uri "$SnowInstanceUrl/api/now/table/incident/$incSysId" `
    -Method PATCH -Headers $testHeaders -Body (@{
        state             = '6'  # Resolved
        close_code        = 'Solved (Permanently)'
        close_notes       = 'Closed by PDI setup test'
    } | ConvertTo-Json) | Out-Null
Write-Host "  ✔ Incident $incNumber resolved"

# ── Step 5: Import Business Rule (optional) ───────────────────────────────────
if ($CloseLogicAppWebhookUrl) {
    Write-Host 'Creating SNOW Business Rule for bi-directional close...'

    $scriptDir = Join-Path $PSScriptRoot '..\..\..\src\servicenow'
    $scriptContent = Get-Content -Path "$scriptDir\snow-automation-rule-script.js" -Raw
    $scriptContent = $scriptContent -replace '<CLOSE-LOGIC-APP-WEBHOOK-URL>', $CloseLogicAppWebhookUrl

    $ruleBody = @{
        name          = 'Azure Monitor Close Alert on Ticket Complete'
        collection    = 'incident'
        when          = 'after'
        condition     = "current.state == '6' && current.correlation_id.startsWith('/subscriptions/')"
        script        = $scriptContent
        active        = 'true'
        filter_condition = ''
    }

    Invoke-RestMethod -Uri "$SnowInstanceUrl/api/now/table/sys_script" `
        -Method POST -Headers $headers -Body ($ruleBody | ConvertTo-Json -Depth 10) | Out-Null

    Write-Host '  ✔ Business Rule created'
}

Write-Host ''
Write-Host '✅ ServiceNow PDI setup complete!' -ForegroundColor Green
Write-Host ''
Write-Host "   Instance URL : $SnowInstanceUrl"
Write-Host "   Service Acct : $ServiceAccountUsername"
Write-Host "   Test Incident: $incNumber"
Write-Host ''
Write-Host 'Use these credentials in Set-KeyVaultSecrets.ps1 to populate Azure Key Vault.'
