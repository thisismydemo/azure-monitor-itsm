#Requires -Modules Az.Accounts, Az.LogicApp
<#
.SYNOPSIS
    Sends a test alert payload to the Alert Logic App and verifies a SNOW incident is created.

.DESCRIPTION
    End-to-end smoke test:
    1. Reads the Logic App trigger callback URL
    2. POSTs the sample metric-alert-fired.json payload
    3. Polls ServiceNow Table API for the incident using correlation_id = the test alertId
    4. Reports success/failure and the SNOW incident number

    Requires:
    - Both Logic Apps must be enabled (Enable-LogicApps.ps1)
    - SNOW credentials must be in Key Vault (Set-KeyVaultSecrets.ps1)
    - Key Vault must be reachable from the Logic App (Set-KeyVaultFirewall.ps1)

.PARAMETER ResourceGroupName
    Resource group containing the Logic Apps and Key Vault.

.PARAMETER AlertLogicAppName
    Alert Logic App name (default: Azure-Monitor-Alert-ITSM-HTTP-API).

.PARAMETER KeyVaultName
    Key Vault name used to read SNOW credentials for polling (default: itsm-kv).

.PARAMETER SnowTable
    ServiceNow table to poll (default: incident).

.PARAMETER PollIntervalSeconds
    Seconds between SNOW polling attempts (default: 15).

.PARAMETER MaxPollAttempts
    Maximum poll attempts before timing out (default: 12 = 3 minutes).

.EXAMPLE
    .\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $AlertLogicAppName = 'Azure-Monitor-Alert-ITSM-HTTP-API',
    [string] $KeyVaultName = 'itsm-kv',
    [string] $SnowTable = 'incident',
    [int]    $PollIntervalSeconds = 15,
    [int]    $MaxPollAttempts = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }

# ── Read Logic App trigger URL ────────────────────────────────────────────────
Write-Host "Reading trigger URL from: $AlertLogicAppName"
$triggerUrl = (Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName $ResourceGroupName `
    -Name $AlertLogicAppName -TriggerName 'When_a_HTTP_request_is_received').Value

if (-not $triggerUrl) {
    throw "Could not read trigger URL from Logic App '$AlertLogicAppName'. Is it enabled?"
}

# ── Build test payload (common alert schema — Metric alert Fired) ─────────────
$testAlertId = "/subscriptions/$($ctx.Subscription.Id)/providers/Microsoft.AlertsManagement/alerts/test-$(New-Guid)"

$payload = @{
    schemaId = 'azureMonitorCommonAlertSchema'
    data     = @{
        essentials = @{
            alertId           = $testAlertId
            alertRule         = 'TestAlertRule-Integration'
            severity          = 'Sev2'
            signalType        = 'Metric'
            monitorCondition  = 'Fired'
            monitoringService = 'Platform'
            alertTargetIDs    = @("/subscriptions/$($ctx.Subscription.Id)/resourceGroups/$ResourceGroupName")
            configurationItems= @('TestServer01')
            firedDateTime     = (Get-Date -Format 'o')
            description       = 'Integration test alert — created by Test-Integration.ps1'
        }
        alertContext = @{
            properties       = $null
            conditionType    = 'SingleResourceMultipleMetricCriteria'
            condition        = @{
                windowSize    = 'PT5M'
                allOf         = @(
                    @{
                        metricName        = 'Percentage CPU'
                        metricNamespace   = 'Microsoft.Compute/virtualMachines'
                        operator          = 'GreaterThan'
                        threshold         = '90'
                        timeAggregation   = 'Average'
                        metricValue       = 95.5
                    }
                )
            }
        }
    }
}

$payloadJson = $payload | ConvertTo-Json -Depth 20

# ── POST to Logic App ─────────────────────────────────────────────────────────
Write-Host 'Sending test alert to Logic App...'
Write-Host "  Alert ID: $testAlertId"

$response = Invoke-RestMethod -Uri $triggerUrl -Method POST `
    -ContentType 'application/json' -Body $payloadJson

Write-Host "  Logic App accepted the request. Polling SNOW for incident..."

# ── Read SNOW credentials from Key Vault ──────────────────────────────────────
$snowUrl  = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiIntegrationCode' -AsPlainText)
$snowUser = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiUserName' -AsPlainText)
$snowPass = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'ItsmApiSecret' -AsPlainText)

$snowCreds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${snowUser}:${snowPass}"))
$snowHeaders = @{
    Authorization = "Basic $snowCreds"
    Accept        = 'application/json'
    'Content-Type'= 'application/json'
}

# correlation_id in SNOW = Azure Monitor alertId
$pollUrl = "$snowUrl/api/now/table/$SnowTable?sysparm_query=correlation_id=$([uri]::EscapeDataString($testAlertId))&sysparm_limit=1&sysparm_fields=number,sys_id,short_description,state,correlation_id"

# ── Poll SNOW for the incident ────────────────────────────────────────────────
$found = $null
for ($i = 1; $i -le $MaxPollAttempts; $i++) {
    Write-Host "  Poll attempt $i/$MaxPollAttempts..."
    Start-Sleep -Seconds $PollIntervalSeconds

    try {
        $snowResponse = Invoke-RestMethod -Uri $pollUrl -Headers $snowHeaders -Method GET
        if ($snowResponse.result.Count -gt 0) {
            $found = $snowResponse.result[0]
            break
        }
    } catch {
        Write-Warning "  SNOW poll error: $_"
    }
}

# ── Result ────────────────────────────────────────────────────────────────────
if ($found) {
    Write-Host ''
    Write-Host '✅ Integration test PASSED!' -ForegroundColor Green
    Write-Host "   SNOW Incident : $($found.number)"
    Write-Host "   sys_id        : $($found.sys_id)"
    Write-Host "   Short desc    : $($found.short_description)"
    Write-Host "   State         : $($found.state)"
} else {
    Write-Host ''
    Write-Host '❌ Integration test FAILED — no SNOW incident found after timeout.' -ForegroundColor Red
    Write-Host '   Check Logic App run history in the Azure portal for errors.'
    exit 1
}
