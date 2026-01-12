using './main.bicep'

param environmentName = 'dev'
param appServicePlanSku = 'F1'

// Read from the environment at deployment time, so the secret exists in this file only as the
// name of a variable. A .bicepparam must assign every parameter that has no default, so an
// inline -p on the command line cannot fill this gap - and a command line argument would leak
// into shell history and the process list anyway. Locally this comes from an untracked env
// file; in the pipeline it comes from a GitHub secret exported for the step.
param sqlAdministratorLoginPassword = readEnvironmentVariable('SQL_ADMIN_PASSWORD')
