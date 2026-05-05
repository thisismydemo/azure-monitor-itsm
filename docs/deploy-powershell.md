# Deploy with PowerShell / Azure CLI

This page covers direct scripted deployment using the PowerShell scripts in `deploy/scripts/`. These scripts use the **Az PowerShell module**. Azure CLI equivalents are shown where the commands differ.

!!! tip "This is also how the other methods work"
    All four IaC methods (Bicep, Terraform, Ansible, ARM) call these same PowerShell scripts for pre- and post-deploy steps. Understanding this page gives you a complete picture of the full deployment.

---

## Prerequisites

=== "PowerShell (Az module)"
    ```powershell
    Install-Module Az -Scope CurrentUser -Force
    Connect-AzAccount
    # Select the target subscription if you have multiple
    Set-AzContext -SubscriptionId <subscription-id>
    ```

=== "Azure CLI"
    ```bash
    az login
    az account set --subscription <subscription-id>
    ```

- PowerShell 7+ required
- ServiceNow instance or [PDI](https://developer.servicenow.com) (admin access for Business Rule setup)

---

## One-Command Deploy (Orchestrator)

```powershell
.\deploy\scripts\Deploy-Solution.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -Location eastus `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc `
  -DeploymentMethod Bicep
```

**Available `-DeploymentMethod` values:** `Bicep` (default), `Terraform`, `ARM`, `Ansible`

**For unattended / CI runs**, pass the password as a SecureString to avoid interactive prompts:
```powershell
$pw = ConvertTo-SecureString $env:SNOW_PASSWORD -AsPlainText -Force
.\deploy\scripts\Deploy-Solution.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -Location eastus `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -SnowUsername azure_monitor_svc `
  -SnowPassword $pw `
  -DeploymentMethod Bicep `
  -SkipTest
```

Pass `-SkipTest` to skip the end-to-end smoke test (useful in pipelines where a real SNOW instance isn't available at deploy time).

---

## Individual Script Reference

| Script | Purpose | Key Parameters |
|---|---|---|
| `New-Prerequisites.ps1` | Create RG, MI, RBAC assignments, KV API connection | `-ResourceGroupName`, `-Location` |
| `Set-KeyVaultSecrets.ps1` | Create Key Vault (RBAC auth) and store SNOW credentials | `-SnowInstanceUrl`, `-SnowUsername`, `-SnowPassword` |
| `Set-KeyVaultFirewall.ps1` | Restrict KV to Logic App outbound IPs only | `-ResourceGroupName` |
| `New-ActionGroup.ps1` | Create Action Group pointing to Alert Logic App webhook | `-ResourceGroupName` |
| `Enable-LogicApps.ps1` | Enable both Logic Apps (they deploy disabled) | `-ResourceGroupName` |
| `Test-Integration.ps1` | End-to-end smoke test | `-ResourceGroupName` |
| `New-SnowPdiSetup.ps1` | Configure SNOW PDI (service account, Business Rule) | `-SnowInstanceUrl`, `-AdminUsername` |
| `Deploy-Solution.ps1` | Full orchestrator — calls all of the above | `-DeploymentMethod Bicep\|Terraform\|ARM\|Ansible` |

---

## Azure CLI Equivalents

For key steps where Azure CLI differs from the Az PowerShell module:

**Create Managed Identity:**
```bash
az identity create \
  --name ITSM-MI \
  --resource-group rg-azure-monitor-itsm \
  --location eastus
```

**Create Key Vault with RBAC authorization:**
```bash
az keyvault create \
  --name itsm-kv \
  --resource-group rg-azure-monitor-itsm \
  --location eastus \
  --enable-rbac-authorization true
```

**ARM template deployment (John's original templates):**
```bash
az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file src/arm/Azure-Monitor-Alert-ITSM-HTTP-API.json \
  --parameters location=eastus managedIdentityName=ITSM-MI keyVaultName=itsm-kv

az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file src/arm/Azure-Monitor-Close-ITSM-HTTP-API.json \
  --parameters location=eastus managedIdentityName=ITSM-MI keyVaultName=itsm-kv
```

**Bicep deployment:**
```bash
az deployment group create \
  --resource-group rg-azure-monitor-itsm \
  --template-file deploy/bicep/main.bicep \
  --parameters deploy/bicep/main.bicepparam
```

---

## Environment Variables for CI/CD Unattended Runs

In pipelines, store SNOW credentials as secret variables and pass them as environment variables:

```powershell
# GitHub Actions / Azure DevOps / GitLab CI example:
# SNOW_PASSWORD is set as a secret/masked variable in the pipeline

$pw = ConvertTo-SecureString $env:SNOW_PASSWORD -AsPlainText -Force

.\deploy\scripts\Deploy-Solution.ps1 `
  -ResourceGroupName rg-azure-monitor-itsm `
  -Location eastus `
  -SnowInstanceUrl $env:SNOW_INSTANCE_URL `
  -SnowUsername $env:SNOW_USERNAME `
  -SnowPassword $pw `
  -DeploymentMethod Bicep `
  -SkipTest
```

See [CI/CD Pipelines](./deploy-cicd.md) for complete pipeline YAML examples.

---

## Notes on Auth

- The scripts use the current Az session context (from `Connect-AzAccount` or `az login`)
- **Azure resources always use Managed Identity** — the pipeline identity (SPN) is only used to call the ARM/Bicep APIs to deploy. The Logic Apps and connections never use a SPN
- The Key Vault API connection (`itsm-keyvault-connection-mi`) uses `oauthMI` (Managed Identity) — no client secret needed at runtime

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
5. **Set up a pipeline** — see [CI/CD Pipelines](./deploy-cicd.md)
