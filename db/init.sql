CREATE TABLE IF NOT EXISTS public.relationships (
    relationship_id UUID PRIMARY KEY,
    relationship_type TEXT NOT NULL,
    source_entity_id TEXT NOT NULL,
    source_entity_type TEXT NOT NULL,
    source_entity_name TEXT,
    target_entity_id TEXT NOT NULL,
    target_entity_type TEXT NOT NULL,
    target_entity_name TEXT,
    detection_id UUID,
    lineage_id UUID,
    knowledge_source TEXT,
    knowledge_entity_id TEXT,
    knowledge_entity_type TEXT,
    knowledge_version TEXT,
    properties JSONB NOT NULL DEFAULT '{}'::jsonb,
    first_observed_at TIMESTAMPTZ NOT NULL,
    last_observed_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_relationships_source_entity_id ON public.relationships (source_entity_id);
CREATE INDEX IF NOT EXISTS idx_relationships_target_entity_id ON public.relationships (target_entity_id);
CREATE INDEX IF NOT EXISTS idx_relationships_type ON public.relationships (relationship_type);

ALTER TABLE public.relationships REPLICA IDENTITY FULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_catalog.pg_roles WHERE rolname = 'debezium'
    ) THEN
        CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD 'debezium';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE ripple TO debezium;
GRANT USAGE ON SCHEMA public TO debezium;
GRANT SELECT ON TABLE public.relationships TO debezium;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'ripple_relationship'
    ) THEN
        CREATE PUBLICATION ripple_relationship FOR TABLE public.relationships;
    END IF;
END
$$;
