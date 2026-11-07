#!/usr/bin/env bash
# =============================================================================
# image-report.sh — the numbers that go into docs/adr-0001-base-image.md.
#
#   ./image-report.sh devopslab-api:local [devopslab-api:alpine ...]
#
# Prints a Markdown table: size, layer count, declared user, exposed ports.
# Paste it into the ADR. A base-image decision without numbers is a preference.
# =============================================================================
set -euo pipefail

[ "$#" -ge 1 ] || { printf 'usage: image-report.sh IMAGE [IMAGE...]\n' >&2; exit 2; }

# The backticks below are Markdown, not command substitution.
# shellcheck disable=SC2016
printf '| Image | Size | Layers | USER | Exposed |\n'
printf '|---|---:|---:|---|---|\n'

status=0
for image in "$@"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        # shellcheck disable=SC2016
        printf '| `%s` | not found | - | - | - |\n' "$image"
        status=1
        continue
    fi
    bytes="$(docker image inspect --format '{{.Size}}' "$image")"
    mb="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b/1024/1024 }')"
    layers="$(docker image inspect --format '{{len .RootFS.Layers}}' "$image")"
    user="$(docker image inspect --format '{{.Config.User}}' "$image")"
    [ -n "$user" ] || user='**root**'
    # The Go range leaves a trailing space; trim it or the Markdown cell gets two.
    ports="$(docker image inspect --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$image" | sed 's/[[:space:]]*$//')"
    [ -n "$ports" ] || ports='-'
    # shellcheck disable=SC2016
    printf '| `%s` | %s MB | %s | %s | %s |\n' "$image" "$mb" "$layers" "$user" "$ports"
done

printf '\nSize is the least interesting column. The one that decides an incident at\n'
printf '02:00 is USER, and the one that decides how you debug is whether the image\n'
printf 'has a shell at all.\n'
exit "$status"
