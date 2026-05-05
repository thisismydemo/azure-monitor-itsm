# John Joyner's Guide: Manual Step-by-Step

This page follows [John Joyner's original 14-step guide](https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/) as closely as possible, mapping each step to the automation scripts.

Use this page if you want to understand exactly what the automation does, or if you prefer a manual walkthrough before trusting the orchestrator.

!!! tip "Prefer automation?"
    If you just want to deploy, use one of the [automated method pages](./deployment-guide.md). Come back here when you want to understand *why* each step exists.

---

## Step 1: Create User-Assigned Managed Identity

**John's guide step 1.** The `ITSM-MI` identity is used for all Azure-side auth — no service principal, no client secrets stored anywhere.

**Manual (Azure Portal / CLI):**
```bash
az identity create \
  --name ITSM-MI \
  --resource-group rg-azure-monitor-itsm \
  --location eastus

# Assign Reader + Monitoring Contributor at subscription scope
IDENTITY_ID=$(az identity show --name ITSM-MI --resource-group rg-azure-monitor-itsm --query principalId -o tsv)
az role assignment create --assignee $IDENTITY_ID --role Reader --scope /subscriptions/<subscription-id>
az role assignment create --assignee $IDENTITY_ID --role "Monitoring Contributor" --scope /subscriptions/<subscription-id>
```

**Automation script:**
```powershell
.\deploy\scripts\New-Prerequisites.ps1 -ResourceGroupName rg-azure-monitor-itsm -Location eastus
```

---

## Step 2: Create Resource Group

**Manual:**
```bash
az group create --name rg-azure-monitor-itsm --location eastus
```

This is included automatically in `New-Prerequisites.ps1`.

---

## Steps 3–4: Create Key Vault and Store Secrets

**John's guide steps 3–4.** The Key Vault holds the three SNOW credentials. It is created with **RBAC authorization** (not vault access policies).

**Manual:**
```bash
az keyvault create \
  --name itsm-kv \
  --resource-group rg-azure-monitor-itsm \
  --location eastus \
  --enable-rbac-authorization true

# Grant the managed identity Key Vault Secrets User
az role assignment create \
  --assignee $IDENTITY_ID \
  --role "Key Vault Secrets User" \
  --scope $(az keyvault show --name itsm-kv --query id -o tsv)

# Store the three secrets
az keyvault secret set --vault-name itsm-kv --name ItsmApiIntegrationCode --value https://dev123456.service-now.com
az keyvault secret set --vault-name itsm-kv --name ItsmApiUserName --value azure_monitor_svc
az keyvault secret set --vault-name itsm-kv --name ItsmApiSecret --value <snow-password>
```

**Automation script:**
```powershell
.\deploy\scripts\Set-KeyVaultSecrets.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc
# (prompted for SNOW password)
```

Stores three secrets:

| Secret Name | Value |
|---|---|
| `ItsmApiIntegrationCode` | SNOW instance URL |
| `ItsmApiUserName` | SNOW service account username |
| `ItsmApiSecret` | SNOW service account password |

---

## Step 5: Create Key Vault API Connection

**John's guide step 5.** Creates the API connection `itsm-keyvault-connection-mi` that the Logic Apps use to read Key Vault secrets at runtime.

!!! warning "Name is hard-coded"
    The connection name **`itsm-keyvault-connection-mi`** is referenced by name inside the Logic App ARM templates. Do not change this name, or the Logic Apps will fail to deploy correctly.

This connection uses `oauthMI` (Managed Identity auth) — no service principal required.

**This step runs automatically as part of `New-Prerequisites.ps1`.**

---

## Steps 6–9: Deploy Logic Apps and Customize SNOW Fields

**John's guide steps 6–9.** Deploy the two Logic Apps, then update the SNOW-specific field values for your environment.

Both Logic Apps deploy in **Disabled** state by design (John's zero-trust approach — they cannot fire until you deliberately enable them in Step 14).

**Manual (Bicep example):**
```bash
az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file deploy/bicep/main.bicep \
  --parameters deploy/bicep/main.bicepparam
```

**After deploying**, customize the Logic App for your SNOW environment:

1. In the Azure portal, open `Azure-Monitor-Alert-ITSM-HTTP-API`
2. Click **Edit** to open the Logic App Designer
3. Find the HTTP action named **Create_SNOW_Incident**
4. Update the JSON body with your SNOW environment values:

| Field | Description | How to find it |
|---|---|---|
| `company` | Your SNOW company `sys_id` | `GET /api/now/table/core_company` |
| `assignment_group` | SNOW group `sys_id` for ticket routing | `GET /api/now/table/sys_user_group?sysparm_query=name=Service Desk` |
| `caller_id` | Default caller `sys_id` | Usually the integration service account's `sys_id` |
| `category` / `subcategory` | Ticket category | e.g., `software`, `hardware`, `network` |

5. For the **target table** (John defaults to `incident`):
   - `incident` — IT incidents (**default, recommended**)
   - `em_event` — Event Management events (requires ITOM)
   - `change_request` — Change requests
   - `problem` — Problem records

   Update the HTTP action URL from `.../table/incident` to `.../table/{your-table}` and adjust field names to match that table's schema.

6. Save the Logic App.

> **Tip**: Use `New-SnowPdiSetup.ps1` output to find `sys_id` values for your PDI.

---

## Step 7: Restrict Key Vault Firewall

**John's guide step 7.** After the Logic Apps are deployed, lock down Key Vault to only accept connections from the Logic App outbound IPs.

!!! warning "You will lose local access"
    After running this script, your local machine IP will no longer have direct access to Key Vault unless you add it manually. The script outputs the IPs it added so you can reverse if needed.

**Automation script:**
```powershell
.\deploy\scripts\Set-KeyVaultFirewall.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

---

## Step 10: Create Action Group

**John's guide step 10.** Creates the Action Group `ag-azure-monitor-itsm` that points to the Alert Logic App webhook.

**Automation script:**
```powershell
.\deploy\scripts\New-ActionGroup.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

Returns the Action Group resource ID. Associate it with your Azure Monitor alert rules:

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

## Steps 11–12: Trigger Test Alert and Validate

**John's guide steps 11–12.** Validate the integration fires correctly before full rollout.

**Automated end-to-end test:**
```powershell
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

For manual validation, trigger a real Azure Monitor alert (e.g., temporarily lower a threshold on an existing metric alert rule), then confirm:

- [ ] SNOW incident is created with the correct severity mapping
- [ ] `correlation_id` on the SNOW record matches the Azure Monitor `alertId`
- [ ] Alert state in Azure Monitor changes to `Acknowledged`
- [ ] Resolving the alert in Azure Monitor closes the SNOW incident (Resolved state)
- [ ] Closing the SNOW incident fires the Business Rule → Close Logic App → Azure Monitor alert closed

---

## Step 13: Configure SNOW Business Rule

!!! danger "Manual step — cannot be automated"
    This is the **one step that cannot be automated** from outside SNOW. It requires SNOW admin access in a browser. No PowerShell or API call can create a Business Rule remotely on a standard PDI.

    `New-SnowPdiSetup.ps1` can automate this on a **developer PDI** using the SNOW REST API with admin credentials — but not on production instances.

1. Get the Close Logic App webhook URL:
   ```powershell
   (Get-AzLogicAppTriggerCallbackUrl `
     -ResourceGroupName rg-azure-monitor-itsm `
     -Name 'Azure-Monitor-Close-ITSM-HTTP-API' `
     -TriggerName 'When_a_HTTP_request_is_received').Value
   ```

2. In SNOW → **System Definition → Business Rules**, create a new rule:
   - **Table**: `incident`
   - **When**: `after`
   - **On**: `update`
   - **Condition**: `state changes to Closed`

3. Paste the script from `src/servicenow/snow-automation-rule-script.js`

4. Replace `<CLOSE-LOGIC-APP-WEBHOOK-URL>` with the URL from step 1

**Automation (PDI only):**
```powershell
.\deploy\scripts\New-SnowPdiSetup.ps1 `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -AdminUsername admin `
  -CloseLogicAppWebhookUrl <url-from-step-1>
```

See [ServiceNow PDI Setup](./servicenow-pdi-setup.md) for full instructions.

---

## Step 14: Enable Logic Apps + Secure Inputs/Outputs + Access Control

**John's guide step 14.** Enable both Logic Apps and apply security hardening.

**Enable both Logic Apps:**
```powershell
.\deploy\scripts\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

**Secure Inputs/Outputs** (prevents SNOW credentials from appearing in Logic App run history — must be done manually in the portal):

1. In the Azure portal, open `Azure-Monitor-Alert-ITSM-HTTP-API` → **Edit**
2. For each action that reads a Key Vault secret, click `...` → **Settings**
3. Toggle **Secure Inputs** and **Secure Outputs** → **On**
4. Repeat for `Azure-Monitor-Close-ITSM-HTTP-API`
5. Save both Logic Apps

**Logic App Access Control** (restricts inbound calls to Azure Monitor IPs only):

1. In the Azure portal, open each Logic App → **Settings → Workflow settings**
2. Under **Access control configuration → Trigger**, add the Azure Monitor service tag: `AzureMonitor`
3. This prevents anyone other than Azure Monitor from calling the Logic App trigger URL

---

## Verify: End-to-End Test

```powershell
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

---

## Next Steps

- [Associate the Action Group with your alert rules](./deployment-guide.md)
- [ServiceNow PDI Setup](./servicenow-pdi-setup.md)
- [CI/CD Pipeline Deployment](./deploy-cicd.md)
