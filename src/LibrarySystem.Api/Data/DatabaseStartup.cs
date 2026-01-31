using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace LibrarySystem.Api.Data;

public static class DatabaseStartup
{
    /// <summary>
    /// Whether the application should apply migrations as it boots.
    /// </summary>
    /// <remarks>
    /// Migrating at startup races when more than one instance boots at once, and it requires the
    /// application's own identity to hold DDL rights at runtime. In Azure the deploy pipeline
    /// owns the schema instead, so the setting is false there and true locally, where a single
    /// developer instance applying its own migrations is the convenient thing.
    /// </remarks>
    public static bool ShouldMigrate(bool isRelational, bool migrateOnStartup) =>
        isRelational && migrateOnStartup;

    public static void Initialize(AppDbContext context, bool migrateOnStartup, ILogger? logger = null)
    {
        try
        {
            var isRelational = context.Database.IsRelational();

            if (ShouldMigrate(isRelational, migrateOnStartup))
            {
                context.Database.Migrate();
            }
            else if (!isRelational)
            {
                // The InMemory provider has no migrations to apply. The test suite depends on
                // this branch, so it stays regardless of the migration setting.
                context.Database.EnsureCreated();
            }

            // Not gated by migrateOnStartup: the schema may be the pipeline's responsibility, but
            // the demo data still needs to appear. DbInitializer returns early when data exists -
            // though note that even the early return costs a query, which is why all of this is
            // inside the try below.
            DbInitializer.Initialize(context);
        }
        catch (Exception ex)
        {
            // Deliberately not rethrown, and this is the important part.
            //
            // Everything above touches the database, and an exception during host startup kills
            // the process. That turns a database which is *briefly* unavailable into a site that
            // is down and stays down until something restarts it - because every subsequent
            // request gets a startup failure rather than a retry.
            //
            // On the serverless tier the database is briefly unavailable by design: it pauses
            // after an idle period and takes time to resume. Left unhandled, an hour of no
            // traffic is enough to take the API offline permanently.
            //
            // Nothing is concealed by swallowing this. /health includes a DbContext check, so an
            // application that genuinely cannot reach its database still reports unhealthy - to
            // App Service's health probe and to the deploy pipeline's smoke test. Deciding that
            // the application is dead is the health check's job, not startup's.
            logger?.LogError(
                ex,
                "Database initialisation failed during startup. The application will start anyway; /health reports unhealthy until the database is reachable.");
        }
    }
}
