#!/usr/bin/env bash
# =============================================================================
# verify-nonroot.sh — prove the image does not run as root.
#
#   ./verify-nonroot.sh devopslab-api:local [running-container-name]
#
# Exit 0 only when the image is demonstrably non-root. Exit 1 otherwise.
#
# Note on `docker run --rm IMAGE id`: that is the proof everyone reaches for,
# and it does not work on a chiseled image, which has no `id` binary and no
# shell. The absence of `id` is not evidence of root — so this script asks the
# image itself, and asks the kernel about the running process.
# =============================================================================
set -euo pipefail

IMAGE="${1:?usage: verify-nonroot.sh IMAGE [CONTAINER]}"
CONTAINER="${2:-}"

fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }
pass() { printf 'OK    %s\n' "$1"; }

# --- 1. What user does the image declare? ------------------------------------
user="$(docker image inspect --format '{{.Config.User}}' "$IMAGE" 2>/dev/null)" \
    || fail "image not found: $IMAGE"

if [ -z "$user" ]; then
    fail "image declares no USER — it will run as root. Add a USER line."
fi
if [ "$user" = "root" ] || [ "$user" = "0" ]; then
    fail "image declares USER $user — that is root."
fi
pass "image declares USER $user"

# --- 2. Does the image say which UID that is? --------------------------------
# .NET 8 images publish the non-root UID in an environment variable so that a
# platform can enforce runAsNonRoot. Read it rather than assuming the number.
uid_env="$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" \
           | grep -E '^APP_UID=' || true)"
if [ -n "$uid_env" ]; then
    pass "image publishes ${uid_env}"
else
    printf 'NOTE  image publishes no APP_UID; UID resolved from /etc/passwd at run time\n'
fi

# --- 3. If a container is running, ask the kernel, not the image -------------
if [ -n "$CONTAINER" ]; then
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        fail "container not found: $CONTAINER"
    fi
    # `docker top` reads the host process table: it cannot be faked by the image.
    owner="$(docker top "$CONTAINER" -o user 2>/dev/null | awk 'NR==2 {print $1}')"
    [ -n "$owner" ] || fail "could not read the process owner of $CONTAINER"
    if [ "$owner" = "root" ] || [ "$owner" = "0" ]; then
        fail "the process in $CONTAINER is owned by root on the host"
    fi
    pass "process in $CONTAINER runs as $owner on the host"
fi

printf '\nPASS  %s does not run as root.\n' "$IMAGE"
