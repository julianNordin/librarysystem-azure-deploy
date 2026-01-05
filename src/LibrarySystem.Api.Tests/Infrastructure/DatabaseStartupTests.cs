using LibrarySystem.Api.Data;
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
}
