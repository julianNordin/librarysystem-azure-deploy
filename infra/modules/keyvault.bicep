@description('Location for the vault.')
param location string

@description('Deterministic suffix shared by every globally unique name in this deployment.')
param uniqueSuffix string

@description('Principal id of the API app\'s system-assigned managed identity. This is what gets the role assignment; no credential is created or stored anywhere.')
param apiPrincipalId string

@description('The connection string to store as a secret.')
@secure()
param sqlConnectionString string

// Vault names are capped at 24 characters, which is why this is abbreviated rather than
// following the full librarysystem naming used elsewhere.
var vaultName = 'kv-libsys-${uniqueSuffix}'

var secretName = 'sql-connection-string'

// Key Vault Secrets User: read secret contents, nothing else. Not Key Vault Secrets Officer,
// which could also write and delete them - the application only ever reads.
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // RBAC rather than the older access-policy model. Access policies are per-vault ACLs that
    // sit outside Azure's normal permission system; RBAC puts vault access in the same place as
    // every other permission, which is what makes it auditable alongside them.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: secretName
  properties: {
    value: sqlConnectionString
  }
}

// Scoped to the vault, not to the resource group or the subscription. The app can read secrets
// from this vault and has no standing permission anywhere else.
resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, apiPrincipalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: apiPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output vaultName string = vault.name
output secretName string = secret.name

@description('The app-setting value that makes App Service resolve this secret at startup using the app\'s own identity.')
output secretReference string = '@Microsoft.KeyVault(VaultName=${vault.name};SecretName=${secretName})'
