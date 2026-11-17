# graph-benchmark

Comparison of graph databases (Neo4j, Memgraph, ArcadeDB, LadybugDB, Apache AGE, Traverse, Relate) against the same dataset and queries.     

## Databases

| Database   | Website | Source / image |
|------------|---------|----------------|
| Neo4j      | [neo4j.com](https://neo4j.com) | [neo4j/neo4j](https://github.com/neo4j/neo4j) |
| Memgraph   | [memgraph.com](https://memgraph.com) | [memgraph/memgraph](https://github.com/memgraph/memgraph) |
| ArcadeDB   | [arcadedb.com](https://arcadedb.com) | [ArcadeData/arcadedb](https://github.com/ArcadeData/arcadedb) |
| LadybugDB  | [ladybugdb.com](https://ladybugdb.com) | [LadybugDB/ladybug](https://github.com/LadybugDB/ladybug) |
| Apache AGE | [age.apache.org](https://age.apache.org) | [apache/age](https://github.com/apache/age) |
| Traverse   | – | [truespar/traverse](https://github.com/truespar/traverse) ([Docker Hub](https://hub.docker.com/r/truespar/traverse)) |
| Relate     | [relatedb.ai](https://relatedb.ai) ([docs](https://relatedb.ai/docs/)) | [relatedb/relate](https://github.com/relatedb/relate) |

## Prerequisites

- Docker and Docker Compose
- For LadybugDB: the `lbug` shell installed on the host, used for seeding
- For Relate: the `relate` CLI installed on the host (`curl -sSfL https://relatedb.ai/install.sh | bash`, installs to `~/.local/bin`) and `python3`

## Starting databases

Start one at a time or all at once:

```bash
docker compose up -d neo4j
docker compose up -d memgraph memgraph-lab
docker compose up -d arcadedb
docker compose up -d age age-viewer
docker compose up -d traverse
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
| Apache AGE Viewer | http://localhost:3001 | see below              |
| Traverse Studio | http://localhost:7691 | API key `tvs_benchmark` |

`age-viewer` isn't configured via environment variables — it logs in through a form in
the browser. Use: host `age`, port `5432`, database `benchmark`, user `postgres`,
password `benchmark`, graph `benchmark`. (Host `age` is the docker-compose service name,
resolvable from inside the `age-viewer` container; from the host itself, e.g. `psql`, use
`localhost:5433` instead — see [Postgres ports](#postgres-ports).)

## Bolt ports

| Database  | Port  |
|-----------|-------|
| Neo4j     | 7687  |
| Memgraph  | 7688  |
| Traverse  | 7690  |
| Relate    | 7689 (only while `relate serve` runs, see [Seeding Relate](#seeding-relate)) |

Traverse's image (`truespar/traverse:0.9.0`) is published for `linux/amd64` only, so on
Apple Silicon it runs under emulation (`platform: linux/amd64` in `docker-compose.yml`).
Expect it to be slower than native, which matters when comparing timings. Studio and the
HTTP API (`/api`, docs at `/api/docs`) share port 7691.

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

### Seeding Traverse

`seed/seed-traverse.cypher` is `seed-neo4j.cypher` adapted to Traverse 0.9.0 (the header of
the file lists every difference and why). In Studio, open **Import Data**, pick the
**Cypher** tab and paste the file (or load it). It takes ~75 s under emulation. Don't paste
it in the query editor: that sends the whole text as one query and fails with
`unexpected token after query: Create`. Log in to Studio with the API key `tvs_benchmark`
(fixed in `docker-compose.yml`). The `./data` folder is mounted at `/import` in the
container, which is why the paths in the file are `file:///import/...`.

Re-running re-seeds from scratch. If a run is aborted midway, three helper indexes can be
left behind and the next run reports `index ... already exists` for them; run it once more
(the end of the file drops them). Expected counts are the same as for Ladybug below, with
NEXT_LOCATION 1895.

### Seeding Apache AGE

Apache AGE is a Postgres extension, not a separate server — the `age` service is a
plain Postgres 16 container with AGE preinstalled. Pinned to PG16 rather than the
newer PG18 build: `apache/age:release_PG18_1.8.0` segfaults the Postgres backend on
the bulk `UNWIND`+`CREATE` pattern below (reproduced — killed the whole connection
mid-seed). This is a known, still-open class of bug in that combination, not
something specific to this setup — see [apache/age#2450](https://github.com/apache/age/issues/2450)
and the linked mail-archive threads on `UNWIND`/`MERGE`/`CREATE` segfaults on PG18.
Revisit once upstream fixes land. `seed/seed-age.sql` creates the
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
Ladybug), so `Location` stores `wkt` plus `lon`/`lat` doubles, parsed out of the WKT
`POINT(lon lat)` string with a SQL regex. 336 of the 2779 Locations have no `lon`/`lat`:
their source WKT is a `LINESTRING`/`GEOMETRYCOLLECTION`, not a `POINT`, so the regex
correctly doesn't match rather than parsing garbage coordinates out of it (the other
seeds' string-splitting approach would silently do the latter for the same rows).

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

`age-viewer` has no published image, so `docker-compose.yml` builds it straight from
`apache/age-viewer`'s own `Dockerfile` on GitHub (a git build context — nothing vendored
in this repo). `docker compose up -d age-viewer` builds it on first run; `docker compose
build age-viewer` rebuilds it against whatever is currently on the upstream `main`
branch.

### Seeding Relate

Relate (https://relatedb.ai, v1.1.0) is embedded like LadybugDB: the database is a store
directory (`relate/benchmark`) opened by the `relate` CLI, not a docker-compose service
(no prebuilt image is published). It speaks Cypher and can serve Bolt, so Neo4j drivers
work. Seed from the repo root:

```bash
./seed/seed-relate.sh
```

It takes a couple of seconds and prints the per-type counts at the end, which match
Ladybug/Traverse (NEXT_LOCATION 1895). Re-running re-seeds from scratch. Differences from
`seed-neo4j.cypher` are listed in the header of `seed/seed-relate.cypher`: there is no
APOC, so the JSON is passed in with `--fetch-params`, and `LOAD CSV` refuses files over
8 MiB, so the script first writes a two-column copy of `lank.csv` to `relate/import/`.

Run queries against the store with the CLI (the store is single-writer, so `--read-only`
also lets a second process read it):

```bash
relate --database relate/benchmark --read-only "MATCH (n:Location) RETURN count(n)"
```

To use Bolt/HTTP clients, serve it (ports have no default, and `--auth none` turns off
the generated token; 7689 avoids clashing with the other Bolt ports):

```bash
relate serve --database relate/benchmark --read-only --bolt 7689 --http 7692 --auth none
```

The weighted shortest path query is not available: Relate has no APOC/GDS procedures and
no `WSHORTEST`-style syntax, see `queries/shortestpath.cypher`. Relate also rejects
explicit hop bounds over 500 by default (`--max-traversal-depth`, up to 2000).

## Shut down

```bash
docker compose down
```
