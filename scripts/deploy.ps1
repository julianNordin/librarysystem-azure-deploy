#Requires -Version 7
<#
.SYNOPSIS
    Deploys the infrastructure and the API, running the same sequence as the deploy workflow.

.DESCRIPTION
    This script exists so the pipeline can be debugged without pushing to it. Every step here is
    the local equivalent of a step in .github/workflows/deploy.yml, in the same order. If this
    succeeds against real Azure, the workflow's logic is sound and only the runner and the OIDC
    token exchange remain unproven - and neither of those can be exercised locally at all.

    Authentication differs by necessity: this uses whatever identity `az login` holds, while the
    workflow uses a federated credential. That is the one deliberate divergence.

.PARAMETER ResourceGroup
    Resource group to deploy into. Created if it does not already exist.

.PARAMETER Location
    Azure region.

.PARAMETER SqlAdminPassword
    Administrator password for the SQL logical server. Falls back to the SQL_ADMIN_PASSWORD
    environment variable, which is how the workflow supplies it from a repository secret.
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup = 'rg-librarysystem-dev',
    [string] $Location = 'swedencentral',
    [string] $SqlAdminPassword = $env:SQL_ADMIN_PASSWORD
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repoRoot = Split-Path -Parent $PSScriptRoot
$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'librarysystem-deploy'

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Reset-StagingDirectory {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($SqlAdminPassword)) {
    throw 'SQL administrator password not supplied. Set SQL_ADMIN_PASSWORD or pass -SqlAdminPassword.'
}

# main.bicepparam reads this through readEnvironmentVariable, so it has to be present in the
# environment rather than passed as an argument - which also keeps it out of the process list.
$env:SQL_ADMIN_PASSWORD = $SqlAdminPassword

Write-Step "Ensuring resource group $ResourceGroup exists"
az group create --name $ResourceGroup --location $Location --output none

Write-Step 'Deploying infrastructure'
az deployment group create `
    --resource-group $ResourceGroup `
    --name librarysystem-infra `
    --template-file (Join-Path $repoRoot 'infra/main.bicep') `
    --parameters (Join-Path $repoRoot 'infra/main.bicepparam') `
    --output none

Write-Step 'Reading deployment outputs'
# Read the hostnames from the deployment rather than constructing them. App Service default
# hostnames are usually predictable, but the unique-default-hostname feature can append a
# suffix, and anything that builds the string by hand breaks silently when it does.
$outputs = az deployment group show `
    --resource-group $ResourceGroup `
    --name librarysystem-infra `
    --query properties.outputs `
    --output json | ConvertFrom-Json

$apiAppName = $outputs.apiAppName.value
$apiHostName = $outputs.apiHostName.value

Write-Host "    api app : $apiAppName"
Write-Host "    api host: $apiHostName"

Write-Step 'Publishing the API'
$publishDir = Join-Path $stagingRoot 'api-publish'
$apiZip = Join-Path $stagingRoot 'api.zip'
Reset-StagingDirectory -Path $publishDir
if (Test-Path -LiteralPath $apiZip) {
    Remove-Item -LiteralPath $apiZip -Force
}

dotnet publish (Join-Path $repoRoot 'src/LibrarySystem.Api') `
    --configuration Release `
    --output $publishDir `
    --nologo

Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $apiZip -Force

Write-Step 'Deploying the API'
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $apiAppName `
    --src-path $apiZip `
    --type zip `
    --output none

Write-Step 'Checking the API responds'
# F1 has no Always On and the database resumes from auto-pause, so a cold environment can be slow
# to answer the first request. Retry rather than failing on the first timeout.
$apiBase = "https://$apiHostName"
$healthy = $false
foreach ($attempt in 1..8) {
    try {
        $response = Invoke-WebRequest -Uri "$apiBase/health" -TimeoutSec 90 -SkipHttpErrorCheck
        Write-Host "    attempt ${attempt}: HTTP $($response.StatusCode)"
        if ($response.StatusCode -eq 200) {
            $healthy = $true
            break
        }
    }
    catch {
        Write-Host "    attempt ${attempt}: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 20
}

if (-not $healthy) {
    throw "The API did not become healthy at $apiBase/health"
}

Write-Host ''
Write-Host "Done. API: $apiBase" -ForegroundColor Green
