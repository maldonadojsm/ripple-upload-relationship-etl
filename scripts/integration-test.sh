#!/usr/bin/env bash
# End-to-end checks for relationship CDC → Redpanda Connect → Memgraph.
# Coverage (moved from ripple-relationship-service): seed MERGE, duplicate UPSERT,
# knowledge-version update, delete edge, Connect health, rebuild from Postgres.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  cp .env.example .env
fi

TIMEOUT_SECS="${INTEGRATION_TIMEOUT:-360}"
LOADER_URL="${MEMGRAPH_LOADER_URL:-http://localhost:19101}"
REL_ID="f726a747-d251-53dd-a174-b0110021e2c6"

PASS=0
FAIL=0

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
ok() { PASS=$((PASS + 1)); log "OK  $*"; }
fail() { echo "[integration] FAIL: $*" >&2; FAIL=$((FAIL + 1)); exit 1; }

if [[ "${SKIP_INTEGRATION:-}" == "1" ]]; then
  log "SKIP_INTEGRATION=1"
  exit 0
fi

command -v docker >/dev/null || fail "docker is required"
docker compose version >/dev/null || fail "docker compose is required"

compose() { docker compose "$@"; }

psql_q() {
  compose exec -T postgres psql -U ripple -d ripple -v ON_ERROR_STOP=1 -tA -c "$1"
}

psql_exec() {
  compose exec -T postgres psql -U ripple -d ripple -v ON_ERROR_STOP=1 -c "$1" >/dev/null
}

cypher_csv() {
  compose exec -T memgraph mgconsole --host 127.0.0.1 --port 7687 --output-format csv <<CYPHER
$1
CYPHER
}

graph_version() {
  cypher_csv "MATCH (s:BiologicalEntity {id:'HGNC:1100'})-[r:DETECTED_IN]->(t:Analysis {id:'analysis:123'}) RETURN r.knowledge_version AS v;" \
    | tr -d '\r' \
    | awk 'NR>1 && NF { gsub(/"/, ""); print; exit }'
}

graph_edge_count() {
  cypher_csv "MATCH ()-[r:DETECTED_IN]->() RETURN count(r) AS n;" \
    | tr -d '\r' \
    | awk 'NR>1 && NF { gsub(/"/, ""); print; exit }'
}

graph_node_count() {
  cypher_csv "MATCH (n) RETURN count(n) AS n;" \
    | tr -d '\r' \
    | awk 'NR>1 && NF { gsub(/"/, ""); print; exit }'
}

wait_until() {
  local name="$1"
  local check="$2"
  local started now elapsed last="" status last_log=-1
  started="$(date +%s)"
  log "waiting for ${name}"
  while true; do
    now="$(date +%s)"
    elapsed=$((now - started))
    set +e
    last="$("$check" 2>&1)"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      log "${name} ready after ${elapsed}s"
      return 0
    fi
    if (( elapsed >= TIMEOUT_SECS )); then
      fail "${name} timeout after ${elapsed}s: ${last}"
    fi
    if (( elapsed - last_log >= 5 )); then
      log "${name} still waiting (${elapsed}s): ${last}"
      last_log=$elapsed
    fi
    sleep 1
  done
}

http_ok() {
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url" || true)"
  [[ "$code" == "200" ]]
}

check_postgres() {
  compose exec -T postgres pg_isready -U ripple -d ripple >/dev/null
}

check_loader() {
  http_ok "${LOADER_URL}/ping" || { echo "loader ${LOADER_URL}/ping not 200"; return 1; }
}

check_seed() {
  local n ver g
  n="$(psql_q "SELECT COUNT(*) FROM relationships")"
  n="$(echo "$n" | tr -d '[:space:]')"
  [[ "$n" == "1" ]] || { echo "relationships=${n}"; return 1; }
  ver="$(psql_q "SELECT knowledge_version FROM relationships")"
  ver="$(echo "$ver" | tr -d '[:space:]')"
  [[ "$ver" == "26.08" ]] || { echo "pg version ${ver}"; return 1; }
  g="$(graph_version)"
  [[ "$g" == "26.08" ]] || { echo "graph version ${g:-missing}"; return 1; }
}

check_knowledge() {
  local ver g
  ver="$(psql_q "SELECT knowledge_version FROM relationships")"
  ver="$(echo "$ver" | tr -d '[:space:]')"
  [[ "$ver" == "26.09" ]] || { echo "pg version ${ver}"; return 1; }
  g="$(graph_version)"
  [[ "$g" == "26.09" ]] || { echo "graph version ${g:-missing}"; return 1; }
}

check_deleted() {
  local n edges
  n="$(psql_q "SELECT COUNT(*) FROM relationships")"
  n="$(echo "$n" | tr -d '[:space:]')"
  [[ "$n" == "0" ]] || { echo "relationships still ${n}"; return 1; }
  edges="$(graph_edge_count)"
  [[ "$edges" == "0" ]] || { echo "edges=${edges} want 0"; return 1; }
}

insert_seed() {
  psql_exec "INSERT INTO relationships (
      relationship_id, relationship_type,
      source_entity_id, source_entity_type, source_entity_name,
      target_entity_id, target_entity_type, target_entity_name,
      detection_id, lineage_id,
      knowledge_source, knowledge_entity_id, knowledge_entity_type, knowledge_version,
      properties, first_observed_at, last_observed_at
    ) VALUES (
      '${REL_ID}',
      'DETECTED_IN',
      'HGNC:1100', 'gene', 'BRCA1',
      'analysis:123', 'analysis', 'analysis 123',
      '49100000-0000-4000-8000-000000000001',
      '49100000-0000-4000-8000-000000000002',
      'OpenTargets', 'ENSG00000012048', 'gene', '26.08',
      '{\"confidence\": 1.0}'::jsonb,
      NOW(), NOW()
    )
    ON CONFLICT (relationship_id) DO UPDATE SET
      knowledge_version = EXCLUDED.knowledge_version,
      last_observed_at = NOW(),
      updated_at = NOW()"
}

log "starting docker compose stack"
if [ -w /proc/sys/net/bridge/bridge-nf-call-iptables ] || sudo -n true 2>/dev/null; then
  echo 0 | sudo tee /proc/sys/net/bridge/bridge-nf-call-iptables >/dev/null || true
fi
if [[ "${INTEGRATION_BUILD:-}" == "1" ]]; then
  compose up -d --build --wait --wait-timeout 300
else
  compose up -d --wait --wait-timeout 300
fi

wait_until "postgres" check_postgres
wait_until "memgraph-loader /ping" check_loader
ok "Connect ping 200"

log "GET ${LOADER_URL}/ping"
curl -sS -f --max-time 5 "${LOADER_URL}/ping" >/dev/null

log "clearing relationships and graph edges"
psql_exec "DELETE FROM relationships"
compose exec -T memgraph sh -c 'echo "MATCH (n) DETACH DELETE n;" | mgconsole --host 127.0.0.1 --port 7687' >/dev/null

log "step: seed creates one relationship and one graph edge"
insert_seed
wait_until "seed path" check_seed
ok "seed path complete: 1 relationship, graph knowledge_version=26.08"

log "step: duplicate upsert does not duplicate"
insert_seed
log "waiting 2s for CDC so a duplicate edge would have time to appear"
sleep 2
n="$(psql_q "SELECT COUNT(*) FROM relationships")"
n="$(echo "$n" | tr -d '[:space:]')"
log "relationships count after duplicate upsert: ${n}"
[[ "$n" == "1" ]] || fail "duplicate relationships: ${n}"
edges="$(graph_edge_count)"
[[ "$edges" == "1" ]] || fail "duplicate edges: ${edges}"
ok "duplicate upsert remained a single DETECTED_IN edge"

log "step: knowledge version update flows to memgraph"
psql_exec "UPDATE relationships SET knowledge_version = '26.09', updated_at = NOW()
  WHERE relationship_id = '${REL_ID}'"
wait_until "knowledge version" check_knowledge
ok "knowledge version 26.09 present in postgres and memgraph"

log "step: relationship delete removes graph edge and leaves nodes"
before_nodes="$(graph_node_count)"
psql_exec "DELETE FROM relationships WHERE relationship_id = '${REL_ID}'"
wait_until "relationship delete" check_deleted
after_nodes="$(graph_node_count)"
[[ "$after_nodes" == "$before_nodes" ]] || fail "nodes changed on delete: before=${before_nodes} after=${after_nodes}"
ok "delete complete: 0 relationships, 0 DETECTED_IN edges, nodes left in place"

log "step: rebuild MERGE from relationships table"
insert_seed
wait_until "seed after rebuild prep" check_seed
compose exec -T memgraph sh -c 'echo "MATCH ()-[r]->() DELETE r;" | mgconsole --host 127.0.0.1 --port 7687' >/dev/null
edges="$(graph_edge_count)"
[[ "$edges" == "0" ]] || fail "edges not cleared before rebuild: ${edges}"
compose --profile tools run --rm memgraph-rebuild
wait_until "rebuild MERGE" check_seed
ok "rebuild restored knowledge_version=26.08 from Postgres"

log "PASS (${PASS} checks)"
log "compose stack is still running; stop with: make down"
