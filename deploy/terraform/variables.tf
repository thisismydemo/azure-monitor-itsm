variable "resource_group_name" {
  description = "Name of the Azure resource group to deploy into"
  type        = string
  default     = "rg-azure-monitor-itsm"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "managed_identity_name" {
  description = "Name of the user-assigned managed identity (all Azure-side auth uses this MI)"
  type        = string
  default     = "ITSM-MI"
}

variable "key_vault_name" {
  description = "Name of the Key Vault (must be globally unique, 3-24 chars)"
  type        = string
  default     = "itsm-kv"
}

variable "action_group_name" {
  description = "Name of the Azure Monitor Action Group"
  type        = string
  default     = "ag-azure-monitor-itsm"
}

# ── ServiceNow credentials — stored in Key Vault only ─────────────────────────
# Use environment variables or a .tfvars file (never commit plaintext secrets).
# Example: TF_VAR_snow_instance_url, TF_VAR_snow_username, TF_VAR_snow_password

variable "snow_instance_url" {
  description = "ServiceNow instance base URL (e.g. https://dev123456.service-now.com)"
  type        = string
  sensitive   = true
}

variable "snow_username" {
  description = "ServiceNow integration service account username"
  type        = string
  sensitive   = true
}

variable "snow_password" {
  description = "ServiceNow integration service account password"
  type        = string
  sensitive   = true
}
