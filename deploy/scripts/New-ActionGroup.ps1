#Requires -Modules Az.Accounts, Az.Monitor
<#
.SYNOPSIS
    Creates an Azure Monitor Action Group pointing to the Alert Logic App.
    John Joyner's guide step 10.

.DESCRIPTION
    Creates an Action Group with a Logic App receiver.
    The Action Group must be associated with individual alert rules — use the
    resource ID from the output with New-AzMetricAlertRuleV2 or equivalent.

    NOTE: The Logic App must be ENABLED before the Action Group will fire.
    Run Enable-LogicApps.ps1 first.

.PARAMETER ResourceGroupName
    Resource group for the Action Group.

.PARAMETER ActionGroupName
    Action Group name (default: ag-azure-monitor-itsm).

.PARAMETER AlertLogicAppName
    Name of the Alert Logic App (default: Azure-Monitor-Alert-ITSM-HTTP-API).

.EXAMPLE
    .\New-ActionGroup.ps1 -ResourceGroupName rg-azure-monitor-itsm
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $ActionGroupName = 'ag-azure-monitor-itsm',
    [string] $AlertLogicAppName = 'Azure-Monitor-Alert-ITSM-HTTP-API'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ctx = Get-AzContext
if (-not $ctx) { Connect-AzAccount; $ctx = Get-AzContext }
$subscriptionId = $ctx.Subscription.Id

# ── Get Logic App resource ID and callback URL ────────────────────────────────
Write-Host "Getting Logic App trigger URL: $AlertLogicAppName"
$la = Get-AzLogicAppTrigger -ResourceGroupName $ResourceGroupName `
    -Name $AlertLogicAppName -TriggerName 'When_a_HTTP_request_is_received' -ErrorAction SilentlyContinue

if (-not $la) {
    Write-Warning "Could not read Logic App trigger. Ensure '$AlertLogicAppName' is deployed."
}

$laResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$AlertLogicAppName"

# ── Action Group template deployment ─────────────────────────────────────────
# Using ARM template because the Az.Monitor PS module doesn't yet expose
# use_common_alert_schema on Logic App receivers.

Write-Host "Creating Action Group: $ActionGroupName"

$template = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
    contentVersion = '1.0.0.0'
    resources      = @(
        @{
            type       = 'Microsoft.Insights/actionGroups'
            apiVersion = '2023-09-01-preview'
            name       = $ActionGroupName
            location   = 'global'
            tags       = @{ purpose = 'Azure Monitor to ServiceNow ITSM integration' }
            properties = @{
                groupShortName     = 'ITSM-SNOW'
                enabled            = $true
                logicAppReceivers  = @(
                    @{
                        name                 = 'ServiceNow-ITSM-Logic-App'
                        resourceId           = $laResourceId
                        callbackUrl          = ''
                        useCommonAlertSchema = $true
                    }
                )
            }
        }
    )
    outputs = @{
        actionGroupId = @{
            type  = 'string'
            value = "[resourceId('Microsoft.Insights/actionGroups', '$ActionGroupName')]"
        }
    }
}

$tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
($template | ConvertTo-Json -Depth 20) | Set-Content -Path $tempFile -Encoding UTF8

$deploy = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
    -TemplateFile $tempFile -DeploymentName 'action-group' -Mode Incremental

Remove-Item -Path $tempFile -Force

$agId = $deploy.Outputs['actionGroupId'].Value
Write-Host ''
Write-Host '✅ Action Group created.' -ForegroundColor Green
Write-Host "   Resource ID: $agId"
Write-Host ''
Write-Host 'Next step: Associate this Action Group with your Azure Monitor alert rules.'
