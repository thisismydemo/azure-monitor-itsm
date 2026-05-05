terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.85.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {}

# ── Data sources ──────────────────────────────────────────────────────────────

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

# ── Resource Group ────────────────────────────────────────────────────────────

resource "azurerm_resource_group" "itsm" {
  name     = var.resource_group_name
  location = var.location
  tags = {
    purpose   = "Azure Monitor to ServiceNow ITSM integration"
    managedBy = "azure-monitor-itsm"
  }
}

# ── User-Assigned Managed Identity (ITSM-MI) ─────────────────────────────────
# All Azure-side auth uses this MI — no SPN, no user credentials

resource "azurerm_user_assigned_identity" "itsm_mi" {
  name                = var.managed_identity_name
  resource_group_name = azurerm_resource_group.itsm.name
  location            = azurerm_resource_group.itsm.location
  tags = {
    purpose   = "Azure Monitor to ServiceNow ITSM integration"
    managedBy = "azure-monitor-itsm"
  }
}

# Reader on subscription — enumerate alert target resources
resource "azurerm_role_assignment" "mi_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.itsm_mi.principal_id
}

# Monitoring Contributor on subscription — update Azure Monitor alert states
resource "azurerm_role_assignment" "mi_monitoring_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_user_assigned_identity.itsm_mi.principal_id
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "itsm" {
  name                       = var.key_vault_name
  resource_group_name        = azurerm_resource_group.itsm.name
  location                   = azurerm_resource_group.itsm.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  enable_rbac_authorization  = true
  soft_delete_retention_days = 7
  tags = {
    purpose   = "Azure Monitor to ServiceNow ITSM integration"
    managedBy = "azure-monitor-itsm"
  }
}

# Key Vault Secrets User — ITSM-MI reads secrets at Logic App runtime
resource "azurerm_role_assignment" "mi_kv_secrets_user" {
  scope                = azurerm_key_vault.itsm.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.itsm_mi.principal_id
}

# Key Vault Secrets Officer — deployer writes secrets during initial setup
resource "azurerm_role_assignment" "deployer_kv_secrets_officer" {
  scope                = azurerm_key_vault.itsm.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ServiceNow credentials — stored as Key Vault secrets only, never in code or state files
resource "azurerm_key_vault_secret" "snow_instance_url" {
  name         = "ItsmApiIntegrationCode"
  value        = var.snow_instance_url
  key_vault_id = azurerm_key_vault.itsm.id
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "snow_username" {
  name         = "ItsmApiUserName"
  value        = var.snow_username
  key_vault_id = azurerm_key_vault.itsm.id
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "snow_password" {
  name         = "ItsmApiSecret"
  value        = var.snow_password
  key_vault_id = azurerm_key_vault.itsm.id
  depends_on   = [azurerm_role_assignment.deployer_kv_secrets_officer]
}

# ── Key Vault API Connection (oauthMI — Managed Identity) ─────────────────────

resource "azurerm_resource_group_template_deployment" "kv_api_connection" {
  name                = "kv-api-connection"
  resource_group_name = azurerm_resource_group.itsm.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters     = {}
    resources = [
      {
        type       = "Microsoft.Web/connections"
        apiVersion = "2016-06-01"
        name       = "itsm-keyvault-connection-mi"
        location   = var.location
        properties = {
          displayName = "itsm-logic-app-to-keyvault"
          api = {
            name = "keyvault"
            id   = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
          }
          # oauthMI = Managed Identity authentication, no secrets, no expiry
          parameterValueSet = {
            name = "oauthMI"
            values = {
              vaultName = {
                value = var.key_vault_name
              }
            }
          }
        }
      }
    ]
    outputs = {
      connectionId = {
        type  = "string"
        value = "[resourceId('Microsoft.Web/connections', 'itsm-keyvault-connection-mi')]"
      }
    }
  })

  depends_on = [azurerm_key_vault.itsm]
}

# ── Logic Apps (via ARM template deployment) ──────────────────────────────────

locals {
  kv_connection_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Web/connections/itsm-keyvault-connection-mi"
  kv_api_id        = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/providers/Microsoft.Web/locations/${var.location}/managedApis/keyvault"
}

resource "azurerm_resource_group_template_deployment" "alert_logic_app" {
  name                = "deploy-alert-logic-app"
  resource_group_name = azurerm_resource_group.itsm.name
  deployment_mode     = "Incremental"

  template_link {
    uri             = "https://raw.githubusercontent.com/john-joyner/Microsoft.Logic/refs/heads/main/Integrate-Azure-Monitor-alerts-with-your-ITSM-Solution/Azure-Monitor-Alert-ITSM-HTTP-API.json"
    content_version = "1.0.0.0"
  }

  parameters_content = jsonencode({
    workflows_Azure_Monitor_Alert_ITSM_HTTP_API_name = { value = "Azure-Monitor-Alert-ITSM-HTTP-API" }
    userAssignedIdentities_ITSM_MI_externalid        = { value = azurerm_user_assigned_identity.itsm_mi.id }
    connections_keyvault_externalid                  = { value = local.kv_connection_id }
    connections_api_externalid                       = { value = local.kv_api_id }
  })

  depends_on = [azurerm_resource_group_template_deployment.kv_api_connection]
}

resource "azurerm_resource_group_template_deployment" "close_logic_app" {
  name                = "deploy-close-logic-app"
  resource_group_name = azurerm_resource_group.itsm.name
  deployment_mode     = "Incremental"

  template_link {
    uri             = "https://raw.githubusercontent.com/john-joyner/Microsoft.Logic/refs/heads/main/Integrate-Azure-Monitor-alerts-with-your-ITSM-Solution/Azure-Monitor-Close-ITSM-HTTP-API.json"
    content_version = "1.0.0.0"
  }

  parameters_content = jsonencode({
    workflows_Azure_Monitor_Close_ITSM_HTTP_API_name = { value = "Azure-Monitor-Close-ITSM-HTTP-API" }
    userAssignedIdentities_ITSM_MI_externalid        = { value = azurerm_user_assigned_identity.itsm_mi.id }
    subscriptionId                                   = { value = data.azurerm_subscription.current.subscription_id }
  })

  depends_on = [azurerm_resource_group_template_deployment.kv_api_connection]
}

# ── Action Group ──────────────────────────────────────────────────────────────

resource "azurerm_monitor_action_group" "itsm" {
  name                = var.action_group_name
  resource_group_name = azurerm_resource_group.itsm.name
  short_name          = "ITSM-SNOW"
  tags = {
    purpose   = "Azure Monitor to ServiceNow ITSM integration"
    managedBy = "azure-monitor-itsm"
  }

  logic_app_receiver {
    name                    = "ServiceNow-ITSM-Logic-App"
    resource_id             = "/subscriptions/${data.azurerm_subscription.current.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Logic/workflows/Azure-Monitor-Alert-ITSM-HTTP-API"
    callback_url            = ""
    use_common_alert_schema = true
  }

  depends_on = [azurerm_resource_group_template_deployment.alert_logic_app]
}
