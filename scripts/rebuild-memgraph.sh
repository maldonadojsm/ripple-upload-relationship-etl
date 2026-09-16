#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Authoritative state is Postgres relationships. Drop graph edges, then MERGE from the table.
docker compose exec -T memgraph sh -c 'echo "MATCH ()-[r]->() DELETE r;" | mgconsole --host 127.0.0.1 --port 7687'
docker compose --profile tools run --rm memgraph-rebuild
