# ADR-0001 — Runtime base image

## Status
Accepted — Session 6

## Context
- image-report.sh output (paste the table: chiseled, alpine, SDK)
- Build context size (Step 4.2): ___ MB
- Rebuild after a one-line source change (Step 4.4):
  correct layer order ___ s · wrong layer order ___ s

## Decision
<which runtime image, and why — one paragraph>

## Consequences
- What we gain:
- What we give up (name the capability, not "slightly harder to debug"):
- How we diagnose a running container without a shell:
- How we check the container's health, given that a HEALTHCHECK needs a shell:
- Readiness recovery time after a database restart (Step 8b): ___ s
