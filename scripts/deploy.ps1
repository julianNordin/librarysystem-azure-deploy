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
    [string] $SqlAdminLogin = 'libsysadmin',
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
$webAppName = $outputs.webAppName.value
$webHostName = $outputs.webHostName.value
$sqlServerName = $outputs.sqlServerName.value
$sqlServerFqdn = $outputs.sqlServerFullyQualifiedDomainName.value
$sqlDatabaseName = $outputs.sqlDatabaseName.value

Write-Host "    api app : $apiAppName"
Write-Host "    api host: $apiHostName"
Write-Host "    sql     : $sqlServerFqdn"

Write-Step 'Applying database migrations'
# A migrations bundle is a self-contained executable holding the migrations that already exist.
# It is built here rather than being committed, and note it is `migrations bundle`, never
# `migrations add` - the latter stamps the real date into a filename and into the [Migration]
# attribute, which then has to be unpicked later.
$bundle = Join-Path $stagingRoot 'efbundle.exe'
dotnet ef migrations bundle `
    --project (Join-Path $repoRoot 'src/LibrarySystem.Api') `
    --startup-project (Join-Path $repoRoot 'src/LibrarySystem.Api') `
    --self-contained -r win-x64 `
    --configuration Release `
    --output $bundle `
    --force

# This machine is not in the SQL firewall - the hardening pass narrowed it to the API app's
# outbound addresses only. So open a hole for this address, migrate, and close it again. The
# close has to happen even when the migration throws: a failed deployment must never be the
# reason the database is left reachable from somewhere it should not be.
$migrationFirewallRule = 'migrate-temp'

function Set-MigrationFirewallRule {
    param([string] $IpAddress)
    az sql server firewall-rule create `
        --resource-group $ResourceGroup `
        --server $sqlServerName `
        --name $migrationFirewallRule `
        --start-ip-address $IpAddress `
        --end-ip-address $IpAddress `
        --output none
}

$migrationConnection = "Server=tcp:$sqlServerFqdn,1433;Initial Catalog=$sqlDatabaseName;User ID=$SqlAdminLogin;Password=$SqlAdminPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

try {
    $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 30).ip
    Write-Host "    opening the firewall for $publicIp"
    Set-MigrationFirewallRule -IpAddress $publicIp

    $output = & $bundle --connection $migrationConnection 2>&1

    if ($LASTEXITCODE -ne 0) {
        # A public echo service reports the address used to reach *it*, over HTTPS. Behind a NAT
        # pool the SQL connection can leave from a different address entirely, and then the rule
        # is correct for the wrong address. The server's own error names the address it actually
        # saw, which is the authoritative answer - so take it and try once more.
        $reportedIp = [regex]::Match(
            ($output -join "`n"),
            "Client with IP address '([0-9]{1,3}(?:\.[0-9]{1,3}){3})'").Groups[1].Value

        if ($reportedIp -and $reportedIp -ne $publicIp) {
            Write-Host "    the server saw $reportedIp instead; reopening for that address"
            Set-MigrationFirewallRule -IpAddress $reportedIp
            # Firewall changes are not always instant.
            Start-Sleep -Seconds 10
            $output = & $bundle --connection $migrationConnection 2>&1
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "Migration bundle failed with exit code $LASTEXITCODE"
    }

    Write-Host '    migrations applied'
}
finally {
    # Always, including when the migration threw. A failed deployment must never be the reason
    # the database is left reachable from somewhere it should not be.
    Write-Host '    closing the firewall'
    az sql server firewall-rule delete `
        --resource-group $ResourceGroup `
        --server $sqlServerName `
        --name $migrationFirewallRule `
        --output none
}

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

Write-Step 'Building the SPA'
# The API URL is baked in at build time by Vite, so the front end cannot be built before the API
# hostname is known - which is why this comes after the infrastructure deployment rather than
# alongside it. No trailing slash: apiClient concatenates '/api/books' onto this directly.
$webDir = Join-Path $repoRoot 'src/web'
$webZip = Join-Path $stagingRoot 'web.zip'
$env:VITE_API_BASE_URL = "https://$apiHostName"
Write-Host "    VITE_API_BASE_URL=$env:VITE_API_BASE_URL"

Push-Location $webDir
try {
    npm ci
    npm run build
}
finally {
    Pop-Location
}

if (Test-Path -LiteralPath $webZip) {
    Remove-Item -LiteralPath $webZip -Force
}
Compress-Archive -Path (Join-Path $webDir 'dist/*') -DestinationPath $webZip -Force

Write-Step 'Deploying the SPA'
az webapp deploy `
    --resource-group $ResourceGroup `
    --name $webAppName `
    --src-path $webZip `
    --type zip `
    --output none

Write-Step 'Smoke testing the deployed environment'
# The same script the pipeline's smoke job runs, so what is proven here is what runs there.
& (Join-Path $PSScriptRoot 'smoke.ps1') -ApiHostName $apiHostName -WebHostName $webHostName
if ($LASTEXITCODE -ne 0) {
    throw 'Smoke test failed.'
}

Write-Host ''
Write-Host "Done." -ForegroundColor Green
Write-Host "  API: https://$apiHostName"
Write-Host "  SPA: https://$webHostName"
