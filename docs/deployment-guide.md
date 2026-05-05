# Deployment Guide

Step-by-step deployment of the Azure Monitor → ServiceNow integration, mapping to [John Joyner's 14-step guide](https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/).

---

## Prerequisites

- Azure subscription (Contributor access)
- ServiceNow instance or [PDI](https://developer.servicenow.com) (admin access)
- PowerShell 7+, `Az` module
- For Bicep: Azure CLI with Bicep extension
- For Terraform: Terraform ≥ 1.5

```powershell
# Install Az module if needed
Install-Module Az -Scope CurrentUser -Force
Connect-AzAccount
```

---

## Option A: One-Command Deploy (Recommended)

```powershell
.\deploy\scripts\Deploy-Solution.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -Location eastus `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc `
  -DeploymentMethod Bicep
```

The orchestrator runs all steps automatically. Skip to [Step 13 (SNOW Business Rule)](#step-13-configure-snow-business-rule) for the one manual SNOW-side step.

---

## Option B: Step-by-Step (Mirrors John Joyner's Guide)

### Step 1: Create User-Assigned Managed Identity

**John's guide step 1.** The `ITSM-MI` identity is used for all Azure-side auth — no SPN needed.

```powershell
.\deploy\scripts\New-Prerequisites.ps1 -ResourceGroupName rg-azure-monitor-itsm -Location eastus
```

Creates `ITSM-MI` with `Reader` and `Monitoring Contributor` on the subscription.

---

### Steps 2-4: Key Vault + Secrets

**John's guide steps 3–4.**

```powershell
.\deploy\scripts\Set-KeyVaultSecrets.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc
```

Creates `itsm-kv` with RBAC authorization and stores three secrets:
- `ItsmApiIntegrationCode` = SNOW instance URL
- `ItsmApiUserName` = SNOW service account username
- `ItsmApiSecret` = SNOW service account password

---

### Step 5: Key Vault API Connection

**John's guide step 5.** Run as part of `New-Prerequisites.ps1` — creates `itsm-keyvault-connection-mi` with `oauthMI` (Managed Identity, no SPN).

---

### Steps 6-8: Deploy Logic Apps

**John's guide steps 6–9.**

```powershell
# Bicep
az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file deploy/bicep/main.bicep \
  --parameters deploy/bicep/main.bicepparam

# Or via Deploy-Solution.ps1 (handles all parameters)
```

Both Logic Apps deploy in **Disabled** state by design.

After deploying, customize the Logic App to match your SNOW environment (John's step 8-9):
1. Open `Azure-Monitor-Alert-ITSM-HTTP-API` in the Logic App designer
2. Find the HTTP action that creates the SNOW incident
3. Update `company` and `assignment_group` values for your SNOW instance

---

### Step 7 (John's guide): Key Vault Firewall

**John's guide step 7.** Restrict Key Vault to only accept connections from Logic App outbound IPs.

```powershell
.\deploy\scripts\Set-KeyVaultFirewall.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

⚠️ After running this, your local machine may lose Key Vault access unless you add your IP manually.

---

### Step 10: Create Action Group

**John's guide step 10.**

```powershell
.\deploy\scripts\New-ActionGroup.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

Returns the Action Group resource ID — associate it with your Azure Monitor alert rules.

---

### Step 13: Configure SNOW Business Rule

**This is the one manual step.** See [servicenow-pdi-setup.md](./servicenow-pdi-setup.md) for full instructions.

1. Get the Close Logic App webhook URL:
   ```powershell
   (Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName rg-azure-monitor-itsm `
     -Name 'Azure-Monitor-Close-ITSM-HTTP-API' -TriggerName 'When_a_HTTP_request_is_received').Value
   ```

2. In SNOW → **System Definition → Business Rules**, create a new rule on the `incident` table
3. Paste the script from `src/servicenow/snow-automation-rule-script.js`
4. Replace `<CLOSE-LOGIC-APP-WEBHOOK-URL>` with the URL from step 1

Or automate via `New-SnowPdiSetup.ps1 -CloseLogicAppWebhookUrl <url>`.

---

### Step 14: Enable Logic Apps

**John's guide step 14.**

```powershell
.\deploy\scripts\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

---

### Verify: End-to-End Test

```powershell
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

---

## Associate Action Group with Alert Rules

The Action Group must be associated with existing alert rules. Example for a metric alert:

```powershell
$agId = (Get-AzActionGroup -ResourceGroupName rg-azure-monitor-itsm -Name ag-azure-monitor-itsm).Id

# Example: CPU alert on a VM
Add-AzMetricAlertRuleV2 `
  -ResourceGroupName rg-my-workload `
  -Name 'High CPU - ITSM' `
  -TargetResourceScope '/subscriptions/.../resourceGroups/rg-my-workload' `
  -TargetResourceType 'Microsoft.Compute/virtualMachines' `
  -TargetResourceRegion eastus `
  -ActionGroupId $agId `
  -WindowSize ([TimeSpan]::FromMinutes(5)) `
  -EvaluationFrequency ([TimeSpan]::FromMinutes(1)) `
  -Severity 2 `
  -Condition (New-AzMetricAlertRuleV2Criteria -MetricName 'Percentage CPU' `
      -Operator GreaterThan -Threshold 90 -TimeAggregation Average)
```

---

## Terraform Deployment

```bash
cd deploy/terraform
terraform init

export TF_VAR_snow_instance_url=https://dev123456.service-now.com
export TF_VAR_snow_username=azure_monitor_svc
export TF_VAR_snow_password=<your-password>

terraform plan -var="resource_group_name=rg-azure-monitor-itsm"
terraform apply -var="resource_group_name=rg-azure-monitor-itsm"
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Logic App run fails on Key Vault step | Key Vault firewall — add Logic App IPs with `Set-KeyVaultFirewall.ps1` |
| SNOW incident not created | Logic App run history → check HTTP action response code |
| Close Logic App not triggered | SNOW Business Rule active? `correlation_id` starts with `/subscriptions/`? |
| `correlation_id` mismatch | Ensure Action Group uses Common Alert Schema (`useCommonAlertSchema: true`) |
| Logic App not receiving alerts | Action Group enabled? Alert rule associated with AG? |
