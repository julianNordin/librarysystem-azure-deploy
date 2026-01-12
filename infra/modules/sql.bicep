@description('Location for the logical server and its database.')
param location string

@description('Deterministic suffix shared by every globally unique name in this deployment.')
param uniqueSuffix string

@description('Administrator login for the logical server.')
param administratorLogin string

@description('Administrator password. Supplied on the command line by the deploying human or the pipeline, never from a parameter file - a .bicepparam is committed, and a password in one is a password in source control.')
@secure()
param administratorLoginPassword string

@description('Minutes of inactivity before the serverless database pauses. The free offer requires auto-pause to be enabled.')
param autoPauseDelayMinutes int = 60

var serverName = 'sql-librarysystem-${uniqueSuffix}'
var databaseName = 'sqldb-librarysystem'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: 'GP_S_Gen5_2'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    // The free offer covers 100,000 vCore-seconds and 32 GB per month, and it applies to exactly
    // one database per subscription. AutoPause means that when the allowance is spent the
    // database stops until the month rolls over, rather than continuing to bill.
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    autoPauseDelay: autoPauseDelayMinutes
    minCapacity: json('0.5')
    requestedBackupStorageRedundancy: 'Local'
    zoneRedundant: false
  }
}

// The 0.0.0.0-0.0.0.0 range is a sentinel meaning "any Azure service", not a literal address.
// It is broader than it looks: it admits Azure resources belonging to any tenant, not only this
// subscription. The security phase replaces it with the API app's own outbound addresses.
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output serverFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output serverName string = sqlServer.name
output databaseName string = database.name
