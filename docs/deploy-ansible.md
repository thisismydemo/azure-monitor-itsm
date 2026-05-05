# Deploy with Ansible

Use this method if your team already uses Ansible for Azure automation and wants the deployment integrated into existing Ansible workflows.

!!! note "PowerShell scripts still required"
    Ansible handles the Azure resource deployment tasks. Some pre/post steps (KV API connection, KV firewall) still invoke the PowerShell scripts in `deploy/scripts/` via the `ansible.builtin.shell` module.

---

## Prerequisites

```bash
# Install Ansible
pip install ansible

# Install Azure collection
ansible-galaxy collection install -r deploy/ansible/requirements.yml

# Authenticate to Azure
az login
# Or set AZURE_* environment variables (see Azure Auth section below)
```

---

## Quick Deploy (Full Run)

```bash
export AZURE_SUBSCRIPTION_ID=<your-subscription-id>

ansible-playbook deploy/ansible/site.yml \
  -e "resource_group_name=rg-azure-monitor-itsm" \
  -e "location=eastus" \
  -e "snow_instance_url=https://dev123456.service-now.com" \
  -e "snow_username=azure_monitor_svc"
# (will prompt for SNOW password unless passed via ansible-vault)
```

!!! note "Logic Apps deploy disabled"
    Both Logic Apps deploy in **Disabled** state. The playbook's `enable` tag step enables them after all configuration is complete.

!!! warning "Key Vault connection name"
    The API connection `itsm-keyvault-connection-mi` is referenced **by name** inside the Logic App ARM templates. This is set as a default in `group_vars/all.yml` — do not override it.

---

## Using ansible-vault for Secrets

Never pass SNOW passwords in plaintext on the command line. Use `ansible-vault`:

```bash
# Encrypt the password
ansible-vault encrypt_string '<your-snow-password>' --name snow_password > vault_vars.yml

# Run with vault
ansible-playbook deploy/ansible/site.yml \
  --ask-vault-pass \
  -e "@vault_vars.yml" \
  -e "snow_instance_url=https://dev123456.service-now.com" \
  -e "snow_username=azure_monitor_svc"
```

For CI/CD pipelines, store the vault password in your pipeline's secret store and pass it via `--vault-password-file`.

---

## Running Specific Steps with Tags

Run only the steps you need using tags:

```bash
# Prerequisites only (MI, resource group, KV API connection)
ansible-playbook deploy/ansible/site.yml --tags prerequisites

# Key Vault creation and secrets
ansible-playbook deploy/ansible/site.yml --tags keyvault

# Logic App deployment
ansible-playbook deploy/ansible/site.yml --tags logic-apps

# Key Vault firewall restriction
ansible-playbook deploy/ansible/site.yml --tags firewall

# Action Group creation
ansible-playbook deploy/ansible/site.yml --tags action-group

# Enable Logic Apps
ansible-playbook deploy/ansible/site.yml --tags enable
```

Available tags: `prerequisites`, `keyvault`, `logic-apps`, `firewall`, `action-group`, `enable`

---

## Variables Reference

Variables are set in `deploy/ansible/group_vars/all.yml`. Key variables:

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
| `snow_instance_url` | *(required)* | ServiceNow instance URL |
| `snow_username` | *(required)* | ServiceNow integration account username |
| `snow_password` | *(required, use vault)* | ServiceNow integration account password |

---

## Azure Authentication

=== "Interactive (az login)"
    ```bash
    az login
    # Ansible will use your current az CLI session
    ```

=== "Service Principal (environment variables)"
    ```bash
    export AZURE_CLIENT_ID=<app-id>
    export AZURE_CLIENT_SECRET=<client-secret>
    export AZURE_TENANT_ID=<tenant-id>
    export AZURE_SUBSCRIPTION_ID=<subscription-id>
    ```
    Use this for pipelines. See [CI/CD Pipelines](./deploy-cicd.md) for pipeline-specific guidance.

=== "Workload Identity / OIDC"
    Configure a federated credential on the app registration and use:
    ```bash
    export AZURE_CLIENT_ID=<app-id>
    export AZURE_TENANT_ID=<tenant-id>
    export AZURE_SUBSCRIPTION_ID=<subscription-id>
    # No AZURE_CLIENT_SECRET needed with federated identity
    ```

!!! note "Deployed resources always use Managed Identity"
    The CI/CD pipeline identity (service principal) is only used to *deploy* resources. The deployed Logic Apps and connections authenticate to Azure services via **Managed Identity** — no client secrets are stored in Azure resources.

---

## Verify

```powershell
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

Or invoke the test from within Ansible:

```bash
ansible-playbook deploy/ansible/site.yml --tags test
```

---

## Next Steps

1. **Customize SNOW fields** in the Logic App designer (company, assignment_group, caller_id) — see [Step 8–9 in John Joyner's Guide](./deploy-john-joyner.md#steps-69-deploy-logic-apps-and-customize-snow-fields)
2. **Configure SNOW Business Rule** — see [Step 13 in John Joyner's Guide](./deploy-john-joyner.md#step-13-configure-snow-business-rule) *(manual SNOW-side step)*
3. **Enable Secure Inputs/Outputs and Access Control** — see [Step 14](./deploy-john-joyner.md#step-14-enable-logic-apps--secure-inputsoutputs--access-control)
4. **Associate Action Group with alert rules** — see the [Deployment Overview](./deployment-guide.md)
