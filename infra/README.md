# Infrastructure

`main.bicep` composes the whole environment at resource-group scope. `main.bicepparam` supplies
its parameters.

## Working with it

```bash
az bicep build --file infra/main.bicep
az deployment group what-if -g rg-librarysystem-dev -f infra/main.bicep -p infra/main.bicepparam
az deployment group create  -g rg-librarysystem-dev -f infra/main.bicep -p infra/main.bicepparam
```

Run `what-if` before every deployment. It is the only cheap way to see what a template is about
to do to an environment that already exists.

## what-if reports App Service site configuration as new on every run

A no-op redeploy still shows the site resource as modified, listing `netFrameworkVersion`,
`healthCheckPath`, `ftpsState` and `minTlsVersion` as additions:

```
~ Microsoft.Web/sites/app-librarysystem-api-...
  + properties.siteConfig.ftpsState:           "Disabled"
  + properties.siteConfig.healthCheckPath:     "/health"
  + properties.siteConfig.localMySqlEnabled:   false
  + properties.siteConfig.minTlsVersion:       "1.2"
  + properties.siteConfig.netFrameworkVersion: "v9.0"
```

**This is noise, not drift.** Those properties live on the site's `config/web` child resource,
and a GET on the site itself does not return them, so what-if compares the template against a
blank and concludes they are being added. The tell is `localMySqlEnabled`, which appears in the
list despite never being set by this template at all — it is the API's own default surfacing,
not something the deployment is about to change.

The values really are applied. Confirm directly rather than trusting the preview:

```bash
az webapp config show -n <api app name> -g rg-librarysystem-dev \
  --query '{netFrameworkVersion:netFrameworkVersion, healthCheckPath:healthCheckPath, ftpsState:ftpsState, minTlsVersion:minTlsVersion}'
```

what-if prints its own warning about false positives above the diff. Moving `siteConfig` out
into a separate `Microsoft.Web/sites/config` resource would make the preview accurate, at the
cost of splitting one resource into two and ordering them; that trade is not worth it here, but
it is the fix if the noise ever hides something real.

## Idempotency

Deploying twice in a row is expected to succeed both times and change nothing the second time.
The plan resource correctly reports `NoChange`; the site reports the false positive above.

## Key Vault soft delete, and why purge protection is deliberately off

Soft delete is enabled with the minimum 7-day retention. Purge protection is **not** enabled,
and that is a deliberate decision rather than an oversight.

The vault's name is derived from `uniqueString(resourceGroup().id)`, so tearing the environment
down and rebuilding it into a resource group of the same name produces **the same vault name**.
A soft-deleted vault still owns its name for the whole retention period, so the rebuild collides
with its own predecessor and fails with a name-in-use error that looks nothing like the actual
cause.

With purge protection off, the deleted vault can be purged and the name released immediately,
which is what the teardown script does:

```bash
az keyvault purge --name <vault name> --location swedencentral
```

With purge protection **on**, that command is refused by design — a protected vault cannot be
purged before its retention expires, by anyone, including the subscription owner. Recreating the
name would then require `createMode: 'recover'` in the template, which resurrects the old vault
and its old secrets instead of creating a clean one.

For anything real, purge protection should be on: it is exactly the control that stops an
attacker, or a mistake, from destroying secrets irrecoverably. It is off here because this
environment's whole purpose is to be destroyed and rebuilt on demand, and those two goals are
genuinely in conflict. The trade is recorded rather than hidden.

## Removing a resource from the template does not delete it

Deployments here run in **incremental** mode, which is the default and the right choice. It adds
and updates what the template describes and *leaves everything else alone* — including resources
the template used to declare and no longer does.

Replacing the broad allow-Azure-services firewall rule with per-address rules demonstrated this
exactly: the new rules appeared, the old rule stayed, and the server ended up with both. The
narrowing had visibly "worked" while the thing being narrowed was still in place.

Removed resources have to be deleted explicitly:

```bash
az sql server firewall-rule delete -g rg-librarysystem-dev -s <server> -n AllowAzureServices
```

Complete-mode deployment would delete them automatically, and would also delete anything else in
the resource group that the template does not describe. That is a far larger blast radius than
this buys.

## The SQL firewall lists possible outbound addresses, not current ones

The rules are generated from the API app's `possibleOutboundIpAddresses`, not
`outboundIpAddresses`. The second is only the handful currently in use; App Service moves an app
between the addresses in the first set without notice, so a firewall pinned to today's addresses
fails intermittently, later, for no visible reason.

**Changing the plan's tier can change the set itself.** The slot phase scales to S1 and back, so
it must redeploy the template rather than assume the existing rules still cover the app.

The genuinely correct design is VNet integration with a private endpoint, leaving the database
with no public surface at all. That requires Standard tier or better, so it is out of reach on F1
and is recorded as further work rather than pretended away.

## Basic publishing credentials are disabled, and deployment still works

`scm` and `ftp` basic authentication are off on both apps, so a username and password can no
longer deploy code. `az webapp deploy` continues to work because it authenticates with the Entra
token from `az login` rather than with basic auth — which is the same mechanism the pipeline's
federated credential uses, and the reason turning this off costs nothing here.
