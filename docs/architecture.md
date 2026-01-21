# Architecture

## Topology

One resource group holds everything. Two App Services share a single Windows plan: the API and
the SPA. A logical SQL server hosts one serverless database on the free offer. A Key Vault holds
the database connection string. A Log Analytics workspace backs an Application Insights
component that the API reports to.

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

Both apps sit on one plan because a plan is what is billed: a second app on it is free, and two
apps means two origins, which forces the CORS policy to be real rather than theoretical.

The plan is Windows. A plan cannot host both Windows and Linux apps, and serving the SPA needs
either IIS with a rewrite rule (Windows, two lines of configuration) or a Node process whose
only job is to serve static files (Linux). The first is less machinery.

## How the pipeline authenticates

The deploy workflow authenticates to Azure with **OIDC federated credentials**. No credential is
stored in GitHub at all.

The exchange works like this. GitHub mints a short-lived JSON Web Token describing the workflow
run — which repository, which branch, which event. `azure/login` presents that token to Entra ID.
Entra checks it against a *federated credential* registered on the app registration, which pins
the issuer, the audience, and above all the **subject**:

```
repo:<owner>/<repo>:ref:refs/heads/main
```

If the subject matches, Entra issues a normal access token. If a workflow runs on a different
branch, in a fork, or in some other repository, the subject does not match and no token is
issued.

Three values identify the target and live as repository **variables**, not secrets:

| Variable | What it is |
|---|---|
| `AZURE_CLIENT_ID` | the app registration's application id |
| `AZURE_TENANT_ID` | the directory the app lives in |
| `AZURE_SUBSCRIPTION_ID` | the subscription to deploy into |

None of them is a credential. They identify *which* identity to attempt to become; they grant
nothing on their own, and possessing all three gets an attacker precisely nowhere without a token
GitHub will only mint for a run in this repository on this branch.

### Why this beats a stored service principal secret

The alternative is `AZURE_CREDENTIALS`: a JSON blob containing a client secret, pasted into a
GitHub secret. It is the older, more common pattern, and it is worse in every dimension.

| | Stored secret | Federated credential |
|---|---|---|
| A long-lived credential exists | yes — in Entra and in GitHub | **no** |
| Value if exfiltrated | usable from anywhere until revoked | nothing to exfiltrate |
| Expiry | secrets expire; the pipeline breaks on a date nobody diarised | no secret, nothing to expire |
| Rotation | a manual chore in two systems | not applicable |
| Scope of trust | anyone holding the string | one repository, one branch |

The last row is the one that matters most and is the least obvious. A stored secret authenticates
*whoever presents it*. A federated credential authenticates *a specific workflow context*, and
that context is asserted by GitHub rather than by the caller. A leaked secret is an incident; a
leaked client id is a fact about your tenant.

Verify that no secret exists, rather than trusting that none was created:

```bash
az ad app credential list --id <app id> --query 'length(@)'   # expected: 0
az ad app federated-credential list --id <app id>
```

### Least privilege

The identity holds **Contributor on the resource group only** — never on the subscription. It can
build and destroy this environment and has no standing permission anywhere else in the tenant.

```bash
az role assignment list --assignee <app id> --all --query '[].{role:roleDefinitionName, scope:scope}'
```

The `--all` matters: without it the command reports only the current subscription's default
scope and would hide an assignment made higher up.

### The one secret that must exist

The SQL administrator password. It is a GitHub secret, exported as an environment variable for
the deployment step and read by `main.bicepparam` through `readEnvironmentVariable`, so it is
never written to a file and never passed as a command line argument.

It exists only because the database uses SQL authentication. Passwordless Entra authentication
from the app's managed identity to Azure SQL would remove it entirely, and is the honest next
step for this design — it needs an Entra admin on the logical server and DDL grants issued to the
managed identity, which is more setup than this project takes on. Recorded as further work rather
than quietly omitted.

### The line everyone forgets

OIDC needs the workflow to be allowed to request a token:

```yaml
permissions:
  id-token: write
  contents: read
```

Without `id-token: write` the login step fails with an error about being unable to get a token,
which reads like a configuration problem with the credential rather than a missing permission on
the job.

## Verifying a pipeline that cannot run

Until the repository has a remote, the workflows cannot execute, and OIDC in particular cannot be
tested locally at all — nothing outside GitHub can mint the token. "Done" is therefore defined
differently:

- **actionlint** over every workflow, which catches YAML and expression errors statically.
- **Every step run locally**, exactly as written, against real Azure. `scripts/deploy.ps1`
  performs the same sequence as the deploy workflow, so if the script succeeds the workflow's
  logic is sound and only the runner and the token exchange remain unproven.
- **The Azure half of OIDC is fully verifiable.** The app registration, the federated credential
  and the role assignment are Azure-side objects that can be created and inspected without
  GitHub, which is what the commands above do.

A pipeline that can only be debugged by pushing to it is a bad pipeline regardless, so having a
locally runnable equivalent is worth having on its own merits.
