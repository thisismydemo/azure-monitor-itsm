# Deploy with Terraform

Use this method if your team already has Terraform pipelines, or if you manage multi-cloud infrastructure with Terraform.

!!! note "PowerShell scripts still required"
    Terraform handles the Azure resource deployment. PowerShell scripts in `deploy/scripts/` are still used for pre-deploy and post-deploy steps (MI, KV API connection, KV firewall, Action Group, enable).

---

## Prerequisites

- Terraform ≥ 1.5:
  ```bash
  terraform version  # should be ≥ 1.5.0
  ```
- PowerShell 7+ with Az module:
  ```powershell
  Install-Module Az -Scope CurrentUser -Force
  Connect-AzAccount
  ```
- Azure CLI (for pre/post steps):
  ```bash
  az login
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
  -DeploymentMethod Terraform
```

Pass `-SnowPassword (ConvertTo-SecureString $env:SNOW_PW -AsPlainText -Force)` for unattended / CI runs.
Pass `-SkipTest` to skip the end-to-end smoke test.

---

## Manual Step-by-Step

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
```

```bash
# 3. Deploy resources via Terraform
cd deploy/terraform
terraform init

export TF_VAR_snow_instance_url=https://dev123456.service-now.com
export TF_VAR_snow_username=azure_monitor_svc
export TF_VAR_snow_password=<your-password>

terraform plan -var="resource_group_name=rg-azure-monitor-itsm"
terraform apply -var="resource_group_name=rg-azure-monitor-itsm"
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
    Both Logic Apps deploy in **Disabled** state. They remain disabled until you explicitly run `Enable-LogicApps.ps1` after all configuration is complete.

!!! warning "Key Vault connection name"
    The API connection `itsm-keyvault-connection-mi` is referenced **by name** inside the Logic App ARM templates. The Terraform module sets this name — do not override it.

---

## Terraform Variables Reference

| Variable | Default | Description |
|---|---|---|
| `resource_group_name` | `rg-azure-monitor-itsm` | Resource group to deploy into |
| `location` | `eastus` | Azure region |
| `managed_identity_name` | `ITSM-MI` | User-assigned managed identity name |
| `key_vault_name` | `itsm-kv` | Key Vault name (must be globally unique) |
| `kv_connection_name` | `itsm-keyvault-connection-mi` | API connection name — **do not change** |
| `alert_logic_app_name` | `Azure-Monitor-Alert-ITSM-HTTP-API` | Alert Logic App name |
| `close_logic_app_name` | `Azure-Monitor-Close-ITSM-HTTP-API` | Close Logic App name |
| `action_group_name` | `ag-azure-monitor-itsm` | Action Group name |

Set `TF_VAR_*` environment variables or a `terraform.tfvars` file for non-default values.

---

## Remote State Configuration

For team use, configure Terraform remote state in Azure Storage:

```hcl
# deploy/terraform/backend.tf
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "tfstate<unique-suffix>"
    container_name       = "tfstate"
    key                  = "azure-monitor-itsm.tfstate"
  }
}
```

Initialize with:
```bash
terraform init \
  -backend-config="resource_group_name=rg-terraform-state" \
  -backend-config="storage_account_name=tfstate<unique-suffix>"
```

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
