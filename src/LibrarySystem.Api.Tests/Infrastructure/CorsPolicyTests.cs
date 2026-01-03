using LibrarySystem.Api.Tests.TestHelpers;
using Microsoft.AspNetCore.Hosting;
using Xunit;

namespace LibrarySystem.Api.Tests.Infrastructure;

public class CorsPolicyTests : IClassFixture<LibrarySystemApiFactory>
{
    // Deliberately not a real hostname. The deployed origin is supplied by Bicep at
    // deployment time; the policy under test is that the API honours whatever it is given.
    private const string AllowedOrigin = "https://app-librarysystem-web.example.net";

    private readonly LibrarySystemApiFactory _factory;

    public CorsPolicyTests(LibrarySystemApiFactory factory)
    {
        _factory = factory;
    }

    // Cors:AllowedOrigins is an array in configuration, so the indexed key is what an
    // environment variable or an App Service setting would supply: Cors__AllowedOrigins__0.
    private HttpClient CreateClientAllowing(string origin) =>
        _factory
            .WithWebHostBuilder(builder => builder.UseSetting("Cors:AllowedOrigins:0", origin))
            .CreateClient();

    [Fact]
    public async Task Preflight_FromConfiguredOrigin_IsAllowed()
    {
        var client = CreateClientAllowing(AllowedOrigin);

        var request = new HttpRequestMessage(HttpMethod.Options, "/api/books");
        request.Headers.Add("Origin", AllowedOrigin);
        request.Headers.Add("Access-Control-Request-Method", "GET");

        var response = await client.SendAsync(request);

        Assert.Equal(
            AllowedOrigin,
            Assert.Single(response.Headers.GetValues("Access-Control-Allow-Origin")));
    }

    [Fact]
    public async Task Preflight_FromUnknownOrigin_IsNotAllowed()
    {
        var client = CreateClientAllowing(AllowedOrigin);

        var request = new HttpRequestMessage(HttpMethod.Options, "/api/books");
        request.Headers.Add("Origin", "https://not-the-app.example.net");
        request.Headers.Add("Access-Control-Request-Method", "GET");

        var response = await client.SendAsync(request);

        Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
    }

    [Fact]
    public async Task ActualRequest_FromConfiguredOrigin_CarriesAllowOriginHeader()
    {
        var client = CreateClientAllowing(AllowedOrigin);

        var request = new HttpRequestMessage(HttpMethod.Get, "/api/books");
        request.Headers.Add("Origin", AllowedOrigin);

        var response = await client.SendAsync(request);

        response.EnsureSuccessStatusCode();
        Assert.Equal(
            AllowedOrigin,
            Assert.Single(response.Headers.GetValues("Access-Control-Allow-Origin")));
    }
}
