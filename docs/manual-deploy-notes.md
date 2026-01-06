# Manual deployment notes

The environment was first built by hand, once, before any of it was written as infrastructure
as code. This file records what was created and why, so that the Bicep in `infra/` has a spec to
be checked against rather than being written from memory.

Nothing here is a transcript. Commands and outputs are described rather than pasted.

## Resource group

A single resource group in **Sweden Central**, chosen because both requirements verified there:
the F1 App Service tier is offered, and so is `GP_S_Gen5_2`, the serverless objective the free
SQL offer requires. `westeurope` was the documented fallback and was not needed.

The hand-built group is named separately from the one the Bicep uses. It is deleted before the
first Bicep deployment rather than being adopted: deploying a template over hand-created
resources fights their property defaults and produces confusing diffs, which is a poor first
lesson in what infrastructure as code is for.

## App Service plan

F1 (Free), **Windows**.

Windows rather than Linux because a single plan cannot mix the two, and the SPA that joins this
plan later is served most simply by IIS with a small rewrite rule. On Linux the same job needs a
Node process running purely to serve static files.

> **The CLI defaults to Linux.** `az appservice plan create` documents `--is-linux` as defaulting
> to *true*, so omitting the flag produces a Linux plan, silently, with a `LinuxFree` SKU. The web
> app creation then fails with "Linux Runtime 'dotnet|9' is not supported", which points at the
> runtime rather than at the plan that actually caused it. Pass `--is-linux false` explicitly.
> The template equivalent is leaving `reserved` false on the server farm.

F1's limits that matter later: 60 CPU-minutes per day, no Always On (so cold starts are normal),
and **no deployment slots** — which is why the slot demonstration has to scale the plan up
temporarily and then back down.

## API web app

Created on that plan with runtime `dotnet|9`. Reading the site configuration back afterwards
shows `netFrameworkVersion` as **`v9.0`**, which is the value the Bicep must set — the CLI's
`dotnet|9` is a CLI-level shorthand and is not what the resource stores.

The default hostname came back as the plain `<name>.azurewebsites.net` form. The Bicep should
still publish `properties.defaultHostName` as an output rather than building that string itself:
the unique-default-hostname feature can append a suffix, and anything that concatenates the name
by hand breaks silently when it does.

Settings applied by hand, both of which the Bicep will own:

- `ConnectionStrings__DefaultConnection` — the full connection string, **in plain text**. This is
  the thing the Key Vault phase exists to remove; it is recorded here as the starting point, not
  as an acceptable end state.
- `Database__MigrateOnStartup=true` — so this first deployment creates its own schema. The
  application defaults this to false in Production precisely so that the pipeline can own
  migrations later; overriding it here is what makes a one-shot manual deploy work at all.

Not configured by hand, and deliberately left for the Bicep to introduce so that the difference
is visible: `httpsOnly`, `ftpsState`, `minTlsVersion`, and `healthCheckPath`.

## SQL logical server and database

A logical server with SQL authentication, then a database created as:

- edition `GeneralPurpose`, compute model `Serverless`, family `Gen5`, capacity 2 — together the
  `GP_S_Gen5_2` objective
- `--use-free-limit` with `--free-limit-exhaustion-behavior AutoPause`
- auto-pause delay of 60 minutes
- locally redundant backup storage

Reading the database back confirms `useFreeLimit: true` and `freeLimitExhaustionBehavior:
AutoPause`, which is the only reliable way to know the free offer actually applied rather than
having been silently ignored.

**The free offer is one database per subscription.** That constrains the order of everything
that follows: the hand-built database must be gone before the Bicep creates its own, or the
deployment fails on a quota that has nothing to do with the template being wrong.

Auto-pause has a visible consequence worth expecting: after an idle period the first request
pays a resume delay, on top of F1's own cold start.

## Firewall

One rule allowing Azure services, expressed as the `0.0.0.0` to `0.0.0.0` sentinel range rather
than as a literal address. It is broad — it admits any Azure tenant, not only this subscription —
and the security phase replaces it with the API app's own outbound addresses. It is used here
because it is the smallest thing that makes the first deploy work.

## Deploying the code

`dotnet publish -c Release` into a directory, that directory zipped, and the zip pushed with
`az webapp deploy --type zip`.

## What this proved

`/health` returned `Healthy`, and because the health check includes a `DbContext` probe, that
response alone establishes the application reached Azure SQL. `/api/books` returned the five
seeded books, confirming the schema was created on startup and the seeder ran.

## What the Bicep has to encode

Everything above, plus the four settings deliberately skipped by hand:

| Property | Value |
|---|---|
| `netFrameworkVersion` | `v9.0` |
| `healthCheckPath` | `/health` |
| `httpsOnly` | true |
| `ftpsState` | `Disabled` |
| `minTlsVersion` | `1.2` |
| server farm `reserved` | false, for Windows |
| database | `GP_S_Gen5_2`, `useFreeLimit`, `AutoPause` |

and it must output the API's `defaultHostName`, because the SPA build and the CORS policy both
need it and neither may construct it by hand.
