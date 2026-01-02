# LibrarySystem on Azure

Deploys the LibrarySystem API and its React front end to Azure: two App Services on a shared
plan, Azure SQL Database, Key Vault for secrets, Bicep for infrastructure as code, Application
Insights for telemetry, and a GitHub Actions pipeline that authenticates with OIDC and stores no
credentials.

**Status: in progress.** This README is rewritten around the finished deployment story once the
build is complete.

## What this repository is

A self-contained monorepo. The API under `src/LibrarySystem.Api` and the web app under
`src/web` are snapshots of two sibling repositories, vendored here without their git history so
that this repository builds, tests and deploys end to end on its own. Their original histories
stay with the originals.

The application is not the point of this project — it already existed, and its code changes very
little here. The point is the deployment: infrastructure defined as code, secrets that never
reach source control, a pipeline that authenticates without a stored credential, and telemetry
from a service actually serving traffic.

## Layout

```
src/LibrarySystem.Api/        ASP.NET Core 9 Web API
src/LibrarySystem.Api.Tests/  xUnit test suite
src/web/                      Vite + React 19 single-page app
```

## Running locally

The API and the web app run independently. From the repository root:

```bash
dotnet test                       # API test suite
dotnet run --project src/LibrarySystem.Api
```

```bash
cd src/web
npm ci
npm run dev                       # proxies /api to the API, so no CORS setup is needed locally
npm test
```
