#!/usr/bin/env python3
"""Line-oriented Bolt shim for Redpanda Connect.

Connect's subprocess processor keeps this process alive and sends one JSON
line per message. Reading until EOF would hang the pipeline forever.

Connect's native cypher output uses neo4j-go-driver VerifyAuthentication,
which hangs on Memgraph (bolt5 re-auth). session.run does not.
"""
from __future__ import annotations

import json
import os
import sys

from neo4j import GraphDatabase

URI = os.environ.get("MEMGRAPH_URI", "bolt://memgraph:7687")


def apply(driver, payload: dict) -> None:
    query = payload.get("cypher") or ""
    params = payload.get("params") or {}
    if not query:
        return
    with driver.session() as session:
        session.run(query, params).consume()


def main() -> int:
    driver = GraphDatabase.driver(URI, auth=None)
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                print("{}", flush=True)
                continue
            try:
                apply(driver, json.loads(line))
            except Exception as exc:  # noqa: BLE001
                print(str(exc), file=sys.stderr, flush=True)
                continue
            print('{"ok":true}', flush=True)
    finally:
        driver.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
