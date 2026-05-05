// Logic App Close Module
// Deploys the Azure-Monitor-Close-ITSM-HTTP-API Logic App using John Joyner's ARM template.
// This Logic App receives the webhook call from ServiceNow when an AM-sourced ticket is completed.
// Deploys in DISABLED state — run Enable-LogicApps.ps1 after testing.

@description('Azure region')
param location string = resourceGroup().location

@description('Resource ID of the ITSM-MI user-assigned managed identity')
param managedIdentityId string

@description('Logic App name — matches the webhook registration in SNOW Business Rule')
param logicAppName string = 'Azure-Monitor-Close-ITSM-HTTP-API'

@description('Subscription ID for Azure Monitor alert API calls')
param subscriptionId string = subscription().subscriptionId

resource closeLogicAppDeploy 'Microsoft.Resources/deployments@2022-09-01' = {
  name: 'deploy-${logicAppName}'
  properties: {
    mode: 'Incremental'
    templateLink: {
      uri: 'https://raw.githubusercontent.com/john-joyner/Microsoft.Logic/refs/heads/main/Integrate-Azure-Monitor-alerts-with-your-ITSM-Solution/Azure-Monitor-Close-ITSM-HTTP-API.json'
      contentVersion: '1.0.0.0'
    }
    parameters: {
      workflows_Azure_Monitor_Close_ITSM_HTTP_API_name: {
        value: logicAppName
      }
      userAssignedIdentities_ITSM_MI_externalid: {
        value: managedIdentityId
      }
      subscriptionId: {
        value: subscriptionId
      }
    }
  }
}

@description('Name of the deployed Logic App')
output logicAppName string = logicAppName
