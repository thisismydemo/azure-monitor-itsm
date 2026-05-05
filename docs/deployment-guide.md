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

### Steps 8–9: Customize Logic App for Your ServiceNow Environment

**John's guide steps 8–9.** The Logic App deploys with placeholder values for SNOW-specific fields. Update these before enabling.

1. In the Azure portal, open `Azure-Monitor-Alert-ITSM-HTTP-API`
2. Click **Edit** to open the Logic App Designer
3. Find the HTTP action named **Create_SNOW_Incident** (or similar)
4. Update the JSON body with your SNOW environment values:

   | Field | Description | Example |
   |---|---|---|
   | `company` | Your SNOW company sys_id | Get from SNOW: `GET /api/now/table/core_company` |
   | `assignment_group` | SNOW group sys_id for ticket routing | Get from SNOW: `GET /api/now/table/sys_user_group?sysparm_query=name=Service Desk` |
   | `category` / `subcategory` | Ticket category | `software`, `hardware`, `network` |
   | `caller_id` | Default caller sys_id | Usually the integration service account sys_id |

5. For the **target table**, John's Logic App defaults to `incident`. If you need a different table:
   - `incident` — IT incidents (default, recommended)
   - `em_event` — Event Management events (requires ITOM)
   - `change_request` — Change requests
   - `problem` — Problem records
   
   Update the HTTP action URL from `.../table/incident` to `.../table/{your-table}` and adjust the field names to match that table's schema.

6. Save the Logic App

> **Tip**: Use the SNOW REST API Explorer (`/api/now/table/sys_user_group`) or `New-SnowPdiSetup.ps1` output to find sys_id values for your PDI.

---

### Steps 11–12: Trigger Test Alert and Validate

**John's guide steps 11–12.** Validate the integration fires correctly before full rollout.

```powershell
# Automated end-to-end test
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

For manual validation, trigger a real Azure Monitor alert by temporarily lowering a threshold on an existing metric alert rule, then confirm:
- SNOW incident is created with the correct severity mapping
- `correlation_id` on the SNOW record matches the Azure Monitor `alertId`
- Alert state in Azure Monitor changes to `Acknowledged`
- Resolving the alert in Azure Monitor closes the SNOW incident (Resolved state)
- Closing the SNOW incident fires the Business Rule → Close Logic App → Azure Monitor alert closed

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

### Step 14: Enable Logic Apps + Secure Inputs/Outputs

**John's guide step 14.** Enable both Logic Apps and protect Key Vault secrets from appearing in run history.

```powershell
.\deploy\scripts\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

**Secure inputs/outputs** (prevents SNOW credentials from appearing in Logic App run history):

1. In the Azure portal, open `Azure-Monitor-Alert-ITSM-HTTP-API` → **Edit**
2. For each action that reads a Key Vault secret, click the `...` menu → **Settings**
3. Toggle **Secure Inputs** and **Secure Outputs** to **On**
4. Repeat for `Azure-Monitor-Close-ITSM-HTTP-API`
5. Save both Logic Apps

**Logic App Access Control** (restricts inbound calls to Azure Monitor IPs only):

1. In the Azure portal, open each Logic App → **Settings → Workflow settings**
2. Under **Access control configuration → Trigger**, add the Azure Monitor service tag: `AzureMonitor`
3. This prevents anyone other than Azure Monitor from calling the Logic App trigger URL

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
