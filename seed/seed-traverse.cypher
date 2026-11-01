// Seed for Traverse 0.9.0. Based on seed-neo4j.cypher, with these differences:
//  - Paths are file:///import/... (docker-compose mounts ./data at /import; Traverse
//    resolves file:/// as an absolute path inside the container).
//  - Re-runnable: everything is wiped first, see the index notes below.
//  - CREATE instead of MERGE for Link/PlaceCenter. MERGE gets quadratically slower
//    (8000 Links took 29s vs 2.6s), and the ids are unique anyway.
//  - Location.coords is only set when the WKT is a POINT; point() throws on null, Neo4j returns null.
//  - FIELDTERMINATOR doesn't parse in 0.9.0, so the ';'-separated rinf files are read as
//    header-less CSV, the comma-split fields glued back together and split on ';'.
//  - The JSON is loaded in two halves: past ~1000 rows apoc.load.json + UNWIND exceeds
//    the per-query memory limit.

// Start from scratch
MATCH (n) DETACH DELETE n;

// Unique constraints double as the lookup indexes (Link.id, PlaceCenter.id and
// Location.signature are what the queries and the MERGEs below match on). Unlike
// CREATE INDEX, CREATE CONSTRAINT ... IF NOT EXISTS works in 0.9.0, so this part is
// safe to re-run.
CREATE CONSTRAINT link_id IF NOT EXISTS FOR (n:Link) REQUIRE n.id IS UNIQUE;
CREATE CONSTRAINT placecenter_id IF NOT EXISTS FOR (n:PlaceCenter) REQUIRE n.id IS UNIQUE;
CREATE CONSTRAINT location_signature IF NOT EXISTS FOR (n:Location) REQUIRE n.signature IS UNIQUE;

// The remaining properties aren't unique, so they need plain indexes. In 0.9.0
// CREATE INDEX ... IF NOT EXISTS errors if the index exists, and DROP INDEX ... IF EXISTS
// errors if it doesn't, so these are created for the load and dropped again at the end.
// Nothing in queries/ uses them. If a run is aborted midway, drop them by hand
// (link_from, placecenter_signature, location_rinfUri) before re-running.
CREATE INDEX link_from FOR (n:Link) ON (n.from);
CREATE INDEX placecenter_signature FOR (n:PlaceCenter) ON (n.signature);
CREATE INDEX location_rinfUri FOR (n:Location) ON (n.rinfUri);

// Create Link nodes from link CSV
LOAD CSV WITH HEADERS FROM 'file:///import/link.csv' AS row
CREATE (:Link {id: row.LINKSEQUENCE_OID, from: row.START_NODE_OID, to: row.END_NODE_OID});

MATCH (l1:Link)
MATCH (l2:Link {from: l1.to})
CREATE (l1)-[:NEXT_LINK]->(l2);

// Update Link nodes with length from lank CSV
LOAD CSV WITH HEADERS FROM 'file:///import/lank.csv' AS row
MATCH (l:Link {id: row.ELEMENT_ID})
SET l.length = toFloat(row.Sparlangd);

// Create PlaceCenter nodes from CSV
LOAD CSV WITH HEADERS FROM 'file:///import/platsmitt.csv' AS row
CREATE (:PlaceCenter {id: row.ELEMENT_ID, signature: toUpper(row.Signatur),
                      name: row.Platsnamn, plc: toInteger(row.Plc_kod)});

// A PlaceCenter and its Link share the same ELEMENT_ID. (Done as a separate pass:
// CREATE followed by MATCH in one query didn't finish within 120s.)
LOAD CSV WITH HEADERS FROM 'file:///import/platsmitt.csv' AS row
MATCH (p:PlaceCenter {id: row.ELEMENT_ID})
MATCH (l:Link {id: row.ELEMENT_ID})
CREATE (p)-[:HAS_LINK]->(l);

// Create Location from rinf-op.csv (';'-separated). Columns: 0 uri, 2 type label,
// 3 uopid, 6 WKT, 7 name
LOAD CSV FROM 'file:///import/rinf-op.csv' AS r
WITH reduce(line = r[0], i IN range(1, size(r) - 1) | line + ',' + r[i]) AS line
SKIP 1
WITH split(line, ';') AS f
WITH f, toUpper(replace(f[3], 'SE', '')) AS signature,
    split(trim(replace(replace(replace(f[6], 'POINT', ''), '(', ''), ')', '')), ' ') AS coords
MERGE (l:Location {signature: signature})
SET l.rinfUri = f[0],
  l.name = f[7],
  l.rinfSignature = f[3],
  l.type = f[2],
  l.wkt = f[6],
  l.coords = CASE WHEN toFloat(coords[0]) IS NOT NULL AND toFloat(coords[1]) IS NOT NULL
    THEN point({longitude: toFloat(coords[0]), latitude: toFloat(coords[1]), crs: 'wgs-84'}) END;

// Create NEXT_LOCATION relationships between Location nodes from rinf-sections.csv
// (';'-separated). Columns: 1 opStart, 4 length in km, 5 opEnd
LOAD CSV FROM 'file:///import/rinf-sections.csv' AS r
WITH reduce(line = r[0], i IN range(1, size(r) - 1) | line + ',' + r[i]) AS line
SKIP 1
WITH split(line, ';') AS f
MATCH (from:Location {rinfUri: f[1]})
MATCH (to:Location {rinfUri: f[5]})
MERGE (from)-[:NEXT_LOCATION {meters: toFloat(f[4]) * 1000}]->(to);

// Update Location nodes from TRV-JSON and create relationships to PlaceCenter nodes.
// 1750 stations, loaded as [0..875] and [875..1750]
CALL apoc.load.json('file:///import/trainstations.json') YIELD value
UNWIND value.TrainStation[0..875] AS row
WITH row, split(trim(replace(replace(replace(row.Geometry.WGS84, 'POINT', ''), '(', ''), ')', '')), ' ') AS coords
MERGE (s:Location {signature: toUpper(row.LocationSignature)})
SET s.name = row.AdvertisedLocationName,
    s.plc = toInteger(row.PrimaryLocationCode),
    s.wkt = row.Geometry.WGS84,
    s.coords = CASE WHEN toFloat(coords[0]) IS NOT NULL AND toFloat(coords[1]) IS NOT NULL
      THEN point({longitude: toFloat(coords[0]), latitude: toFloat(coords[1]), crs: 'wgs-84'}) END
WITH s
MATCH (pc:PlaceCenter {signature: s.signature})
MERGE (s)-[:HAS_PLACECENTER]->(pc);

CALL apoc.load.json('file:///import/trainstations.json') YIELD value
UNWIND value.TrainStation[875..1750] AS row
WITH row, split(trim(replace(replace(replace(row.Geometry.WGS84, 'POINT', ''), '(', ''), ')', '')), ' ') AS coords
MERGE (s:Location {signature: toUpper(row.LocationSignature)})
SET s.name = row.AdvertisedLocationName,
    s.plc = toInteger(row.PrimaryLocationCode),
    s.wkt = row.Geometry.WGS84,
    s.coords = CASE WHEN toFloat(coords[0]) IS NOT NULL AND toFloat(coords[1]) IS NOT NULL
      THEN point({longitude: toFloat(coords[0]), latitude: toFloat(coords[1]), crs: 'wgs-84'}) END
WITH s
MATCH (pc:PlaceCenter {signature: s.signature})
MERGE (s)-[:HAS_PLACECENTER]->(pc);

DROP INDEX link_from;
DROP INDEX placecenter_signature;
DROP INDEX location_rinfUri;
