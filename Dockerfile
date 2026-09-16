FROM docker.redpanda.com/redpandadata/connect:4.50.0 AS connect
FROM python:3.12-slim
RUN pip install --no-cache-dir neo4j==5.23.1
COPY --from=connect /redpanda-connect /usr/local/bin/redpanda-connect
COPY apply_cypher.py /usr/local/bin/apply_cypher.py
COPY connect.yaml /connect.yaml
COPY rebuild.yaml /rebuild.yaml
RUN chmod +x /usr/local/bin/apply_cypher.py
EXPOSE 4195
ENTRYPOINT ["redpanda-connect"]
CMD ["run", "/connect.yaml"]
