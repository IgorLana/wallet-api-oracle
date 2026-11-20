#!/usr/bin/env bash
# C10 - Fast tests and disposable Oracle integration suite.
# Run from anywhere: bash scripts/verify-c10.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

printf '\n[C10 1/2] Running JUnit / Mockito tests (no Docker required)...\n'
./mvnw -U test

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf '\nERROR: Docker Desktop must be running for Testcontainers.\n' >&2
  printf 'The fast tests above ran. Start Docker and rerun this script.\n' >&2
  exit 1
fi

printf '\n[C10 2/2] Running the isolated Oracle Free integration suite...\n'
printf 'No credentials from .env are used by the integration tests.\n'
./mvnw -U verify
printf '\nC10 completed: Maven BUILD SUCCESS means unit + integration tests passed.\n'
