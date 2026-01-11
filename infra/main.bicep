targetScope = 'resourceGroup'

@description('Location for every resource. Defaults to the resource group\'s own location.')
param location string = resourceGroup().location

@description('Short environment name, used in resource names that do not need to be globally unique.')
param environmentName string = 'dev'

@description('App Service plan SKU. F1 is free and is the normal state of this project. S1 exists because deployment slots require a Standard tier or better; the slot demonstration scales up and straight back down.')
@allowed([
  'F1'
  'B1'
  'S1'
])
param appServicePlanSku string = 'F1'

// Globally unique names need a deterministic suffix. uniqueString over the resource group id
// gives the same answer on every deployment into the same group, which is what makes repeated
// deployments idempotent rather than creating a second set of resources.
var uniqueSuffix = uniqueString(resourceGroup().id)

var planName = 'plan-librarysystem-${environmentName}'
var apiAppName = 'app-librarysystem-api-${uniqueSuffix}'

var skuTiers = {
  F1: 'Free'
  B1: 'Basic'
  S1: 'Standard'
}

// Always On is unavailable on F1, and setting it there fails the deployment rather than being
// ignored. Tying it to the SKU means the one parameter switch carries everything that depends
// on the tier.
var supportsAlwaysOn = appServicePlanSku != 'F1'

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: appServicePlanSku
    tier: skuTiers[appServicePlanSku]
  }
  properties: {
    // false selects a Windows plan. Windows is required because the SPA that shares this plan
    // is served by IIS with a rewrite rule, and a plan cannot host both Windows and Linux apps.
    reserved: false
  }
}

resource apiApp 'Microsoft.Web/sites@2023-12-01' = {
  name: apiAppName
  location: location
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      netFrameworkVersion: 'v9.0'
      healthCheckPath: '/health'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      alwaysOn: supportsAlwaysOn
      appSettings: [
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
      ]
    }
  }
}

@description('The API\'s hostname, read from the resource rather than constructed. The default hostname is normally <name>.azurewebsites.net, but the unique-default-hostname feature can append a suffix, and anything that builds the string by hand breaks silently when it does.')
output apiHostName string = apiApp.properties.defaultHostName

@description('The API app\'s resource name, so deployment steps do not have to recompute the unique suffix.')
output apiAppName string = apiApp.name
