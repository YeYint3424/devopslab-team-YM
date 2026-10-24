using DevOpsLab.Domain.Entities;
using DevOpsLab.Infrastructure.Persistence;
using DevOpsLab.IntegrationTests.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace DevOpsLab.IntegrationTests.Database;

/// <summary>
/// Each test bypasses ProductService AND the domain checks and asks the
/// database itself to enforce a rule.
/// </summary>
[Collection(ApiCollection.Name)]
public class DatabaseConstraintTests : IAsyncLifetime
{
    private readonly ApiFactory _factory;

    public DatabaseConstraintTests(ApiFactory factory) => _factory = factory;

    public Task InitializeAsync() => _factory.ResetAsync();
    public Task DisposeAsync() => Task.CompletedTask;

    // A fresh DbContext straight from the API's DI container - no service, no HTTP.
    private AppDbContext NewContext(out IServiceScope scope)
    {
        scope = _factory.Services.CreateScope();
        return scope.ServiceProvider.GetRequiredService<AppDbContext>();
    }

    [Fact]
    public async Task Database_RejectsDuplicateSku()
    {
        var db = NewContext(out var scope); using var _ = scope;
        var categoryId = await db.Categories.Select(c => c.Id).FirstAsync();

        db.Products.Add(Product.Create(categoryId, "DUP-001", "First", 10m, 1));
        await db.SaveChangesAsync();

        db.Products.Add(Product.Create(categoryId, "DUP-001", "Second", 20m, 2));

        await Assert.ThrowsAnyAsync<DbUpdateException>(() => db.SaveChangesAsync());
    }

    [Fact]
    public async Task Database_RejectsNameLongerThanTheColumn()
    {
        var db = NewContext(out var scope); using var _ = scope;
        var categoryId = await db.Categories.Select(c => c.Id).FirstAsync();

        var product = Product.Create(categoryId, "LONG-001", "Valid name", 10m, 1);
        db.Products.Add(product);
        db.Entry(product).Property(p => p.Name).CurrentValue =
            new string('A', Product.NameMaxLength + 100);

        await Assert.ThrowsAnyAsync<DbUpdateException>(() => db.SaveChangesAsync());
    }

    [Fact]
    public async Task Database_RejectsProductWithUnknownCategory()
    {
        var db = NewContext(out var scope); using var _ = scope;

        db.Products.Add(Product.Create(Guid.NewGuid(), "ORPHAN-001", "Orphan", 10m, 1));

        await Assert.ThrowsAnyAsync<DbUpdateException>(() => db.SaveChangesAsync());
    }
}