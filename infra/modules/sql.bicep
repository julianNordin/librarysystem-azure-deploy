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

@description('Outbound addresses the API app may originate connections from. Supply possibleOutboundIpAddresses, not outboundIpAddresses: the latter is only the set currently in use, and App Service may move the app to any address in the former without warning.')
param apiOutboundIpAddresses array = []

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

// One single-address rule per address the API app might originate from, replacing the
// 0.0.0.0-0.0.0.0 sentinel that previously admitted any Azure resource in any tenant.
//
// This is the full possible set rather than the three currently in use. App Service moves an app
// between the addresses in that set without notice, so a firewall pinned to today's three fails
// intermittently and for no visible reason. Changing the plan's tier can change the set itself,
// which is why the scale-up phase has to redeploy this rather than leave it alone.
//
// The genuinely correct answer is VNet integration with a private endpoint, so the database has
// no public surface at all. That needs a Standard tier or better and so is out of reach on F1;
// it is recorded as further work rather than pretended away.
resource apiOutboundRules 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = [
  for (ipAddress, index) in apiOutboundIpAddresses: {
    parent: sqlServer
    name: 'AllowApiOutbound-${index}'
    properties: {
      startIpAddress: ipAddress
      endIpAddress: ipAddress
    }
  }
]

output serverFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output serverName string = sqlServer.name
output databaseName string = database.name
