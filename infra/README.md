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
