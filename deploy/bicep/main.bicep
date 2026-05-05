// Azure Monitor → ServiceNow Integration — Main Bicep Orchestrator
// Deploys all components in the correct order:
//   1. User-Assigned Managed Identity (ITSM-MI)
//   2. Key Vault (itsm-kv) + ServiceNow secrets
//   3. Key Vault API Connection (oauthMI — Managed Identity, no SPN)
//   4. Logic App: Azure-Monitor-Alert-ITSM-HTTP-API (Alert → SNOW)
//   5. Logic App: Azure-Monitor-Close-ITSM-HTTP-API (SNOW close → Azure Monitor)
//   6. Action Group pointing to the Alert Logic App
//
// Reference: John Joyner (Microsoft MVP)
// https://blog.johnjoyner.net/integrate-azure-monitor-alerts-from-servers-with-your-itsm-system/

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

// ── Managed Identity ────────────────────────────────────────────────────────
@description('Name of the user-assigned managed identity')
param managedIdentityName string = 'ITSM-MI'

// ── Key Vault ────────────────────────────────────────────────────────────────
@description('Key Vault name')
param keyVaultName string = 'itsm-kv'

@description('Object ID of the user/service principal deploying this template (needs Secrets Officer to write secrets)')
param deployerObjectId string

// ── ServiceNow Credentials (stored as Key Vault secrets only) ───────────────
@description('ServiceNow instance base URL, e.g. https://dev123456.service-now.com')
@secure()
param snowInstanceUrl string

@description('ServiceNow integration account username')
@secure()
param snowUsername string

@description('ServiceNow integration account password')
@secure()
param snowPassword string

// ── Logic App / ITSM parameters ──────────────────────────────────────────────
@description('SNOW company ID for ticket creation (customize after deployment)')
param itsmCompanyId string = '0'

@description('SNOW queue ID for ticket creation (customize after deployment)')
param itsmQueueId string = '0'

// ── Modules ──────────────────────────────────────────────────────────────────

module identity 'modules/managed-identity.bicep' = {
  name: 'deploy-managed-identity'
  params: {
    managedIdentityName: managedIdentityName
    location: location
  }
}

module kv 'modules/key-vault.bicep' = {
  name: 'deploy-key-vault'
  params: {
    keyVaultName: keyVaultName
    location: location
    managedIdentityPrincipalId: identity.outputs.principalId
    deployerObjectId: deployerObjectId
    snowInstanceUrl: snowInstanceUrl
    snowUsername: snowUsername
    snowPassword: snowPassword
  }
}

module kvConnection 'modules/kv-api-connection.bicep' = {
  name: 'deploy-kv-api-connection'
  params: {
    location: location
    keyVaultName: keyVaultName
    managedIdentityId: identity.outputs.managedIdentityId
  }
  dependsOn: [kv]
}

module alertLogicApp 'modules/logic-app-alert.bicep' = {
  name: 'deploy-logic-app-alert'
  params: {
    location: location
    managedIdentityId: identity.outputs.managedIdentityId
    kvConnectionId: kvConnection.outputs.connectionId
    itsmCompanyId: itsmCompanyId
    itsmQueueId: itsmQueueId
  }
}

module closeLogicApp 'modules/logic-app-close.bicep' = {
  name: 'deploy-logic-app-close'
  params: {
    location: location
    managedIdentityId: identity.outputs.managedIdentityId
  }
}

module actionGroup 'modules/action-group.bicep' = {
  name: 'deploy-action-group'
  params: {
    alertLogicAppResourceId: resourceId('Microsoft.Logic/workflows', 'Azure-Monitor-Alert-ITSM-HTTP-API')
  }
  dependsOn: [alertLogicApp]
}

// ── Outputs ──────────────────────────────────────────────────────────────────

@description('Resource ID of the ITSM-MI managed identity')
output managedIdentityId string = identity.outputs.managedIdentityId

@description('Key Vault URI')
output keyVaultUri string = kv.outputs.keyVaultUri

@description('Action Group resource ID — associate this with your Azure Monitor alert rules')
output actionGroupId string = actionGroup.outputs.actionGroupId

@description('Next steps after deployment')
output nextSteps string = 'Run Set-KeyVaultFirewall.ps1 to restrict KV access to Logic App IPs, then Enable-LogicApps.ps1 to enable both Logic Apps.'
