# ripple-upload-relationship-etl

Redpanda Connect ETL that projects **relationship CDC** into Memgraph.

This service consumes **only** `ripple.relationship.public.relationships`. It does not join tables A/B/C and does not infer relationships.

```text
PostgreSQL public.relationships
        │ WAL
        ▼
 Debezium Server  →  Redpanda (ripple.relationship.public.relationships)
        │
        ▼
 Redpanda Connect  →  Memgraph
 (BRCA1 -[:DETECTED_IN]-> Analysis 123)
```

- `c` / `u` / `r` → MERGE `BiologicalEntity`, typed artifact node, `DETECTED_IN`
- `d` → DELETE the graph relationship by `relationship_id` (nodes stay)
- Bolt writes go through a long-lived Python helper (`apply_cypher.py`). Connect’s native `cypher` output hangs on Memgraph because Neo4j Bolt v5 `VerifyAuthentication` never completes.

Rebuild is a bounded Connect job (`rebuild.yaml`) that `SELECT`s `relationships` and runs the same MERGE. It does not replay A/B/C CDC.

Extracted from `ripple-relationship-service`.

## Run

```bash
cp .env.example .env
make up
```

Wait until Debezium and Redpanda Connect are healthy, then insert a relationships row (or run `make integration-test`).

- Redpanda Console: http://localhost:18088
- Memgraph Lab: http://localhost:13001
- Connect HTTP: http://localhost:19101/ping
- Postgres: `localhost:15432` user/password/db `ripple`
- Kafka: `localhost:19092`

## Tests

```bash
make unit                 # Bloblang mapping tests (connect_benthos_test.yaml)
make integration-test     # docker compose up, then CDC → Memgraph checks
```

`make integration-test` starts the compose stack and runs `scripts/integration-test.sh`. Coverage: seed MERGE, duplicate UPSERT, knowledge-version update, relationship delete (nodes left in place), Connect health, rebuild from Postgres. The stack stays up afterward (`make down` to stop it).

## Make targets

| Target                    | Action |
| ------------------------- | ------ |
| `make lint`               | Validate Compose + `connect.yaml` |
| `make unit`               | Redpanda Connect Bloblang tests |
| `make build`              | Build the loader image |
| `make up`                 | Start the stack |
| `make down`               | Stop containers, keep volumes |
| `make reset`              | `docker compose down -v` |
| `make rebuild`            | Clear graph edges, MERGE from `relationships` |
| `make integration-test`   | Unit tests + full CDC path |

## Configuration

Copy `.env.example` to `.env` for local overrides. Do not commit production secrets.
