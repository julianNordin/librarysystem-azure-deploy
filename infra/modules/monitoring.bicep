@description('Location for the workspace and the Application Insights component.')
param location string

@description('Short environment name, used in resource names.')
param environmentName string

@description('Days to retain data. 30 keeps the workspace inside the free ingestion allowance for a project of this size.')
param retentionInDays int = 30

var workspaceName = 'log-librarysystem-${environmentName}'
var appInsightsName = 'appi-librarysystem-${environmentName}'

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

// Workspace-based rather than classic. Classic Application Insights components are retired, and
// only the workspace-backed form puts requests, dependencies and traces in the same store as
// everything else, so one KQL query can join across them.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output applicationInsightsConnectionString string = appInsights.properties.ConnectionString
output applicationInsightsName string = appInsights.name
output workspaceName string = workspace.name
