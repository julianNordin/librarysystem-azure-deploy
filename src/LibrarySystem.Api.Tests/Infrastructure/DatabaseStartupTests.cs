using LibrarySystem.Api.Data;
using Microsoft.EntityFrameworkCore;
using LibrarySystem.Api.Tests.TestHelpers;
using Xunit;

namespace LibrarySystem.Api.Tests.Infrastructure;

public class DatabaseStartupTests
{
    [Fact]
    public void Initialize_SeedsData_WhenMigrateOnStartupIsDisabled()
    {
        using var db = TestDbContextFactory.Create();

        DatabaseStartup.Initialize(db, migrateOnStartup: false);

        // Seeding is deliberately not gated by the migration switch: in Azure the schema is
        // the pipeline's job, but the demo data still has to appear.
        Assert.Equal(5, db.Books.Count());
    }

    [Fact]
    public void Initialize_SeedsData_WhenMigrateOnStartupIsEnabled()
    {
        using var db = TestDbContextFactory.Create();

        DatabaseStartup.Initialize(db, migrateOnStartup: true);

        Assert.Equal(5, db.Books.Count());
    }

    [Fact]
    public void Initialize_IsIdempotent()
    {
        using var db = TestDbContextFactory.Create();

        DatabaseStartup.Initialize(db, migrateOnStartup: false);
        DatabaseStartup.Initialize(db, migrateOnStartup: false);

        Assert.Equal(5, db.Books.Count());
    }

    [Theory]
    [InlineData(true, true, true)]
    [InlineData(true, false, false)]
    [InlineData(false, true, false)]
    [InlineData(false, false, false)]
    public void ShouldMigrate_RequiresBothARelationalProviderAndTheEnabledSetting(
        bool isRelational,
        bool migrateOnStartup,
        bool expected)
    {
        Assert.Equal(expected, DatabaseStartup.ShouldMigrate(isRelational, migrateOnStartup));
    }
    [Fact]
    public void Initialize_DoesNotThrow_WhenTheDatabaseCannotBeReached()
    {
        // A SQL Server context pointed at an address that cannot answer, with a one second
        // connect timeout so the test fails fast rather than hanging. This reproduces what a
        // serverless database resuming from auto-pause looks like to an application that is
        // starting up.
        //
        // The application must survive it. Seeding runs during host startup, and an exception
        // there kills the process before it can serve anything - so a database that is briefly
        // unavailable takes the whole site down and keeps it down until something restarts it,
        // rather than causing one slow request.
        var options = new DbContextOptionsBuilder<AppDbContext>()
            .UseSqlServer("Server=tcp:127.0.0.1,1;Initial Catalog=nonexistent;User ID=none;Password=none;Connect Timeout=1;Encrypt=False;TrustServerCertificate=True;")
            .Options;

        using var db = new AppDbContext(options);

        var exception = Record.Exception(() => DatabaseStartup.Initialize(db, migrateOnStartup: false));

        Assert.Null(exception);
    }
}
