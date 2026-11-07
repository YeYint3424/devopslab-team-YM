# syntax=docker/dockerfile:1

# --- Stage 1: build ----------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# 1. Project files first. This layer changes only when a dependency changes.
COPY DevOpsLab.sln ./
COPY src/DevOpsLab.Domain/DevOpsLab.Domain.csproj                 src/DevOpsLab.Domain/
COPY src/DevOpsLab.Application/DevOpsLab.Application.csproj       src/DevOpsLab.Application/
COPY src/DevOpsLab.Infrastructure/DevOpsLab.Infrastructure.csproj src/DevOpsLab.Infrastructure/
COPY src/DevOpsLab.WebApi/DevOpsLab.WebApi.csproj                 src/DevOpsLab.WebApi/

# 2. Restore only the web project's graph. Test projects never enter the image.
RUN dotnet restore src/DevOpsLab.WebApi/DevOpsLab.WebApi.csproj

# 3. Now the source. A one-character change here invalidates from this line down.
COPY src/ src/

# 4. Publish. --no-restore asserts that step 2 really did the work.
RUN dotnet publish src/DevOpsLab.WebApi/DevOpsLab.WebApi.csproj \
        --configuration Release \
        --no-restore \
        --output /app/publish \
        /p:UseAppHost=false

# --- Stage 2: runtime --------------------------------------------------------
# noble-chiseled: Ubuntu 24.04, no shell, no package manager, non-root by default.
FROM mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled AS runtime
WORKDIR /app

# 8080, not 80: a non-root process cannot bind a port below 1024.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Only the published output crosses from the build stage.
COPY --from=build /app/publish .

# The chiseled image already defaults to `app` (UID 1654). Say it anyway.
USER app

ENTRYPOINT ["dotnet", "DevOpsLab.WebApi.dll"]

# No HEALTHCHECK on purpose: it would run INSIDE the container, and this image
# has no shell and no curl. See docs/adr-0001-base-image.md.
