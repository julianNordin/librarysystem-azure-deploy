#Requires -Version 7
<#
.SYNOPSIS
    Asserts that a deployed environment actually works.

.DESCRIPTION
    A deploy that reports success without checking anything is a deploy you cannot trust. This
    runs after the applications are published and fails loudly if the environment is not serving.

    The same script is called by scripts/deploy.ps1 and by the smoke job in
    .github/workflows/deploy.yml - pwsh is preinstalled on GitHub's Ubuntu runners - so the
    check proven locally is byte-for-byte the check the pipeline runs.

.PARAMETER ApiHostName
    Hostname of the API app, without a scheme.

.PARAMETER WebHostName
    Hostname of the SPA app, without a scheme.

.PARAMETER ExpectedBookCount
    How many seeded books /api/books must return.

.PARAMETER TimeoutSeconds
    Per-request timeout.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiHostName,
    [Parameter(Mandatory)] [string] $WebHostName,
    [int] $ExpectedBookCount = 5,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

$apiBase = "https://$ApiHostName"
$webBase = "https://$WebHostName"
$failures = [System.Collections.Generic.List[string]]::new()

function Invoke-WithRetry {
    <#
        F1 has no Always On and the serverless database resumes from auto-pause, so a cold
        environment can legitimately take a while to answer the first request. Retrying is not
        papering over flakiness - it is the documented behaviour of the tier this runs on.
    #>
    param(
        [string] $Uri,
        [int] $Attempts = 6
    )

    foreach ($attempt in 1..$Attempts) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSeconds -SkipHttpErrorCheck
            if ($response.StatusCode -eq 200) {
                return $response
            }
            Write-Host "    attempt ${attempt}: HTTP $($response.StatusCode)"
        }
        catch {
            Write-Host "    attempt ${attempt}: $($_.Exception.Message)"
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds 20
        }
    }

    return $null
}

function Add-Failure {
    param([string] $Message)
    $failures.Add($Message)
    Write-Host "  FAIL  $Message" -ForegroundColor Red
}

function Add-Pass {
    param([string] $Message)
    Write-Host "  ok    $Message" -ForegroundColor Green
}

Write-Host ''
Write-Host "Smoke testing $apiBase and $webBase"
Write-Host ''

# 1. The API is up and can reach its database. /health includes a DbContext probe, so a 200 here
#    already establishes database connectivity, not merely that the process is running.
Write-Host 'API health'
$health = Invoke-WithRetry -Uri "$apiBase/health"
if ($null -eq $health) {
    Add-Failure "$apiBase/health did not return 200"
}
elseif ($health.Content.Trim() -ne 'Healthy') {
    Add-Failure "/health returned '$($health.Content.Trim())' rather than 'Healthy'"
}
else {
    Add-Pass '/health reports Healthy'
}

# 2. The seeded data is really there. Checking the count rather than just the status code is the
#    difference between "the API answered" and "the API answered with the right thing".
Write-Host 'API data'
$books = Invoke-WithRetry -Uri "$apiBase/api/books"
if ($null -eq $books) {
    Add-Failure "$apiBase/api/books did not return 200"
}
else {
    $parsed = $books.Content | ConvertFrom-Json
    $count = @($parsed).Count
    if ($count -ne $ExpectedBookCount) {
        Add-Failure "/api/books returned $count books, expected $ExpectedBookCount"
    }
    else {
        Add-Pass "/api/books returned $count books"
    }
}

# 3. The SPA is served.
Write-Host 'SPA'
$root = Invoke-WithRetry -Uri "$webBase/"
if ($null -eq $root) {
    Add-Failure "$webBase/ did not return 200"
}
else {
    Add-Pass 'SPA root responds'
}

# 4. Client-side routing works. A deep link is not a file on disk, so this only returns 200 if
#    the IIS rewrite is in place - which is a separate failure from the SPA being deployed at all.
$deepLink = Invoke-WithRetry -Uri "$webBase/books" -Attempts 2
if ($null -eq $deepLink) {
    Add-Failure "$webBase/books did not return 200 - the SPA fallback rewrite is not working"
}
else {
    Add-Pass 'SPA deep link resolves through the rewrite'
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "Smoke test FAILED with $($failures.Count) problem(s):" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Smoke test passed.' -ForegroundColor Green
exit 0
