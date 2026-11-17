// Seed for Relate 1.1.0. Based on seed-neo4j.cypher, with these differences:
//  - Run it through seed/seed-relate.sh, which also passes trainstations.json as the
//    parameter $ts (--fetch-params) and points --load-csv-dir at a prepared copy of data/.
//    Relate has no APOC, so apoc.load.json is replaced by UNWIND $ts.TrainStation.
//  - lank.csv is trimmed to the two columns used (ELEMENT_ID, Sparlangd) by the shell
//    script: the original is 19 MB and LOAD CSV in the CLI refuses files over 8 MiB.
//  - Location.coords is only set when the WKT is a POINT; point() fails on null.
//  - CREATE instead of MERGE for Link/PlaceCenter (the ids are unique).

// Start from scratch
MATCH (n) DETACH DELETE n;

CREATE CONSTRAINT link_id IF NOT EXISTS FOR (n:Link) REQUIRE n.id IS UNIQUE;
CREATE CONSTRAINT placecenter_id IF NOT EXISTS FOR (n:PlaceCenter) REQUIRE n.id IS UNIQUE;
CREATE CONSTRAINT location_signature IF NOT EXISTS FOR (n:Location) REQUIRE n.signature IS UNIQUE;
CREATE INDEX link_from IF NOT EXISTS FOR (n:Link) ON (n.from);
CREATE INDEX placecenter_signature IF NOT EXISTS FOR (n:PlaceCenter) ON (n.signature);
CREATE INDEX location_rinfUri IF NOT EXISTS FOR (n:Location) ON (n.rinfUri);

// Create Link nodes from link CSV
LOAD CSV WITH HEADERS FROM 'file:///link.csv' AS row
CREATE (:Link {id: row.LINKSEQUENCE_OID, from: row.START_NODE_OID, to: row.END_NODE_OID});

MATCH (l1:Link)
MATCH (l2:Link {from: l1.to})
CREATE (l1)-[:NEXT_LINK]->(l2);

// Update Link nodes with length from lank CSV
LOAD CSV WITH HEADERS FROM 'file:///lank.csv' AS row
MATCH (l:Link {id: row.ELEMENT_ID})
SET l.length = toFloat(row.Sparlangd);

// Create PlaceCenter nodes from CSV
LOAD CSV WITH HEADERS FROM 'file:///platsmitt.csv' AS row
CREATE (:PlaceCenter {id: row.ELEMENT_ID, signature: toUpper(row.Signatur),
                      name: row.Platsnamn, plc: toInteger(row.Plc_kod)});

LOAD CSV WITH HEADERS FROM 'file:///platsmitt.csv' AS row
MATCH (p:PlaceCenter {id: row.ELEMENT_ID})
MATCH (l:Link {id: row.ELEMENT_ID})
CREATE (p)-[:HAS_LINK]->(l);

// Create Location from rinf-op.csv
LOAD CSV WITH HEADERS FROM 'file:///rinf-op.csv' AS row
FIELDTERMINATOR ';'
WITH row,
    toUpper(replace(row.era_OperationalPoint_era_uopid, 'SE', '')) AS signature,
    split(trim(replace(replace(replace(row.era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT, 'POINT', ''), '(', ''), ')', '')), ' ') AS coords
MERGE (l:Location {signature: signature})
SET l.rinfUri = row.era_OperationalPoint,
  l.name = row.era_OperationalPoint_era_opName,
  l.rinfSignature = row.era_OperationalPoint_era_uopid,
  l.type = row.era_OperationalPoint_era_opType__label,
  l.wkt = row.era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT,
  l.coords = CASE WHEN toFloat(coords[0]) IS NOT NULL AND toFloat(coords[1]) IS NOT NULL
    THEN point({longitude: toFloat(coords[0]), latitude: toFloat(coords[1]), crs: 'wgs-84'}) END;

// Create NEXT_LOCATION relationships between Location nodes
LOAD CSV WITH HEADERS FROM 'file:///rinf-sections.csv' AS row
FIELDTERMINATOR ';'
MATCH (from:Location {rinfUri: row.era_SectionOfLine_era_opStart})
MATCH (to:Location {rinfUri: row.era_SectionOfLine_era_opEnd})
MERGE (from)-[:NEXT_LOCATION {meters: toFloat(row.era_SectionOfLine_era_lengthOfSectionOfLine) * 1000}]->(to);

// Update Location nodes from TRV-JSON and create relationships to PlaceCenter nodes
UNWIND $ts.TrainStation AS row
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

// Counts
MATCH (n:Link) RETURN 'Link' AS type, count(n) AS count
UNION ALL MATCH (n:PlaceCenter) RETURN 'PlaceCenter' AS type, count(n) AS count
UNION ALL MATCH (n:Location) RETURN 'Location' AS type, count(n) AS count
UNION ALL MATCH ()-[r:NEXT_LINK]->() RETURN 'NEXT_LINK' AS type, count(r) AS count
UNION ALL MATCH ()-[r:HAS_LINK]->() RETURN 'HAS_LINK' AS type, count(r) AS count
UNION ALL MATCH ()-[r:NEXT_LOCATION]->() RETURN 'NEXT_LOCATION' AS type, count(r) AS count
UNION ALL MATCH ()-[r:HAS_PLACECENTER]->() RETURN 'HAS_PLACECENTER' AS type, count(r) AS count;
