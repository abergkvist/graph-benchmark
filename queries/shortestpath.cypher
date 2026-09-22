/*
    Simple Shortest Path through the Link-node
*/ 

// Neo4j:
MATCH (:Location {signature:'HP'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l1:Link)
MATCH (:Location {signature:'MGB'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l2:Link)
with l1, l2 ORDER BY l1.id, l2.id limit 1
MATCH p = SHORTEST 1 (l1)-[:NEXT_LINK]-+(l2)
RETURN length(p);

// Memgraph:
MATCH (:Location {signature:'HP'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l1:Link)
MATCH (:Location {signature:'MGB'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l2:Link)
with l1, l2 ORDER BY l1.id, l2.id limit 1
MATCH p = (l1)-[:NEXT_LINK *BFS]-(l2)
RETURN length(p);

// ArcadeDB:
MATCH (:Location {signature:'HP'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l1:Link)
MATCH (:Location {signature:'MGB'})-[:HAS_PLACECENTER]->(:PlaceCenter)-[:HAS_LINK]->(l2:Link)
with l1, l2 ORDER BY l1.id, l2.id limit 1
MATCH p = shortestPath(
  (l1)-[:NEXT_LINK*]-(l2)
)
RETURN length(p);

// LadybugDB: intentionally left out. SHORTEST over NEXT_LINK (32k links, the HP-MGB
// route is thousands of hops) did not finish within 60 s.

// Apache AGE: intentionally left out. Its cypher subset has no shortestPath(),
// SHORTEST or *BFS/*WSHORTEST syntax at all (all four throw a parse error, not
// just a "too slow" timeout, on 1.6.0) and no APOC/algo-style procedure library
// either, so there's no built-in way to express this query. Rougher edges
// elsewhere too: the newer PG18 build of AGE (1.8.0) segfaults the Postgres
// backend on this repo's bulk seeding pattern — see docker-compose.yml and
// readme.md's "Seeding Apache AGE" section — which is why the seed and both
// queries below only run against the PG16 build.


/*
    Simple graph traversal
*/ 
// Neo4j, Memgraph, and ArcadeDB 
MATCH p=(:Location {signature:'FLN'})-[:NEXT_LOCATION*..12]-(:Location {signature:'AVKY'}) 
RETURN nodes(p), relationships(p)

// LadybugDB (TRAIL: no relationship is reused, like Neo4j's default)
MATCH p=(:Location {signature:'FLN'})-[:NEXT_LOCATION* TRAIL 1..12]-(:Location {signature:'AVKY'})
RETURN nodes(p), rels(p);

// Apache AGE: variable-length MATCH works the same as Neo4j/Memgraph/ArcadeDB,
// but every query has to go through the cypher() SQL wrapper (LOAD 'age'; SET
// search_path = ag_catalog, "$user", public; first, once per session):
SELECT * FROM cypher('benchmark', $$
  MATCH p=(:Location {signature:'FLN'})-[:NEXT_LOCATION*..12]-(:Location {signature:'AVKY'})
  RETURN nodes(p), relationships(p)
$$) AS (nodes agtype, relationships agtype);


/*
    Weighted Shortest Path through the Location-node
*/ 
// Neo4j:
MATCH (l1:Location {signature: 'HP'}), (l2:Location {signature: 'MGB'})
CALL apoc.algo.dijkstra(l1, l2, 'NEXT_LOCATION', 'meters')
YIELD path, weight
RETURN [n IN nodes(path) | n.name] AS route, weight;

// Memgraph:
MATCH (l1:Location {signature: 'HP'}), (l2:Location {signature: 'MGB'})
MATCH path=(l1)-[:NEXT_LOCATION *WSHORTEST (r, n | r.meters)]-(l2)
RETURN [n IN nodes(path) | n.name] AS route, 
  reduce(x = 0, r IN relationships(path) | x + r.meters) AS meters;

// ArcadeDB:
MATCH (l1:Location {signature: 'HP'}), (l2:Location {signature: 'MGB'})
CALL algo.dijkstra(l1, l2, 'NEXT_LOCATION', 'meters') YIELD path, weight
return [x in path.nodes | x.signature] as route, 
  reduce(x=0, y in path.relationships | x+y.meters) as length,
  weight, size(path.nodes) as count;

// LadybugDB: recursion is capped at 30 hops by default and the route is ~200 hops
CALL var_length_extend_max_depth=1000;
MATCH (l1:Location {signature: 'HP'}), (l2:Location {signature: 'MGB'})
MATCH p = (l1)-[e:NEXT_LOCATION* WSHORTEST(meters) 1..1000]-(l2)
RETURN properties(nodes(p), 'name') AS route, cost(e) AS meters;

// Apache AGE: intentionally left out, same reason as the unweighted shortest
// path above — no shortestPath()/SHORTEST/*WSHORTEST syntax and no dijkstra-style
// procedure to call instead. See that note for the PG16-vs-PG18 caveat too.