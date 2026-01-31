#Requires -Version 7
<#
.SYNOPSIS
    Deletes the environment and verifies that nothing is left behind.

.DESCRIPTION
    The environment exists to be demonstrated, not to run continuously. Everything in it is
    described by infra/main.bicep, so destroying it costs nothing that cannot be rebuilt with a
    single deployment - which is the actual payoff of having written the infrastructure as code.

    Two things this does that `az group delete` alone does not.

    It reads the Key Vault's name *before* deleting the group, because afterwards there is
    nothing left to ask. And it purges the vault, because soft delete keeps the name reserved for
    the whole retention period: the vault's name is derived from the resource group id, so a
    rebuild lands on exactly the same name and fails with a name-in-use error that points nowhere
    near the real cause.

.PARAMETER ResourceGroup
    Resource group to delete.

.PARAMETER Location
    Region the vault lives in. Required to purge a soft-deleted vault.

.PARAMETER Force
    Skip the confirmation prompt. Intended for automation; think before using it interactively.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-librarysystem-dev',
    [string] $Location = 'swedencentral',
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

Write-Step "Checking $ResourceGroup"
$exists = az group exists --name $ResourceGroup | ConvertFrom-Json
if (-not $exists) {
    Write-Host "Resource group $ResourceGroup does not exist. Nothing to do."
    exit 0
}

$resources = az resource list --resource-group $ResourceGroup --query '[].{name:name, type:type}' --output json | ConvertFrom-Json
Write-Host "  $(@($resources).Count) resource(s) will be deleted:"
$resources | ForEach-Object { Write-Host "    $($_.type)/$($_.name)" }

if (-not $Force) {
    $answer = Read-Host "`nDelete resource group '$ResourceGroup' and everything in it? Type the group name to confirm"
    if ($answer -ne $ResourceGroup) {
        Write-Host 'Aborted.' -ForegroundColor Yellow
        exit 1
    }
}

# Ask now, while the group still exists. After the delete there is nothing left to query.
Write-Step 'Recording the Key Vault name before it disappears'
$vaultNames = az keyvault list --resource-group $ResourceGroup --query '[].name' --output json | ConvertFrom-Json
if (@($vaultNames).Count -gt 0) {
    $vaultNames | ForEach-Object { Write-Host "    $_" }
}
else {
    Write-Host '    none found'
}

Write-Step "Deleting $ResourceGroup"
az group delete --name $ResourceGroup --yes --no-wait
Write-Host '    delete requested; waiting for it to finish'
az group wait --name $ResourceGroup --deleted --timeout 1800

Write-Step 'Purging soft-deleted Key Vaults'
foreach ($vaultName in $vaultNames) {
    # Purge protection is deliberately off on this project precisely so this can succeed. With it
    # on, the name stays reserved for the full retention period and a rebuild cannot use it.
    Write-Host "    purging $vaultName"
    az keyvault purge --name $vaultName --location $Location --no-wait
}

Write-Step 'Verifying'
$stillExists = az group exists --name $ResourceGroup | ConvertFrom-Json
if ($stillExists) {
    Write-Host "  FAIL  resource group $ResourceGroup still exists" -ForegroundColor Red
    exit 1
}
Write-Host "  ok    resource group $ResourceGroup is gone" -ForegroundColor Green

$orphans = az resource list --query "[?resourceGroup=='$ResourceGroup']" --output json | ConvertFrom-Json
if (@($orphans).Count -gt 0) {
    Write-Host "  FAIL  $(@($orphans).Count) resource(s) still report this resource group" -ForegroundColor Red
    exit 1
}
Write-Host '  ok    no resources remain' -ForegroundColor Green

Write-Host ''
Write-Host 'Environment destroyed. Nothing is accruing.' -ForegroundColor Green
Write-Host 'Rebuild it with: ./scripts/deploy.ps1'
