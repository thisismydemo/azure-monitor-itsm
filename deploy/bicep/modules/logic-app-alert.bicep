// Logic App Alert Module
// Deploys the Azure-Monitor-Alert-ITSM-HTTP-API Logic App using John Joyner's ARM template
// as a nested deployment. The Logic App deploys in DISABLED state per zero-trust design.
// Run Enable-LogicApps.ps1 after configuration to enable.

@description('Azure region')
param location string = resourceGroup().location

@description('Resource ID of the ITSM-MI user-assigned managed identity')
param managedIdentityId string

@description('Resource ID of the itsm-keyvault-connection-mi API connection')
param kvConnectionId string

@description('External ID of the managed APIs keyvault resource (region-scoped)')
param kvApiExternalId string = '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/keyvault'

@description('Logic App name — default matches the connection name hard-coded in the ARM template')
param logicAppName string = 'Azure-Monitor-Alert-ITSM-HTTP-API'

@description('SNOW company/account ID used when creating ITSM tickets. Customize after deployment.')
param itsmCompanyId string = '0'

@description('SNOW queue/team ID used when creating ITSM tickets. Customize after deployment.')
param itsmQueueId string = '0'

// Nested ARM template deployment — uses John Joyner's Logic App definition verbatim
resource alertLogicAppDeploy 'Microsoft.Resources/deployments@2022-09-01' = {
  name: 'deploy-${logicAppName}'
  properties: {
    mode: 'Incremental'
    templateLink: {
      uri: 'https://raw.githubusercontent.com/john-joyner/Microsoft.Logic/refs/heads/main/Integrate-Azure-Monitor-alerts-with-your-ITSM-Solution/Azure-Monitor-Alert-ITSM-HTTP-API.json'
      contentVersion: '1.0.0.0'
    }
    parameters: {
      workflows_Azure_Monitor_Alert_ITSM_HTTP_API_name: {
        value: logicAppName
      }
      userAssignedIdentities_ITSM_MI_externalid: {
        value: managedIdentityId
      }
      connections_keyvault_externalid: {
        value: kvConnectionId
      }
      connections_api_externalid: {
        value: kvApiExternalId
      }
    }
  }
}

@description('Name of the deployed Logic App')
output logicAppName string = logicAppName
