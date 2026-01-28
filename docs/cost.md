# Cost

This project is built to run at zero cost and to be torn down when it is not being shown. This
file records what is free, what the limits actually are, and the one thing that is not free.

## Azure SQL Database — free offer

The database uses the free offer, which is **one database per subscription**. That single-instance
limit dictates ordering elsewhere: a hand-built database has to be gone before the templates
create theirs, or the deployment fails on a quota that has nothing to do with the template.

| Allowance | Amount |
|---|---|
| Compute | 100,000 vCore-seconds per month |
| Storage | 32 GB |

Configured as `GP_S_Gen5_2` serverless, minimum capacity 0.5 vCores, auto-pause after 60 minutes
of inactivity, locally redundant backups.

`freeLimitExhaustionBehavior` is set to **`AutoPause`**. When the monthly allowance runs out the
database stops until the month rolls over. The alternative, `BillOverage`, keeps it serving and
starts charging — which is the correct choice for something real and the wrong one for a
portfolio project that should never be able to generate a bill.

Verify the offer actually applied rather than assuming it did. A database created without the
free-limit flags looks identical until an invoice arrives:

```bash
az sql db show -g rg-librarysystem-dev -s <server> -n sqldb-librarysystem \
  --query '{useFreeLimit:useFreeLimit, exhaustion:freeLimitExhaustionBehavior}'
```

### Consequences worth expecting

Auto-pause is not free of side effects. After an idle period the first request pays a resume
delay of several seconds, stacked on top of the App Service cold start below. A health check or
a smoke test hitting a cold environment needs a timeout generous enough to survive both.

## App Service — F1 (Free)

| Limit | Value |
|---|---|
| Compute | 60 CPU-minutes per day |
| Always On | not available, so the app cold-starts after idling |
| Deployment slots | **none** |
| Custom domains / TLS | not available |

Both applications share one plan. That costs the same as running one and is the reason the
topology has two App Services rather than serving the SPA from the API.

The absence of slots on F1 is why demonstrating a slot swap requires temporarily scaling the
plan up.

## The one real cost

Deployment slots need Standard tier or better. The slot phase sets the plan SKU parameter to
`S1`, deploys, creates a staging slot, swaps it into production, and **returns the parameter to
F1 in the same session**. S1 bills by the hour, so the cost is the length of that session rather
than a month of Standard.

Because the whole tier is one template parameter, scaling up and back down is a parameter change
and a redeploy — which is the actual point being demonstrated.

## Not accruing anything

The environment is deleted when it is not being demonstrated, and rebuilt from the templates in
one command when it is. After teardown, confirm nothing survives:

```bash
az group show -g rg-librarysystem-dev     # expected to fail: group not found
az resource list --query "[?resourceGroup=='rg-librarysystem-dev']"
```

A subscription budget with alert thresholds is configured as a backstop, so that a mistake
surfaces as a notification rather than as a surprise at the end of the month.

## What the slot demonstration actually cost

The plan was scaled to S1, a staging slot created and deployed to, swapped into production, the
slot deleted, and the plan returned to F1 — all in one session, about **twelve minutes at
Standard tier**. App Service bills by the hour but meters below it, so the charge is roughly a
fifth of one S1 hour. Confirm the exact figure in Cost analysis rather than trusting an estimate
here; hourly rates are regional and change.

Everything else in the project ran on always-free SKUs throughout.

The scale up and the scale down were each a single parameter in `main.bicepparam` plus a
redeploy, which is the actual thing being demonstrated: tier is a property of the description of
the system, not a manual operation performed on it.
