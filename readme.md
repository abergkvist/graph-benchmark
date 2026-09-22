# graph-benchmark

Comparison of graph databases (Neo4j, Memgraph, ArcadeDB, LadybugDB, Apache AGE) against the same dataset and queries.     

## Prerequisites

- Docker and Docker Compose
- For LadybugDB: the `lbug` shell installed on the host, used for seeding

## Starting databases

Start one at a time or all at once:

```bash
docker compose up -d neo4j
docker compose up -d memgraph memgraph-lab
docker compose up -d arcadedb
docker compose up -d age
```

```bash
# or all at once
docker compose up -d
```

LadybugDB is embedded, so the database itself is not a service. It lives in a file
created with the `lbug` shell (see [Seeding LadybugDB](#seeding-ladybugdb)), and
`ladybug-explorer` is a web UI for that file. Seed first, since the explorer opens the
database read-only and refuses to start without it:

```bash
docker compose up -d ladybug-explorer
```

## Web interfaces

| Database  | URL                        | Credentials              |
|-----------|----------------------------|--------------------------|
| Neo4j     | http://localhost:7474       | neo4j / benchmark        |
| Memgraph  | http://localhost:3000       | –                        |
| ArcadeDB  | http://localhost:2480       | root / benchmark         |
| Ladybug   | http://localhost:8000       | –                        |

Apache AGE has no web UI yet (planned for a later iteration, built the same way as
`ladybug-explorer` — see [Seeding Apache AGE](#seeding-apache-age)); connect with `psql`
or any Postgres client instead.

## Bolt ports

| Database  | Port  |
|-----------|-------|
| Neo4j     | 7687  |
| Memgraph  | 7688  |

## Postgres ports

| Database   | Port  | Credentials              |
|------------|-------|--------------------------|
| Apache AGE | 5433  | postgres / benchmark     |
     
## Data

CSV files in `data/` are mounted into each container:

| Database  | Path in container                     |
|-----------|---------------------------------------|
| Neo4j     | `/var/lib/neo4j/import/`              |
| Memgraph  | `/usr/lib/memgraph/import-data/`      |
| ArcadeDB  | `/home/arcadedb/import/`              |
| Ladybug Explorer | `/data/` (read-only)           |
| Apache AGE | `/data/` (read-only)                  |

The `lbug` shell reads `data/` straight from the repo, and the database file goes in `ladybug/`,
which is mounted at `/database` in the explorer.

Seed scripts are located in `seed/`.

### Seeding ArcadeDB

`seed/seed-arcadedb.sql` is a single sqlscript covering the whole ingest — schema,
CSV import, indexes and edges. Create the database once, then run the file:

```bash
curl -u root:benchmark -X POST http://localhost:2480/api/v1/server \
     -H 'Content-Type: application/json' \
     -d '{"command":"create database benchmark"}'

curl -u root:benchmark -X POST http://localhost:2480/api/v1/command/benchmark \
     -H 'Content-Type: application/json' \
     --data-binary @<(jq -Rs '{language:"sqlscript", command:.}' seed/seed-arcadedb.sql)
```

It prints the record count per type when done, and re-running it re-seeds from
scratch. Studio (http://localhost:2480) works too — paste the file in and set the
language to `sqlscript`.

### Seeding Apache AGE

Apache AGE is a Postgres extension, not a separate server — the `age` service is a
plain Postgres 16 container with AGE preinstalled. `seed/seed-age.sql` creates the
`benchmark` graph, loads the CSVs and JSON into Postgres staging tables (AGE has no
LOAD CSV) and bulk-creates the Link/PlaceCenter/Location graph from them. Run it once
the container is healthy:

```bash
docker compose exec -T age psql -U postgres -d benchmark < seed/seed-age.sql
```

Re-running re-seeds from scratch — the graph is dropped and recreated at the top of the
script. The script ends by printing the same per-type/per-relationship counts as the
Ladybug check below, so no separate verification query is needed. Expected: Link 31970,
PlaceCenter 3092, Location 2779, NEXT_LINK 37134, HAS_LINK 3092, NEXT_LOCATION 1893,
HAS_PLACECENTER 3088. NEXT_LOCATION is 2 lower than the other seeds' 1895: `meters` is
computed in SQL (`length_km::float8 * 1000`) rather than Cypher's `toFloat(...)*1000`,
and for two section rows that float ends up bit-identical to another row's, so AGE's
`MERGE (from)-[:NEXT_LOCATION {meters: ...}]->(to)` — which matches on the property, like
the other seeds — collapses them into one edge. Apache AGE has no point type either (like
Ladybug), so `Location` stores `wkt` plus `lon`/`lat` doubles.

### Seeding LadybugDB

LadybugDB is embedded and has no server, so seeding runs on the host with the `lbug`
shell and reads `data/` directly. `seed/seed-ladybug.cypher` creates the schema, loads the
CSVs and JSON and builds the edges. Run it from the repo root (paths in the file are
relative). The database goes in `ladybug/`, where the explorer looks for it. The file is
single-writer, so stop the explorer first (`docker compose stop ladybug-explorer`):

```bash
lbug ladybug/benchmark.lbdb -i seed/seed-ladybug.cypher
```

`-i` prints nothing, so check the result with:

```bash
lbug ladybug/benchmark.lbdb <<'EOF'
MATCH (n:Link) RETURN 'Link' AS type, count(n) AS count
UNION ALL MATCH (n:PlaceCenter) RETURN 'PlaceCenter', count(n)
UNION ALL MATCH (n:Location) RETURN 'Location', count(n)
UNION ALL MATCH ()-[r:NEXT_LINK]->() RETURN 'NEXT_LINK', count(r)
UNION ALL MATCH ()-[r:HAS_LINK]->() RETURN 'HAS_LINK', count(r)
UNION ALL MATCH ()-[r:NEXT_LOCATION]->() RETURN 'NEXT_LOCATION', count(r)
UNION ALL MATCH ()-[r:HAS_PLACECENTER]->() RETURN 'HAS_PLACECENTER', count(r);
EOF
```

Expected: Link 31970, PlaceCenter 3092, Location 2779, NEXT_LINK 37134, HAS_LINK 3092,
NEXT_LOCATION 1895, HAS_PLACECENTER 3088. Re-running re-seeds from scratch. The JSON
extension is installed on first run (needs internet). Ladybug has no point type, so
`Location` stores `wkt` plus `lon`/`lat` doubles, and no secondary indexes exist.

The explorer is built from `docker/ladybug-explorer/` instead of pulled, because the
published `ghcr.io/ladybugdb/explorer` (0.19.1) cannot open a database written by `lbug`
0.20.4 (storage version 47 vs 43). If you change the `lbug` version, set `LBUG_VERSION`
in `docker-compose.yml` to match and run `docker compose build ladybug-explorer`.

## Shut down

```bash
docker compose down
```
