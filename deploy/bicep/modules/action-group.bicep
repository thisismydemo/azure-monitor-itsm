// Action Group Module
// Creates an Azure Monitor Action Group that triggers the Alert Logic App
// every time an Azure Monitor alert changes state (Fired / Resolved).

@description('Action Group name')
param actionGroupName string = 'ag-azure-monitor-itsm'

@description('Short display name (max 12 chars)')
param actionGroupShortName string = 'ITSM-SNOW'

@description('Azure region — Action Groups are global but need a region for the resource')
param location string = 'global'

@description('Resource ID of the Azure-Monitor-Alert-ITSM-HTTP-API Logic App')
param alertLogicAppResourceId string

@description('Enable the common alert schema on the Logic App trigger (required for the Logic App to parse alerts)')
param enableCommonAlertSchema bool = true

resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: actionGroupName
  location: location
  tags: {
    purpose: 'Azure Monitor to ServiceNow ITSM integration'
    managedBy: 'azure-monitor-itsm'
  }
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    logicAppReceivers: [
      {
        name: 'ServiceNow-ITSM-Logic-App'
        resourceId: alertLogicAppResourceId
        callbackUrl: '' // populated automatically by Azure after Logic App deploy
        useCommonAlertSchema: enableCommonAlertSchema
      }
    ]
  }
}

@description('Resource ID of the Action Group')
output actionGroupId string = actionGroup.id

@description('Name of the Action Group')
output actionGroupName string = actionGroup.name
