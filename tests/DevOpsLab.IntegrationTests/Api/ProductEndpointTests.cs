using System.Net;
using System.Net.Http.Json;
using DevOpsLab.Application.Common;
using DevOpsLab.Application.Products;
using DevOpsLab.IntegrationTests.Infrastructure;
using Xunit;

namespace DevOpsLab.IntegrationTests.Api;

[Collection(ApiCollection.Name)]
public class ProductEndpointTests : IAsyncLifetime
{
    private readonly ApiFactory _factory;

    public ProductEndpointTests(ApiFactory factory) => _factory = factory;

    // xUnit runs these before and after every test in this class.
    public Task InitializeAsync() => _factory.ResetAsync();
    public Task DisposeAsync() => Task.CompletedTask;

    [Fact]
    public async Task ListProducts_ReturnsSeededCatalog()
    {
        var client = _factory.CreateClient();

        var result = await client.GetFromJsonAsync<PagedResult<ProductResponse>>("/api/products");

        Assert.NotNull(result);
        Assert.True(result!.TotalCount >= 5);
    }

    [Fact]
    public async Task GetProduct_WithUnknownId_ReturnsNotFound()
    {
        var client = _factory.CreateClient();

        var response = await client.GetAsync($"/api/products/{Guid.NewGuid()}");

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task CreateProduct_WithInvalidPrice_ReturnsBadRequestWithRule()
    {
        var client = _factory.CreateClient();
        var list = await client.GetFromJsonAsync<PagedResult<ProductResponse>>("/api/products");
        var categoryId = list!.Items[0].CategoryId;

        var response = await client.PostAsJsonAsync("/api/products",
            new CreateProductRequest(categoryId, "NEG-001", "Invalid price", -5m, 1));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        var problem = await response.Content.ReadFromJsonAsync<Dictionary<string, object>>();
        Assert.NotNull(problem);
        Assert.True(problem!.ContainsKey("rule"));
    }

    [Fact]
    public async Task ReserveStock_BeyondAvailability_ReturnsBadRequest()
    {
        var client = _factory.CreateClient();
        var list = await client.GetFromJsonAsync<PagedResult<ProductResponse>>("/api/products");
        var product = list!.Items[0];

        var response = await client.PostAsJsonAsync(
            $"/api/products/{product.Id}/reserve",
            new ReserveStockRequest(product.StockQuantity + 1_000));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}