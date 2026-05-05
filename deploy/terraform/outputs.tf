output "managed_identity_id" {
  description = "Resource ID of the ITSM-MI user-assigned managed identity"
  value       = azurerm_user_assigned_identity.itsm_mi.id
}

output "managed_identity_principal_id" {
  description = "Principal ID of the managed identity"
  value       = azurerm_user_assigned_identity.itsm_mi.principal_id
}

output "key_vault_uri" {
  description = "URI of the Key Vault containing ServiceNow credentials"
  value       = azurerm_key_vault.itsm.vault_uri
}

output "action_group_id" {
  description = "Resource ID of the Action Group — associate this with Azure Monitor alert rules"
  value       = azurerm_monitor_action_group.itsm.id
}

output "next_steps" {
  description = "Post-deployment instructions"
  value       = "Run Set-KeyVaultFirewall.ps1 to restrict KV to Logic App IPs, then Enable-LogicApps.ps1 to enable both Logic Apps."
}
