// Managed Identity Module
// Creates the User-Assigned Managed Identity (ITSM-MI) and assigns required RBAC roles.
// Authentication: All Azure-side auth uses this MI — no SPN or user credentials.

@description('Name for the user-assigned managed identity')
param managedIdentityName string = 'ITSM-MI'

@description('Azure region for the managed identity')
param location string = resourceGroup().location

@description('Subscription ID to assign RBAC roles on')
param subscriptionId string = subscription().subscriptionId

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: {
    purpose: 'Azure Monitor to ServiceNow ITSM integration'
    managedBy: 'azure-monitor-itsm'
  }
}

// Reader — allows MI to enumerate Azure resources (alert targets, subscription metadata)
resource readerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, managedIdentity.id, 'Reader')
  scope: subscription()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Contributor — allows MI to update Azure Monitor alert states
resource monitoringContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, managedIdentity.id, 'MonitoringContributor')
  scope: subscription()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the user-assigned managed identity')
output managedIdentityId string = managedIdentity.id

@description('Principal ID of the managed identity (used for RBAC assignments)')
output principalId string = managedIdentity.properties.principalId

@description('Client ID of the managed identity')
output clientId string = managedIdentity.properties.clientId
