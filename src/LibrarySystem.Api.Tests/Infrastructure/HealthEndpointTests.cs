using System.Net;
using LibrarySystem.Api.Tests.TestHelpers;
using Xunit;

namespace LibrarySystem.Api.Tests.Infrastructure;

public class HealthEndpointTests : IClassFixture<LibrarySystemApiFactory>
{
    private readonly HttpClient _client;

    public HealthEndpointTests(LibrarySystemApiFactory factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task Health_ReturnsOk()
    {
        var response = await _client.GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Health_ReportsHealthy()
    {
        var response = await _client.GetAsync("/health");

        var body = await response.Content.ReadAsStringAsync();
        Assert.Equal("Healthy", body);
    }
}
