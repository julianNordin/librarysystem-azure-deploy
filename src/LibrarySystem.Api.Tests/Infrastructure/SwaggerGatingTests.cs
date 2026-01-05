using System.Net;
using LibrarySystem.Api.Tests.TestHelpers;
using Microsoft.AspNetCore.Hosting;
using Xunit;

namespace LibrarySystem.Api.Tests.Infrastructure;

public class SwaggerGatingTests : IClassFixture<LibrarySystemApiFactory>
{
    private readonly LibrarySystemApiFactory _factory;

    public SwaggerGatingTests(LibrarySystemApiFactory factory)
    {
        _factory = factory;
    }

    private HttpClient CreateClientWithSwagger(string enabled) =>
        _factory
            .WithWebHostBuilder(builder => builder.UseSetting("Swagger:Enabled", enabled))
            .CreateClient();

    [Fact]
    public async Task SwaggerDocument_IsServed_WhenEnabled()
    {
        var client = CreateClientWithSwagger("true");

        var response = await client.GetAsync("/swagger/v1/swagger.json");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task SwaggerDocument_IsNotServed_WhenDisabled()
    {
        var client = CreateClientWithSwagger("false");

        var response = await client.GetAsync("/swagger/v1/swagger.json");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
