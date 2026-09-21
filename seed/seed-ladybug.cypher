// LadybugDB seed - Link / PlaceCenter / Location graph
// Loads data/link.csv, data/lank.csv, data/platsmitt.csv, data/rinf-op.csv,
// data/rinf-sections.csv and data/trainstations.json.
//
// Paths are relative to the working directory, so run from the repo root:
//   lbug benchmark.lbdb -i seed/seed-ladybug.cypher
// -i prints no results, see the README for a query that checks the counts.
// Do not pipe the file into the shell, its input buffer garbles long scripts.
// Re-running is safe, the script drops and recreates every table it owns.
//
// Differences from the Neo4j and Memgraph seeds:
//   - Strict schema. Node tables need a PRIMARY KEY, rel tables declare FROM/TO.
//   - No secondary indexes, so no CREATE INDEX statements.
//   - COPY reads columns positionally, so every CSV goes through a
//     LOAD FROM subquery that picks and converts the columns.
//   - from and to are reserved words, hence Link.fromNode and Link.toNode.
//   - No point type. Location keeps the raw wkt string plus lon/lat DOUBLEs,
//     which are NULL unless the WKT is a POINT.

// ---------------------------------------------------------------- schema ----

DROP TABLE IF EXISTS NEXT_LINK;
DROP TABLE IF EXISTS HAS_LINK;
DROP TABLE IF EXISTS NEXT_LOCATION;
DROP TABLE IF EXISTS HAS_PLACECENTER;
DROP TABLE IF EXISTS Link;
DROP TABLE IF EXISTS PlaceCenter;
DROP TABLE IF EXISTS Location;

INSTALL json;
LOAD json;

CREATE NODE TABLE Link(id STRING PRIMARY KEY, fromNode STRING, toNode STRING, length DOUBLE);
CREATE NODE TABLE PlaceCenter(id STRING PRIMARY KEY, signature STRING, name STRING, plc INT64);
CREATE NODE TABLE Location(
    signature STRING PRIMARY KEY,
    rinfUri STRING,
    rinfSignature STRING,
    name STRING,
    type STRING,
    plc INT64,
    wkt STRING,
    lon DOUBLE,
    lat DOUBLE
);

CREATE REL TABLE NEXT_LINK(FROM Link TO Link);
CREATE REL TABLE HAS_LINK(FROM PlaceCenter TO Link);
CREATE REL TABLE NEXT_LOCATION(FROM Location TO Location, meters DOUBLE);
CREATE REL TABLE HAS_PLACECENTER(FROM Location TO PlaceCenter);

// ------------------------------------------------------------ Link nodes ----
// Create Link nodes from link CSV (length is filled in from lank.csv below)

COPY Link FROM (
    LOAD FROM 'data/link.csv' (HEADER=true)
    RETURN LINKSEQUENCE_OID, START_NODE_OID, END_NODE_OID, CAST(NULL AS DOUBLE)
);

// A link is followed by every link that starts where it ends.
COPY NEXT_LINK FROM (
    MATCH (l1:Link), (l2:Link)
    WHERE l1.toNode = l2.fromNode
    RETURN l1.id, l2.id
);

// Update Link nodes with length from lank CSV
LOAD FROM 'data/lank.csv' (HEADER=true)
WITH ELEMENT_ID AS id, Sparlangd AS len
MATCH (l:Link {id: id})
SET l.length = CAST(len AS DOUBLE);

// ---------------------------------------------------- PlaceCenter nodes ----
// platsmitt.csv is keyed by the id of the Link the place centre sits on.

COPY PlaceCenter FROM (
    LOAD FROM 'data/platsmitt.csv' (HEADER=true)
    RETURN ELEMENT_ID, upper(Signatur), Platsnamn, CAST(Plc_kod AS INT64)
);

COPY HAS_LINK FROM (
    MATCH (p:PlaceCenter), (l:Link)
    WHERE p.id = l.id
    RETURN p.id, l.id
);

// -------------------------------------------------------- Location nodes ----
// rinf-op.csv is the master for Location, keyed by uopid with the country
// prefix stripped and upper-cased. 4424 rows map to ~2100 signatures, with the
// later row winning, so this is MERGE + SET (as in the Neo4j seed) rather than
// COPY, which would reject the duplicate primary keys.

LOAD FROM 'data/rinf-op.csv' (HEADER=true, DELIM=';', PARALLEL=false)
WITH
    upper(replace(era_OperationalPoint_era_uopid, 'SE', '')) AS signature,
    era_OperationalPoint AS uri,
    era_OperationalPoint_era_uopid AS uopid,
    era_OperationalPoint_era_opName AS name,
    era_OperationalPoint_era_opType__label AS type,
    era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT AS wkt
WITH signature, uri, uopid, name, type, wkt,
    CASE WHEN starts_with(wkt, 'POINT')
        THEN string_split(trim(replace(replace(replace(wkt, 'POINT', ''), '(', ''), ')', '')), ' ')
        ELSE NULL END AS coords
MERGE (l:Location {signature: signature})
SET l.rinfUri = uri,
    l.name = name,
    l.rinfSignature = uopid,
    l.type = type,
    l.wkt = wkt,
    l.lon = CAST(coords[1] AS DOUBLE),
    l.lat = CAST(coords[2] AS DOUBLE);

// Create NEXT_LOCATION relationships between Location nodes based on
// rinf-sections.csv. Section length is in kilometres, stored here in metres.
COPY NEXT_LOCATION FROM (
    LOAD FROM 'data/rinf-sections.csv' (HEADER=true, DELIM=';')
    WITH
        era_SectionOfLine_era_opStart AS opStart,
        era_SectionOfLine_era_opEnd AS opEnd,
        era_SectionOfLine_era_lengthOfSectionOfLine AS km
    MATCH (a:Location {rinfUri: opStart})
    MATCH (b:Location {rinfUri: opEnd})
    RETURN DISTINCT a.signature, b.signature, CAST(km AS DOUBLE) * 1000
);

// ----------------------------------------------------- trainstations.json ----
// Enriches Location with TRV data (advertised name, PLC code) and creates
// stations that rinf-op.csv does not know. Identity is LocationSignature, not
// PrimaryLocationCode (255 records carry none, 14 codes are shared).

LOAD FROM 'data/trainstations.json'
UNWIND TrainStation AS row
WITH row, string_split(trim(replace(replace(replace(row.Geometry.WGS84, 'POINT', ''), '(', ''), ')', '')), ' ') AS coords
MERGE (l:Location {signature: upper(row.LocationSignature)})
SET l.name = row.AdvertisedLocationName,
    l.plc = CAST(row.PrimaryLocationCode AS INT64),
    l.wkt = row.Geometry.WGS84,
    l.lon = CAST(coords[1] AS DOUBLE),
    l.lat = CAST(coords[2] AS DOUBLE);

// Create relationships from Location to PlaceCenter
COPY HAS_PLACECENTER FROM (
    MATCH (l:Location), (pc:PlaceCenter)
    WHERE l.signature = pc.signature
    RETURN l.signature, pc.id
);
