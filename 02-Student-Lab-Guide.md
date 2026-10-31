# Session 4 — Student Lab Guide

## Lab 2 — Integration Tests, Smoke Test & Coverage Gate (5% of the course)

**Work in your squad. Every member runs every step on their own machine.**

Your integration tests have been green since Session 1. Today you find out what
they were actually testing.

There are **eight checkpoints**.

### Map of the files you will touch

All paths are relative to the root of your team repository.

| Step | File | Action |
|---|---|---|
| 2.1 | `tests/DevOpsLab.IntegrationTests/DevOpsLab.IntegrationTests.csproj` | **Edit** (via `dotnet` CLI) — swap packages |
| 2.2 | `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs` | **Replace** the whole file |
| 2.3 | `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiCollection.cs` | **Create** |
| 2.3 | `tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs` | **Edit** — class declaration only |
| 2.3 | `tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs` | **Edit** — class declaration only |
| 2.3 | `tests/DevOpsLab.IntegrationTests/xunit.runner.json` | **Create** |
| 2.3 | `tests/DevOpsLab.IntegrationTests/DevOpsLab.IntegrationTests.csproj` | **Edit** — copy the json to the output folder |
| 3 | `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs` | **Edit** — add `ResetAsync` |
| 3 | `tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs` | **Edit** — call `ResetAsync` |
| 3 | `tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs` | **Edit** — call `ResetAsync` |
| 4 | `tests/DevOpsLab.IntegrationTests/Database/DatabaseConstraintTests.cs` | **Create** (new folder `Database/`) |
| 4 | `ApiFactory.cs` + `.csproj` | **Temporary edit** for the experiment, then revert |
| 5 | `scripts/smoke-test.sh` | **Copy in** from the Session 4 course materials |
| 6 | `scripts/coverage-gate.sh`, `scripts/diff-coverage.sh` | **Copy in** from the Session 4 course materials |

When you finish, the integration test project looks like this:

```
tests/DevOpsLab.IntegrationTests/
├── Api/
│   ├── HealthEndpointTests.cs        (edited)
│   └── ProductEndpointTests.cs       (edited)
├── Database/
│   └── DatabaseConstraintTests.cs    (new)
├── Infrastructure/
│   ├── ApiCollection.cs              (new)
│   └── ApiFactory.cs                 (rewritten)
├── DevOpsLab.IntegrationTests.csproj (edited)
└── xunit.runner.json                 (new)
```

---

## Checkpoint 0 — Before you start

```bash
cd <your-team-repo>
git switch main && git pull
git switch -c test/testcontainers

docker info          # must succeed
dotnet test          # everything green
```

Confirm the SQL Server image is still on your machine:

```bash
docker images | grep mssql
# if missing:  docker pull mcr.microsoft.com/mssql/server:2022-latest
```

> Pull it **now** if it is missing. It is about 1.5 GB and you do not want to
> download it while thirty other people are doing the same.

---

## Step 1 — Read the comment you were given in Session 1 (5 min)

**Files:** read only — nothing to change yet.

Open `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs`:

```csharp
// TODO (Session 4): replace the in-memory provider below with Testcontainers so
// that integration tests run against a real SQL Server, identically on a
// developer laptop and on the CI runner. The in-memory provider does not enforce
// relational constraints and therefore hides an entire class of defects.
```

Now open the six integration tests that have been passing all along:

- `tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs` — 2 tests
- `tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs` — 4 tests

They check routing, status codes, serialisation and the health endpoints.

**Not one of them asks the database to enforce anything.**

That is why they pass against `UseInMemoryDatabase`, which is — structurally — a
`Dictionary`. Here is what your schema declares, and what InMemory does with it.
(The rules are declared in
`src/DevOpsLab.Infrastructure/Persistence/Configurations/ProductConfiguration.cs`.)

| The database enforces | Your code relies on it | EF InMemory |
|---|---|---|
| Unique index on `Sku` | Two products cannot share a SKU | **Not enforced** |
| `nvarchar(200)` on `Name` | A 300-character name is rejected | **Not enforced** |
| Foreign key to `Categories` | No orphan products | **Not enforced** |
| SQL translation of `EF.Functions.Like` | Search works at all | **Runs in memory — never as SQL** |

> **Checkpoint 1** — your team can name three guarantees the current test suite
> is not testing.

---

## Step 2 — Make the database real (25 min)

### 2.1 Swap the package

**File:** `tests/DevOpsLab.IntegrationTests/DevOpsLab.IntegrationTests.csproj` —
do not edit it by hand, let the CLI do it.

```bash
cd tests/DevOpsLab.IntegrationTests
dotnet remove package Microsoft.EntityFrameworkCore.InMemory
dotnet add package Testcontainers.MsSql
cd ../..
```

Open the `.csproj` afterwards and check: the `Microsoft.EntityFrameworkCore.InMemory`
line is gone and a `Testcontainers.MsSql` line has appeared.

> **Remove it, do not just stop using it.** If the package is still referenced,
> somebody will quietly go back to it the first time a container is slow — and
> the suite will start lying again without anyone noticing.

The project will **not build** until you finish 2.2 — that is expected.

### 2.2 Rewrite the factory

**File:** `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs` —
**replace the entire contents** of the file with the code below, including the
`using` lines at the top.

```csharp
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
/// Boots the real API pipeline in memory, against a real SQL Server running in
/// a throw-away Docker container.
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
```

What each part does:

| Part | Why it is there |
|---|---|
| `IAsyncLifetime` (from `Xunit`) | xUnit calls `InitializeAsync` before the first test and `DisposeAsync` after the last — this is where the container starts and stops. |
| `new MsSqlBuilder("<image>")` | Testcontainers 4.x takes the image in the constructor. The older `new MsSqlBuilder().WithImage(...)` form is **obsolete**, and because this project sets `TreatWarningsAsErrors`, it fails the build with `CS0618`. |
| `WithWaitStrategy(... "SELECT 1")` | Wait until SQL Server answers a query, not just until the port opens. |
| `MigrateAsync()` | Builds the schema from your real migrations in `src/DevOpsLab.Infrastructure/Migrations/`. |
| `DatabaseSeeder.SeedAsync(...)` | `Program.cs` only seeds outside Production, and this factory runs as Production. Without this line the catalogue is empty and `ListProducts_ReturnsSeededCatalog` fails. |
| `UseSqlServer(_database.GetConnectionString())` | Points the API at the container instead of InMemory. |

Check that it builds:

```bash
dotnet build
```

### 2.3 One container for the whole run

Starting SQL Server takes 20–40 seconds. Doing that per test class makes a suite
nobody is willing to wait for — and a suite nobody runs protects nothing.

Right now each test class declares `IClassFixture<ApiFactory>`, which means
**each class gets its own factory and its own container**. You will change that
to one shared factory for the whole run. Four files:

**① Create** `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiCollection.cs`:

```csharp
using Xunit;

namespace DevOpsLab.IntegrationTests.Infrastructure;

/// <summary>
/// Every test class marked [Collection(ApiCollection.Name)] shares ONE ApiFactory,
/// and therefore one SQL Server container, for the whole test run.
/// </summary>
[CollectionDefinition(Name)]
public sealed class ApiCollection : ICollectionFixture<ApiFactory>
{
    public const string Name = "api";
}
```

**② Edit** `tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs` — change
only the class declaration:

```csharp
// BEFORE
public class HealthEndpointTests : IClassFixture<ApiFactory>

// AFTER
[Collection(ApiCollection.Name)]
public class HealthEndpointTests
```

**③ Edit** `tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs` — the
same change:

```csharp
// BEFORE
public class ProductEndpointTests : IClassFixture<ApiFactory>

// AFTER
[Collection(ApiCollection.Name)]
public class ProductEndpointTests
```

> **You must remove `IClassFixture<ApiFactory>`, not just add the attribute.**
> If a class has both, xUnit still creates a private factory for that class —
> and a second container. Keep the constructor `(ApiFactory factory)` as it is;
> xUnit now passes in the shared instance.

**④ Create** `tests/DevOpsLab.IntegrationTests/xunit.runner.json`:

```json
{
  "parallelizeTestCollections": false,
  "longRunningTestSeconds": 60
}
```

**⑤ Edit** `tests/DevOpsLab.IntegrationTests/DevOpsLab.IntegrationTests.csproj` —
add this block just before the `<ItemGroup>` that contains `<ProjectReference>`:

```xml
<ItemGroup>
  <Content Include="xunit.runner.json" CopyToOutputDirectory="PreserveNewest" />
</ItemGroup>
```

> xUnit reads `xunit.runner.json` from the **build output folder**
> (`bin/Debug/net8.0/`), not from the project folder. Without this line the file
> is silently ignored and collections still run in parallel.

> One shared database plus parallel collections equals failures that look random
> and are not.

Run it, and **time it** — the `Duration` xUnit prints does not include the
container start-up, so it is not the number you are asked for:

```bash
time dotnet test tests/DevOpsLab.IntegrationTests
```

> **Checkpoint 2** — the six original tests pass against a real SQL Server.
> Note the run time (the `real` line from `time`); you will be asked for it.

---

## Step 3 — Make the tests isolated (20 min)

Every test class in the run now shares **one** real database. Unlike InMemory, it
does not vanish between tests: whatever one test inserts, the next test sees.
From Step 4 onwards tests really do insert rows, so each class must start from a
known state.

**① Edit** `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs` — add
this method inside the class, between `InitializeAsync` and `DisposeAsync`. No new
`using` lines are needed.

```csharp
public async Task ResetAsync()
{
    using var scope = Services.CreateScope();
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    var loggerFactory = scope.ServiceProvider.GetRequiredService<ILoggerFactory>();

    // Delete in foreign-key order. TRUNCATE fails against the FK.
    await db.Database.ExecuteSqlRawAsync("DELETE FROM Products");
    await db.Database.ExecuteSqlRawAsync("DELETE FROM Categories");

    await DatabaseSeeder.SeedAsync(db, loggerFactory.CreateLogger("TestSeed"));
}
```

> `DatabaseSeeder` skips seeding if any category already exists — that is why you
> must **delete first**, then seed.

**② Edit** both test classes —
`tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs` and
`tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs`. Add
`: IAsyncLifetime` to the class and the two methods under the constructor.
Here is `ProductEndpointTests` — do the same in `HealthEndpointTests`:

```csharp
[Collection(ApiCollection.Name)]
public class ProductEndpointTests : IAsyncLifetime
{
    private readonly ApiFactory _factory;

    public ProductEndpointTests(ApiFactory factory) => _factory = factory;

    // xUnit runs these before and after every test in this class.
    public Task InitializeAsync() => _factory.ResetAsync();
    public Task DisposeAsync() => Task.CompletedTask;

    // ... the existing [Fact] methods stay exactly as they are ...
}
```

This is **I** and **R** from FIRST (Session 3) — now with a real cost attached.
With InMemory you got isolation for free and never had to think about it.

```bash
dotnet test && dotnet test        # both must be green

# one class alone:
dotnet test tests/DevOpsLab.IntegrationTests --filter "FullyQualifiedName~ProductEndpointTests"
```

> **Checkpoint 3** — the suite passes twice in a row, and passes when you run
> one class alone.

---

## Step 4 — The three tests that change everything (20 min)

Each of these asserts something a **relational database** guarantees. Each one
deliberately bypasses `ProductService` and talks to `DbContext` directly.

> **Why bypass the service?** Because the service is one path to an insert. A
> background importer, a data migration, a fix-up script, an endpoint you write
> in Session 9 — each is another path. The service check gives a nice error
> message; the database constraint is what makes the rule true no matter who is
> inserting. A test that goes through the service is testing the service again.

**Create** the folder `tests/DevOpsLab.IntegrationTests/Database/` and in it the
file `DatabaseConstraintTests.cs` with the **complete** contents below. Note the
`NewContext` helper — the tests need it, and it does not exist anywhere else.

```csharp
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
    // The caller disposes the scope, which disposes the context.
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

        // Product.Create already refuses a name over 200 characters - that is the
        // domain's defence, not the database's. Create a valid product, then force
        // the column value through EF's change tracker so the database is asked.
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
```

> **Why the second test does not simply call `Product.Create` with a long name.**
> `Product.Create` would throw `BusinessRuleViolationException` before the
> database is ever involved — on SQL Server *and* on InMemory — and the test would
> prove nothing about the column. To test the database you must get past every
> layer above it: the service **and** the domain model. That one rule is defended
> three times; each layer needs its own test.

Run them:

```bash
dotnet test tests/DevOpsLab.IntegrationTests --filter "FullyQualifiedName~DatabaseConstraintTests"
```

All three pass against SQL Server. **Take the screenshot now** (evidence item 3).

### Now do the experiment

**Predict first.** Write it down:

> If I put `UseInMemoryDatabase` back, these three tests will: ______

Putting InMemory back takes **three** temporary edits, not one: `MigrateAsync`
and `ExecuteSqlRawAsync` only work on a relational database and throw on
InMemory. If you only swap the `UseSqlServer` line, **every** test fails with
`InvalidOperationException` and the experiment proves nothing.

Commit (or stash) your work first so you can get back to it exactly:

```bash
git add -A && git commit -m "test: run integration tests against SQL Server via Testcontainers"
```

**① Temporarily re-add the package** (pin version `8.0.10` to match EF Core in
`src/DevOpsLab.Infrastructure`):

```bash
cd tests/DevOpsLab.IntegrationTests
dotnet add package Microsoft.EntityFrameworkCore.InMemory --version 8.0.10
cd ../..
```

**② Temporarily edit** `tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs`
— three replacements:

| Where | Replace | With |
|---|---|---|
| `ConfigureWebHost` | `o.UseSqlServer(_database.GetConnectionString())` | `o.UseInMemoryDatabase("experiment")` |
| `InitializeAsync` | `await db.Database.MigrateAsync();` | `await db.Database.EnsureCreatedAsync();` |
| `ResetAsync` | the two `ExecuteSqlRawAsync("DELETE ...")` lines | `await db.Database.EnsureDeletedAsync();`<br>`await db.Database.EnsureCreatedAsync();` |

**③ Run:**

```bash
dotnet test tests/DevOpsLab.IntegrationTests
```

**All three constraint tests fail; the six original tests still pass.**
Nothing throws, because nothing is enforced. **Screenshot** (evidence item 2).

**④ Revert both files** — this is not optional, Step 7 checks it:

```bash
git restore tests/DevOpsLab.IntegrationTests/
dotnet test tests/DevOpsLab.IntegrationTests    # all 9 green again
```

> **Your integration suite was green for three sessions because no test had ever
> asked the database a question.**
>
> You did not have an integration test suite. You had a slower unit test suite
> with HTTP in front of it.

**The rule to keep:** *if a test replaces a dependency with a fake, it can only
tell you about your code. The moment you need to know whether your code and the
dependency **agree**, the dependency has to be real.*

> **Checkpoint 4** — screenshots of all three tests **failing** under InMemory
> and **passing** under SQL Server. Lab 2 evidence, items 2 and 3.

---

## Step 5 — A smoke test whose exit code matters (30 min)

**File:** `scripts/smoke-test.sh` — **copy** it from the Session 4 course
materials into the `scripts/` folder at the root of your repository (next to the
existing `setup.sh`). Make it executable:

```bash
chmod +x scripts/smoke-test.sh
```

Run it against your local API. The API needs the local SQL Server from
`docker-compose.yml`; when started with `dotnet run` it runs as Development, so it
applies migrations and seeds data by itself.

```bash
docker compose up -d                       # local SQL Server (same as: make db-up)
dotnet run --project src/DevOpsLab.WebApi &
sleep 5
bash scripts/smoke-test.sh http://localhost:5080
echo "exit=$?"
```

Five checks, exit 0.

### What makes it a gate

**The exit code.** From Session 9 your CD pipeline runs this and stops the
deployment on a non-zero exit. Nobody reads the output at 2am — the pipeline
reads one integer.

| Check | Why |
|---|---|
| `/healthz/ready` returns 200 | Nothing downstream is meaningful until it does. Wait for **ready**, not **live**. |
| `/healthz/live` returns 200 | The process answers |
| `/api/products` returns 200 **with items** | "200" is not enough — an empty catalogue means the seed or migration silently failed |
| Unknown id returns 404 | A 500 on a typo is a broken deployment |
| Invalid product returns 400 with a `rule` field | The error contract other systems depend on |

### Prove it fails

```bash
docker compose stop sqlserver
bash scripts/smoke-test.sh http://localhost:5080
echo "exit=$?"          # expect 1
docker compose start sqlserver
```

> **Check the exit code without a pipe.**
>
> ```bash
> bash scripts/smoke-test.sh http://localhost:5080 | tee smoke.log
> echo "exit=$?"     # this is tee's exit code, not the script's - ALWAYS 0
> ```
>
> This is the Session 2 "false gate" wearing a different costume: a check that
> runs, prints red text, and reports success. It catches professionals regularly.
> If you must keep a log, use `set -o pipefail` or `${PIPESTATUS[0]}`.

When you are done, stop the API: `kill %1` (or `fg` then Ctrl+C).

> **Checkpoint 5** — screenshot of a **non-zero exit** from a broken deployment.
> Lab 2 evidence item 5.

---

## Step 6 — The coverage gate (20 min)

**Files:** `scripts/coverage-gate.sh` and `scripts/diff-coverage.sh` — **copy**
both from the Session 4 course materials into `scripts/`, then:

```bash
chmod +x scripts/coverage-gate.sh scripts/diff-coverage.sh
bash scripts/coverage-gate.sh --threshold 75
```

Today the number stops being information and becomes a gate. From Session 5 this
runs in CI and a non-zero exit blocks the merge button.

**Prove it fails too.** Temporarily lower nothing — instead raise the bar:

```bash
bash scripts/coverage-gate.sh --threshold 99
echo "exit=$?"          # expect 1
```

Then run it at the real threshold and make it pass by **writing tests** — unit
tests go in `tests/DevOpsLab.UnitTests/` (`Domain/` or `Application/`),
integration tests in `tests/DevOpsLab.IntegrationTests/`.

> **Two ways to raise coverage that both work and are both cheating:** delete
> code, or add tests with no assertions. Session 3 showed you exactly what an
> assertion-free test is worth. The gate cannot tell the difference. Your
> reviewer can.

### Diff coverage

```bash
git fetch origin
bash scripts/diff-coverage.sh --base origin/main --threshold 80
```

**Why this is the better question.** A pull request adds 200 untested lines to a
10,000-line codebase sitting at 80%. New total: 78.4%. A 75% gate passes. Two
hundred untested lines just went in.

Total coverage describes the whole repository. Diff coverage asks about **the
change in front of the reviewer**, and it prints the exact changed lines that no
test exercised — a review comment writing itself.

Paste both outputs into your pull request description.

> **Checkpoint 6** — coverage gate seen to fail and then pass; diff coverage
> reported on the PR. Lab 2 evidence items 6 and 7.

---

## Step 7 — Prove InMemory is gone (5 min)

**Files:** none to change — run this from the **repository root**:

```bash
grep -rn "UseInMemoryDatabase\|EntityFrameworkCore.InMemory" --include="*.cs" --include="*.csproj" .
# must return nothing
```

If it returns anything — typically a leftover from the Step 4 experiment — the
suite can silently go back to lying. Remove it (`git restore` the file, or
`dotnet remove package Microsoft.EntityFrameworkCore.InMemory`).

> **Checkpoint 7** — the grep is empty.

---

## Step 8 — Submit Lab 2 (10 min)

Commit everything on `test/testcontainers`, push, and open a pull request into
`main`. The PR should contain exactly these changes:

```
scripts/coverage-gate.sh                                          (new)
scripts/diff-coverage.sh                                          (new)
scripts/smoke-test.sh                                             (new)
tests/DevOpsLab.IntegrationTests/Api/HealthEndpointTests.cs       (modified)
tests/DevOpsLab.IntegrationTests/Api/ProductEndpointTests.cs      (modified)
tests/DevOpsLab.IntegrationTests/Database/DatabaseConstraintTests.cs (new)
tests/DevOpsLab.IntegrationTests/DevOpsLab.IntegrationTests.csproj   (modified)
tests/DevOpsLab.IntegrationTests/Infrastructure/ApiCollection.cs  (new)
tests/DevOpsLab.IntegrationTests/Infrastructure/ApiFactory.cs     (modified)
tests/DevOpsLab.IntegrationTests/xunit.runner.json                (new)
```

…plus any new unit tests you wrote in Step 6. `git status` must not show
`smoke.log`, `TestResults/` or coverage reports staged — do not commit them.

One message in your team channel:

1. Screenshot — `dotnet test` green against Testcontainers, **with the run time**
2. Screenshot — the three constraint tests **failing** under InMemory
3. Screenshot — the same three **passing** under SQL Server
4. Screenshot — `dotnet test` twice in a row, both green
5. Screenshot — `smoke-test.sh` exiting **non-zero** on a broken deployment
6. Screenshot — coverage gate **failing**, then passing
7. Diff coverage output, in the PR description
8. Link to the merged PR
9. The empty `grep` from Step 7

Every screenshot must show something **failing**. A gate that has only ever been
seen to pass is not evidence.

> **Checkpoint 8** — all nine posted.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CS0246: 'IAsyncLifetime' could not be found` | Missing `using Xunit;` | Add it to the top of the file |
| `CS0246: 'MsSqlContainer' could not be found` | Missing `using Testcontainers.MsSql;` (or the package) | Add the `using`; check Step 2.1 ran |
| `CS0103: The name 'Wait' does not exist` | Missing `using DotNet.Testcontainers.Builders;` | Add it to the top of `ApiFactory.cs` |
| `CS0618: 'MsSqlBuilder.MsSqlBuilder()' is obsolete` | Old builder form + `TreatWarningsAsErrors` | `new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest")`, remove `.WithImage(...)` |
| `ListProducts_ReturnsSeededCatalog` fails: `TotalCount` is 0 | Factory runs as Production, so nothing seeds | Call `DatabaseSeeder.SeedAsync` in `InitializeAsync` (Step 2.2) |
| `Relational-specific methods can only be used...` | InMemory provider with `MigrateAsync` / `ExecuteSqlRawAsync` | You only half-did the Step 4 experiment — make all three edits, or revert |
| Two containers start (`docker ps`) | A class still has `IClassFixture<ApiFactory>` | Remove it; use `[Collection(ApiCollection.Name)]` only |
| `xunit.runner.json` has no effect | File not copied to `bin/` | Add the `<Content ... CopyToOutputDirectory>` line (Step 2.3 ⑤) |
| `Docker.DotNet ... connection refused` | Docker not running | Start Docker Desktop |
| Container start times out | Waiting on the port, not on the database | Wait on `sqlcmd -Q "SELECT 1"` |
| First run takes 40 seconds | SQL Server startup | Normal. One container per collection, not per class. |
| Tests pass alone, fail together | No reset between tests | `ResetAsync` in `InitializeAsync` |
| Suite green once, red on re-run | Seed data duplicated | Delete before seeding |
| `Cannot truncate table ... FOREIGN KEY` | Truncate ignores FK order | `DELETE FROM Products` then `Categories` |
| Random unexplainable failures | Collections running in parallel | `parallelizeTestCollections: false` |
| `Port is already allocated` | Orphaned container | `docker ps -a`, remove it; use `WithCleanUp(true)` |
| Smoke test "passes" when the API is down | Exit code swallowed by a pipe | Do not pipe, or use `${PIPESTATUS[0]}` |
| `bash: scripts/smoke-test.sh: No such file` | Script not copied in | Copy it from the Session 4 course materials (Step 5) |
| Diff coverage says "no coverable lines changed" | Coverage report older than your commits | Re-run `coverage-gate.sh` first |

**Before you leave the room:**

```bash
docker ps -a        # remove any container you left behind
```

---

## Before Session 5

- [ ] `UseInMemoryDatabase` appears nowhere — grep and prove it
- [ ] Suite green twice in a row and in any order
- [ ] Coverage at or above the agreed threshold
- [ ] `scripts/` committed: smoke test, coverage gate, diff coverage
- [ ] Read *GitHub Actions in Action*, Chapters 1–4

**Session 5 preview.** Everything you built in Sessions 2–4 runs on your laptop,
where you can choose not to run it. Next session it moves to a server that runs
it on every pull request, whether you want it to or not — and a red result stops
the merge button working. That is "red means stop", with a switch attached.
