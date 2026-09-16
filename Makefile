.PHONY: lint unit build up down reset logs logs-loader logs-debezium query consume-cdc rebuild integration-test env-file

COMPOSE ?= docker compose
ENV_FILE ?= .env

env-file:
	@if [ ! -f "$(ENV_FILE)" ]; then cp .env.example "$(ENV_FILE)"; echo "Created $(ENV_FILE) from .env.example"; fi

lint: env-file
	$(COMPOSE) config --quiet
	bash -n scripts/integration-test.sh
	bash -n scripts/rebuild-memgraph.sh
	docker run --rm --entrypoint /redpanda-connect \
		-e KAFKA_BROKERS=redpanda:9092 \
		-e RELATIONSHIP_TOPIC=ripple.relationship.public.relationships \
		-e CONSUMER_GROUP=memgraph-loader \
		-v "$(PWD)/connect.yaml:/connect.yaml:ro" \
		docker.redpanda.com/redpandadata/connect:4.50.0 \
		lint /connect.yaml

unit:
	docker run --rm -v "$(PWD):/connect:ro" docker.redpanda.com/redpandadata/connect:4.50.0 test /connect/connect.yaml

build: env-file
	$(COMPOSE) build memgraph-loader

up: env-file
	@if sudo -n true 2>/dev/null; then echo 0 | sudo tee /proc/sys/net/bridge/bridge-nf-call-iptables >/dev/null || true; fi
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

reset:
	@echo "Destroying Postgres, Redpanda, Debezium offsets, and Memgraph data (docker compose down -v)."
	$(COMPOSE) down -v

logs:
	$(COMPOSE) logs -f --tail=200

logs-loader:
	$(COMPOSE) logs -f --tail=200 memgraph-loader

logs-debezium:
	$(COMPOSE) logs -f --tail=200 debezium-server

query:
	$(COMPOSE) exec -T postgres psql -U ripple -d ripple -c "SELECT relationship_id, relationship_type, source_entity_id, target_entity_id, knowledge_version FROM relationships;"

consume-cdc:
	$(COMPOSE) exec -T redpanda rpk topic consume ripple.relationship.public.relationships -o 0:end -f '%v\n'

rebuild: env-file
	./scripts/rebuild-memgraph.sh

integration-test: env-file unit
	./scripts/integration-test.sh
