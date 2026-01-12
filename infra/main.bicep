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

@description('Administrator login for the SQL logical server.')
param sqlAdministratorLogin string = 'libsysadmin'

@description('Administrator password for the SQL logical server. Supplied on the command line by the deploying human or the pipeline. It is deliberately absent from main.bicepparam, which is committed - a password in a parameter file is a password in source control.')
@secure()
param sqlAdministratorLoginPassword string

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

module sql 'modules/sql.bicep' = {
  name: 'sql'
  params: {
    location: location
    uniqueSuffix: uniqueSuffix
    administratorLogin: sqlAdministratorLogin
    administratorLoginPassword: sqlAdministratorLoginPassword
  }
}

// Assembled here rather than in the module so that the app settings stay in one place. This is
// the plaintext form, and it is temporary: the Key Vault phase replaces this value with a
// vault reference and removes the password from application configuration entirely.
var sqlConnectionString = 'Server=tcp:${sql.outputs.serverFullyQualifiedDomainName},1433;Initial Catalog=${sql.outputs.databaseName};Persist Security Info=False;User ID=${sqlAdministratorLogin};Password=${sqlAdministratorLoginPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'

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
        {
          name: 'ConnectionStrings__DefaultConnection'
          value: sqlConnectionString
        }
      ]
    }
  }
}

@description('The API\'s hostname, read from the resource rather than constructed. The default hostname is normally <name>.azurewebsites.net, but the unique-default-hostname feature can append a suffix, and anything that builds the string by hand breaks silently when it does.')
output apiHostName string = apiApp.properties.defaultHostName

@description('The API app\'s resource name, so deployment steps do not have to recompute the unique suffix.')
output apiAppName string = apiApp.name

@description('Fully qualified name of the SQL logical server, for the migration step in the pipeline.')
output sqlServerFullyQualifiedDomainName string = sql.outputs.serverFullyQualifiedDomainName

@description('SQL logical server resource name, for firewall rules added and removed around the migration step.')
output sqlServerName string = sql.outputs.serverName

@description('Database name, for the migration step.')
output sqlDatabaseName string = sql.outputs.databaseName
