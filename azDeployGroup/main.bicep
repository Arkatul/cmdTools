param  kvName string
resource keyvault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: kvName
  location: 'West Europe'
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
  }
}
