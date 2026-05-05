# Deployment Overview

!!! warning "Azure Monitor ITSM Connector is retired"
    The **Azure Monitor ITSM Connector (ITSMC)** has been retired by Microsoft. This solution replaces it entirely using Logic Apps and a direct ServiceNow REST API integration.
    See [Why Not the ITSM Connector?](./why-not-itsm-connector.md) for the full comparison and migration guidance.

This solution automates Azure Monitor alert → ServiceNow incident integration, based on [John Joyner's 14-step guide](https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/). It supports four IaC deployment methods — pick the one that fits your team.

---

## Choose a Deployment Method

| Method | Files | Best for |
|---|---|---|
| [**Bicep** (Recommended)](./deploy-bicep.md) | `deploy/bicep/` | Azure-native, full type-checking, best IDE support |
| [**Terraform**](./deploy-terraform.md) | `deploy/terraform/` | Multi-cloud teams, existing Terraform pipelines |
| [**Ansible**](./deploy-ansible.md) | `deploy/ansible/` | Teams already running Ansible for Azure automation |
| [**PowerShell / Azure CLI**](./deploy-powershell.md) | `deploy/scripts/` | Direct scripting, CI/CD pipelines |

All four methods deploy identical resources. PowerShell scripts in `deploy/scripts/` handle pre- and post-deploy steps for all methods.

Want to understand every step manually? See [John Joyner's Guide (Manual)](./deploy-john-joyner.md).

Want to deploy from a pipeline? See [CI/CD Pipelines](./deploy-cicd.md).

---

## What Gets Deployed

| Resource | Name | Purpose |
|---|---|---|
| User-Assigned Managed Identity | `ITSM-MI` | All Azure-side auth — no SPN, no client secrets |
| Key Vault | `itsm-kv` | Stores SNOW credentials (RBAC authorization mode) |
| Key Vault API Connection | `itsm-keyvault-connection-mi` | Logic Apps read KV secrets at runtime via Managed Identity |
| Logic App (Alert) | `Azure-Monitor-Alert-ITSM-HTTP-API` | Receives Azure Monitor alerts → creates SNOW incidents |
| Logic App (Close) | `Azure-Monitor-Close-ITSM-HTTP-API` | Receives SNOW closure events → closes Azure Monitor alerts |
| Action Group | `ag-azure-monitor-itsm` | Connects Azure Monitor alert rules to the Alert Logic App |

!!! note "Logic Apps deploy disabled by default"
    Both Logic Apps are deployed in **Disabled** state. This is John Joyner's zero-trust design — they cannot fire until you deliberately enable them after completing all configuration steps.

!!! warning "Key Vault connection name is hard-coded"
    The connection `itsm-keyvault-connection-mi` is referenced **by name** in the Logic App ARM templates. Do not rename it.

---

## Common Prerequisites

- Azure subscription (Contributor access)
- ServiceNow instance or [PDI](https://developer.servicenow.com) (admin access for Business Rule setup)
- PowerShell 7+ with Az module:
  ```powershell
  Install-Module Az -Scope CurrentUser -Force
  Connect-AzAccount
  ```

Additional prerequisites vary by method — see the individual method pages.

---

## Associate Action Group with Alert Rules

After deploying, associate the Action Group with your existing Azure Monitor alert rules:

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

## Troubleshooting

| Symptom | Check |
|---|---|
| Logic App run fails on Key Vault step | Key Vault firewall — add Logic App IPs with `Set-KeyVaultFirewall.ps1` |
| SNOW incident not created | Logic App run history → check HTTP action response code |
| Close Logic App not triggered | SNOW Business Rule active? `correlation_id` starts with `/subscriptions/`? |
| `correlation_id` mismatch | Ensure Action Group uses Common Alert Schema (`useCommonAlertSchema: true`) |
| Logic App not receiving alerts | Action Group enabled? Alert rule associated with AG? |
