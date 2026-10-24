using System.Net;
using System.Text.Json;
using DevOpsLab.IntegrationTests.Infrastructure;
using Xunit;

namespace DevOpsLab.IntegrationTests.Api;

[Collection(ApiCollection.Name)]
public class HealthEndpointTests : IAsyncLifetime
{
    private readonly ApiFactory _factory;

    public HealthEndpointTests(ApiFactory factory) => _factory = factory;

    // xUnit runs these before and after every test in this class.
    public Task InitializeAsync() => _factory.ResetAsync();
    public Task DisposeAsync() => Task.CompletedTask;

    [Fact]
    public async Task Liveness_ReturnsHealthy_AndOnlyContainsTheSelfCheck()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/healthz/live");
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        using var document = JsonDocument.Parse(body);
        Assert.Equal("Healthy", document.RootElement.GetProperty("status").GetString());

        var checks = document.RootElement.GetProperty("checks").EnumerateArray().ToList();
        Assert.Single(checks);
        Assert.Equal("self", checks[0].GetProperty("name").GetString());
    }

    [Fact]
    public async Task Readiness_ReturnsHealthy_AndOnlyContainsTheDatabaseCheck()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync("/healthz/ready");
        var body = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        using var document = JsonDocument.Parse(body);
        var checks = document.RootElement.GetProperty("checks").EnumerateArray().ToList();
        Assert.Single(checks);
        Assert.Equal("database", checks[0].GetProperty("name").GetString());
    }
}