using Microsoft.EntityFrameworkCore;

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

    public static void Initialize(AppDbContext context, bool migrateOnStartup)
    {
        var isRelational = context.Database.IsRelational();

        if (ShouldMigrate(isRelational, migrateOnStartup))
        {
            context.Database.Migrate();
        }
        else if (!isRelational)
        {
            // The InMemory provider has no migrations to apply. The test suite depends on this
            // branch, so it stays regardless of the migration setting.
            context.Database.EnsureCreated();
        }

        // Not gated by migrateOnStartup: the schema may be the pipeline's responsibility, but
        // the demo data still needs to appear. DbInitializer returns early when data exists.
        DbInitializer.Initialize(context);
    }
}
