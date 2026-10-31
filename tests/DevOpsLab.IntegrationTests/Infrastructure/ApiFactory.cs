using DevOpsLab.Infrastructure.Persistence;
using DotNet.Testcontainers.Builders;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Testcontainers.MsSql;
using Xunit;

namespace DevOpsLab.IntegrationTests.Infrastructure;

/// <summary>
/// Boots the real API pipeline in memory.
///
/// TODO (Session 4): replace the in-memory provider below with Testcontainers so
/// that integration tests run against a real SQL Server, identically on a
/// developer laptop and on the CI runner. The in-memory provider does not enforce
/// relational constraints and therefore hides an entire class of defects.
/// </summary>
public sealed class ApiFactory : WebApplicationFactory<Program>, IAsyncLifetime
{
    private readonly MsSqlContainer _database = new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")
        .WithPassword("Your_strong_Passw0rd")
        // Do NOT report the container as started until SQL Server actually
        // answers a query. Running is not ready - the same distinction as
        // /healthz/live vs /healthz/ready from Session 1.
        .WithWaitStrategy(Wait.ForUnixContainer().UntilCommandIsCompleted(
            "/opt/mssql-tools18/bin/sqlcmd", "-C", "-Q", "SELECT 1"))
        .WithCleanUp(true)
        .Build();

    public async Task InitializeAsync()
    {
        await _database.StartAsync();

        // Apply the REAL migrations. A broken migration now fails your test
        // suite instead of production (you will care about this in Session 10).
        using var scope = Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
        await db.Database.MigrateAsync();

        // The app runs as Production here, so Program.cs skips seeding - do it explicitly.
        var loggerFactory = scope.ServiceProvider.GetRequiredService<ILoggerFactory>();
        await DatabaseSeeder.SeedAsync(db, loggerFactory.CreateLogger("TestSeed"));
    }

    public new async Task DisposeAsync()
    {
        await _database.DisposeAsync();
        await base.DisposeAsync();
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(Environments.Production);
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<DbContextOptions<AppDbContext>>();
            services.RemoveAll<AppDbContext>();
            services.AddDbContext<AppDbContext>(o =>
                o.UseSqlServer(_database.GetConnectionString()));
        });
    }
}
