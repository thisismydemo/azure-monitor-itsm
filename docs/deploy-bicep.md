# Deploy with Bicep

Bicep is the **recommended** deployment method. It compiles to ARM templates, has full Azure type-checking, and has the best IDE support of all four methods.

!!! tip "One-command deploy"
    Jump straight to [One-Command Deploy](#one-command-deploy) if you just want to get running.

---

## Prerequisites

- Azure CLI with Bicep extension:
  ```bash
  az bicep install
  az bicep version  # should be ≥ 0.22
  ```
- PowerShell 7+ with Az module:
  ```powershell
  Install-Module Az -Scope CurrentUser -Force
  Connect-AzAccount
  ```
- ServiceNow instance or [PDI](https://developer.servicenow.com) (admin access for Business Rule setup)

---

## One-Command Deploy

```powershell
.\deploy\scripts\Deploy-Solution.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -Location eastus `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc `
  -DeploymentMethod Bicep
```

Pass `-SnowPassword (ConvertTo-SecureString $env:SNOW_PW -AsPlainText -Force)` for unattended / CI runs.
Pass `-SkipTest` to skip the end-to-end smoke test.

The orchestrator runs all steps below automatically.

---

## Manual Step-by-Step

If you prefer to run each step individually (useful for troubleshooting or understanding what happens):

```powershell
# 1. Create prerequisites: resource group, MI, RBAC, KV API connection
.\deploy\scripts\New-Prerequisites.ps1 -ResourceGroupName rg-azure-monitor-itsm -Location eastus
```

```powershell
# 2. Create Key Vault and store SNOW credentials
.\deploy\scripts\Set-KeyVaultSecrets.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc
# (prompted for SNOW password)
```

```bash
# 3. Deploy resources via Bicep
az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file deploy/bicep/main.bicep \
  --parameters deploy/bicep/main.bicepparam
```

```powershell
# 4. Restrict Key Vault firewall to Logic App outbound IPs only
.\deploy\scripts\Set-KeyVaultFirewall.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

```powershell
# 5. Create Action Group
.\deploy\scripts\New-ActionGroup.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

```powershell
# 6. Enable both Logic Apps
.\deploy\scripts\Enable-LogicApps.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

!!! note "Logic Apps deploy disabled"
    Both Logic Apps deploy in **Disabled** state. They remain disabled until you explicitly run `Enable-LogicApps.ps1` after all configuration is complete. This is John Joyner's zero-trust design.

!!! warning "Key Vault connection name"
    The API connection `itsm-keyvault-connection-mi` is referenced **by name** inside the Logic App ARM templates. Do not rename it — the Logic Apps will fail to resolve Key Vault secrets if this name changes.

---

## Bicep Parameter Reference

Parameters are set in `deploy/bicep/main.bicepparam`. Key parameters:

| Parameter | Default | Description |
|---|---|---|
| `resourceGroupName` | `rg-azure-monitor-itsm` | Resource group to deploy into |
| `location` | `eastus` | Azure region |
| `managedIdentityName` | `ITSM-MI` | User-assigned managed identity name |
| `keyVaultName` | `itsm-kv` | Key Vault name (must be globally unique) |
| `kvConnectionName` | `itsm-keyvault-connection-mi` | API connection name — **do not change** |
| `alertLogicAppName` | `Azure-Monitor-Alert-ITSM-HTTP-API` | Alert Logic App name |
| `closeLogicAppName` | `Azure-Monitor-Close-ITSM-HTTP-API` | Close Logic App name |
| `actionGroupName` | `ag-azure-monitor-itsm` | Action Group name |

---

## Verify

```powershell
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

---

## Next Steps

1. **Customize SNOW fields** in the Logic App designer (company, assignment_group, caller_id) — see [Step 8–9 in John Joyner's Guide](./deploy-john-joyner.md#steps-69-deploy-logic-apps-and-customize-snow-fields)
2. **Configure SNOW Business Rule** — see [Step 13 in John Joyner's Guide](./deploy-john-joyner.md#step-13-configure-snow-business-rule) *(manual SNOW-side step)*
3. **Enable Secure Inputs/Outputs and Access Control** — see [Step 14](./deploy-john-joyner.md#step-14-enable-logic-apps--secure-inputsoutputs--access-control)
4. **Associate Action Group with alert rules** — see the [Deployment Overview](./deployment-guide.md)
