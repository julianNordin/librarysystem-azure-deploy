# LibrarySystem on Azure

An ASP.NET Core 9 API and a React 19 single-page app, deployed to Azure entirely from code:
infrastructure defined in Bicep, secrets held in Key Vault and reached through a managed
identity, and a GitHub Actions pipeline that authenticates to Azure **without storing a
credential of any kind**.

The application is not the interesting part. It already existed, and its code barely changes
here. The subject of this project is the deployment.

## Related projects

This repo vendors snapshots of two standalone projects without their git history (see
[Repository layout](#repository-layout)) so it can build, test and deploy end to end on its
own. For their full commit history, see the originals:

- [LibrarySystem.Api](https://github.com/julianNordin/LibrarySystem.Api) — the API developed on its own
- [LibrarySystem.Web](https://github.com/julianNordin/LibrarySystem.Web) — the frontend developed on its own

## What it demonstrates

- **Infrastructure as code.** Every resource is declared in `infra/`. The environment is created,
  changed, destroyed and recreated by deploying a template — never by clicking.
- **Secrets that are not in source control.** The database connection string lives in Key Vault.
  The API reads it through an app setting that is a *reference*, resolved at startup by the app's
  own system-assigned managed identity. No password appears in any application setting.
- **A pipeline with no stored credential.** Deployment authenticates with OIDC federated
  credentials. There is no service principal secret, in GitHub or anywhere else.
- **Least privilege.** The pipeline identity is scoped to one resource group, never the
  subscription: Contributor to manage resources, plus RBAC Administrator **conditioned so it can
  assign exactly one role definition and no other** — because Contributor cannot create role
  assignments at all, and an unconditioned grant would let the pipeline make itself Owner. The
  API's identity may read one secret from one vault, and nothing else.
- **Telemetry from a service actually serving traffic**, including dependency tracing through to
  the database tier.
- **A deploy that verifies itself.** A smoke test asserts the environment really works and fails
  the deployment when it does not.

## Architecture

```
                      browser
                         |
              +----------+-----------+
              |                      |
        web App Service        api App Service
        (SPA, IIS rewrite)     (ASP.NET Core 9)
              |                      |  system-assigned
              |  cross-origin        |  managed identity
              |  fetch, CORS         |
              +--------------------->|
                                     |--------> Key Vault  (connection string)
                                     |--------> Azure SQL  (serverless, free offer)
                                     |--------> App Insights -> Log Analytics
              \______________________/
                 one App Service plan
```

Both apps share a single Windows App Service plan. A second app on the plan costs nothing extra,
and two apps means two origins — which makes the CORS policy a real requirement rather than a
theoretical one.

Full reasoning, including why the pipeline's authentication model was chosen over the more common
one, is in [`docs/architecture.md`](docs/architecture.md).

## Repository layout

```
src/LibrarySystem.Api/        ASP.NET Core 9 Web API
src/LibrarySystem.Api.Tests/  xUnit test suite
src/web/                      Vite + React 19 single-page app
infra/                        Bicep templates and modules
.github/workflows/            CI, and the deployment pipeline
scripts/                      the same deployment steps, runnable locally
docs/                         architecture, cost, saved telemetry queries
```

The two applications are snapshots of sibling repositories, vendored here without their git
history so that this repository builds, tests and deploys end to end on its own.

## Running locally

```bash
dotnet test                                  # API suite, no external dependencies
dotnet run --project src/LibrarySystem.Api
```

```bash
cd src/web
npm ci
npm run dev      # proxies /api to the API, so no CORS configuration is needed locally
npm test
```

## Deploying

The pipeline runs on a push to `main`. Every step it performs is also runnable locally, against
real Azure, which is how it was developed:

```powershell
$env:SQL_ADMIN_PASSWORD = '<the SQL administrator password>'
./scripts/deploy.ps1
```

That performs the same sequence as the workflow, in the same order: deploy the infrastructure,
apply database migrations behind a temporary firewall rule, publish and deploy the API, build the
SPA against the API's hostname and deploy it, then smoke test the result. The smoke test is
literally the same script the pipeline runs.

A pipeline that can only be debugged by pushing to it is a bad pipeline.

## Verified

- `/health` returns `Healthy`. The check includes a `DbContext` probe, so that response alone
  establishes the API reached Azure SQL rather than merely that the process is alive.
- `/api/books` returns the five seeded books from Azure SQL.
- Borrowing and returning a book through the deployed site works. That one flow exercises CORS,
  the build-time API URL, the Key Vault reference, the managed identity, and database writes at
  once.
- `az webapp config appsettings list` shows the connection string as
  `@Microsoft.KeyVault(VaultName=...;SecretName=...)`, and the password appears in no setting.
- Application Insights shows request volume and latency, failures split by result code, and
  dependency calls through to SQL. The saved queries are in [`docs/kql/`](docs/kql).
- A deployment slot was created on a temporarily upscaled plan, deployed to, swapped into
  production, and the plan returned to its free tier — one parameter each way.

## Cost

The project runs on always-free tiers: an F1 App Service plan and an Azure SQL database on the
free offer, configured to pause rather than bill when its monthly allowance is spent. A
subscription budget alerts at 50% and 90% as a backstop. The only deliberate spend was about
twelve minutes at Standard tier to demonstrate deployment slots, which the free tier does not
support. Details in [`docs/cost.md`](docs/cost.md).

The environment is torn down when it is not being shown, and rebuilt from the templates in one
command:

```powershell
./scripts/teardown.ps1
```

Teardown deletes the resource group, which also deletes the pipeline's role assignments, since
they are scoped to it. Recreate the group and those assignments before the next pipeline run —
see [`docs/architecture.md`](docs/architecture.md#the-bootstrap-and-what-teardown-takes-with-it).

## Known limitations

Recorded rather than glossed over:

- **The database uses SQL authentication**, which is why one secret has to exist at all.
  Passwordless Entra authentication from the API's managed identity would remove it entirely. It
  needs an Entra admin on the logical server and DDL grants issued to the identity — the honest
  next step for this design.
- **The database has a public endpoint**, restricted by firewall to the API app's possible
  outbound addresses. That allow-list verifiably blocks clients on the public internet — but
  testing showed it is *not* what grants the App Service its access: with every rule deleted, the
  API still read rows while an external client was refused. Same-region traffic evidently arrives
  over an internal path the public-endpoint rules do not govern. VNet integration with a private
  endpoint is therefore not just the better answer but the only one whose behaviour is fully
  explained; it requires Standard tier or better and so is out of reach on F1.
- **Key Vault purge protection is off**, deliberately, because this environment is built to be
  destroyed and rebuilt and a protected vault holds its name for the whole soft-delete retention
  period. For anything long-lived it should be on. The reasoning is in
  [`infra/README.md`](infra/README.md).
- **A slot swap is very nearly zero-downtime, not exactly.** Measured across a swap: about five
  seconds of disruption with no warm-up path configured.
