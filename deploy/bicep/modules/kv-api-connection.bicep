// Key Vault API Connection Module
// Creates the Managed Identity OAuth API connection used by the Logic App to access Key Vault.
// Connection type: oauthMI — no tokens, no secrets, no expiry.

@description('Azure region — must match the Logic App region')
param location string = resourceGroup().location

@description('Key Vault name that this connection targets')
param keyVaultName string = 'itsm-kv'

@description('Connection name — hard-coded to match the Logic App ARM template reference')
param connectionName string = 'itsm-keyvault-connection-mi'

@description('Resource ID of the ITSM-MI user-assigned managed identity')
param managedIdentityId string

var apiId = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/keyvault'

resource kvApiConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: connectionName
  location: location
  tags: {
    purpose: 'Azure Monitor to ServiceNow ITSM integration'
    managedBy: 'azure-monitor-itsm'
  }
  properties: {
    displayName: 'itsm-logic-app-to-keyvault'
    api: {
      name: 'keyvault'
      id: apiId
    }
    // oauthMI: Managed Identity authentication — no client secret, no expiry
    parameterValueSet: {
      name: 'oauthMI'
      values: {
        vaultName: {
          value: keyVaultName
        }
      }
    }
  }
}

@description('Resource ID of the Key Vault API connection')
output connectionId string = kvApiConnection.id

@description('Runtime URL of the connection')
output connectionRuntimeUrl string = reference(kvApiConnection.id, '2016-06-01').connectionRuntimeUrl
