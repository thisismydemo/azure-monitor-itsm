// Key Vault Module
// Creates itsm-kv and stores ServiceNow credentials as secrets.
// Access is restricted to the ITSM-MI managed identity at runtime.
// The deploying user is granted Key Vault Secrets Officer temporarily to populate secrets.

@description('Key Vault name')
param keyVaultName string = 'itsm-kv'

@description('Azure region')
param location string = resourceGroup().location

@description('Principal ID of the ITSM-MI managed identity (needs Key Vault Secrets User)')
param managedIdentityPrincipalId string

@description('Object ID of the deploying user/principal (needs Key Vault Secrets Officer during setup)')
param deployerObjectId string

@description('ServiceNow instance base URL, e.g. https://dev123456.service-now.com')
@secure()
param snowInstanceUrl string

@description('ServiceNow integration account username')
@secure()
param snowUsername string

@description('ServiceNow integration account password')
@secure()
param snowPassword string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: {
    purpose: 'Azure Monitor to ServiceNow ITSM integration'
    managedBy: 'azure-monitor-itsm'
  }
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow' // Tightened via Set-KeyVaultFirewall.ps1 after Logic App IPs are known
    }
  }
}

// Key Vault Secrets User — allows ITSM-MI to read secrets at Logic App runtime
resource miSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentityPrincipalId, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Key Vault Secrets Officer — allows the deployer to write secrets during initial setup
resource deployerSecretsOfficerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerObjectId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// ServiceNow secrets — stored in Key Vault, never in templates or scripts as plaintext
resource secretInstanceUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ItsmApiIntegrationCode'
  properties: {
    value: snowInstanceUrl
    attributes: { enabled: true }
  }
  dependsOn: [deployerSecretsOfficerRole]
}

resource secretUsername 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ItsmApiUserName'
  properties: {
    value: snowUsername
    attributes: { enabled: true }
  }
  dependsOn: [deployerSecretsOfficerRole]
}

resource secretPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ItsmApiSecret'
  properties: {
    value: snowPassword
    attributes: { enabled: true }
  }
  dependsOn: [deployerSecretsOfficerRole]
}

@description('Resource ID of the Key Vault')
output keyVaultId string = keyVault.id

@description('Name of the Key Vault')
output keyVaultName string = keyVault.name

@description('URI of the Key Vault')
output keyVaultUri string = keyVault.properties.vaultUri
