-- ArcadeDB seed — Link / PlaceCenter / Location graph
-- Loads data/link.csv, data/lank.csv, data/platsmitt.csv, data/rinf-op.csv,
-- data/rinf-sections.csv and data/trainstations.json, which docker-compose
-- mounts read-only at /home/arcadedb/import.

-- The whole file is ONE sqlscript. Create the database once:
--   curl -u root:benchmark -X POST http://localhost:2480/api/v1/server \
--        -H 'Content-Type: application/json' \
--        -d '{"command":"create database benchmark"}'
-- then run this file:
--   curl -u root:benchmark -X POST http://localhost:2480/api/v1/command/benchmark \
--        -H 'Content-Type: application/json' \
--        --data-binary @<(jq -Rs '{language:"sqlscript", command:.}' seed/seed-arcadedb.sql)
-- Studio works too: paste the file in and set the language to "sqlscript".

-- Re-running is safe: the script drops and recreates every type it owns.

-- Ingest strategy:
--   1. CSVs and JSON are bulk-loaded with IMPORT DATABASE into throwaway staging
--      types, reading only the columns we actually need.
--   2. Vertices are projected out of staging with FOREACH, which renames the
--      source columns into the schema shared with the Neo4j/Memgraph seeds
--      (id / fromNode / toNode / length / signature / name / plc / rinfUri).
--      INSERT ... FROM SELECT cannot be used here: it resolves its source type
--      while the script is parsed, i.e. before IMPORT DATABASE has created it.
--   3. Indexes are created AFTER the bulk load, so no index has to be maintained
--      row by row during ingest.
--   4. Edges are built last, driven by the indexes from step 3.

-- ---------------------------------------------------------------- schema ----

DROP TYPE NEXT_LINK IF EXISTS UNSAFE;
DROP TYPE NEXT_LOCATION IF EXISTS UNSAFE;
DROP TYPE HAS_LINK IF EXISTS UNSAFE;
DROP TYPE HAS_PLACECENTER IF EXISTS UNSAFE;
DROP TYPE Link IF EXISTS UNSAFE;
DROP TYPE PlaceCenter IF EXISTS UNSAFE;
DROP TYPE Location IF EXISTS UNSAFE;
DROP TYPE LinkCsv IF EXISTS;
DROP TYPE LankCsv IF EXISTS;
DROP TYPE PlaceCsv IF EXISTS;
DROP TYPE RinfOpCsv IF EXISTS;
DROP TYPE RinfSectionsCsv IF EXISTS;
DROP TYPE LocationImport IF EXISTS UNSAFE;

CREATE VERTEX TYPE Link;
CREATE PROPERTY Link.id STRING;
CREATE PROPERTY Link.fromNode STRING;
CREATE PROPERTY Link.toNode STRING;
CREATE PROPERTY Link.length FLOAT;

CREATE VERTEX TYPE PlaceCenter;
CREATE PROPERTY PlaceCenter.id STRING;
CREATE PROPERTY PlaceCenter.signature STRING;
CREATE PROPERTY PlaceCenter.name STRING;
CREATE PROPERTY PlaceCenter.plc INTEGER;

CREATE VERTEX TYPE Location;
CREATE PROPERTY Location.signature STRING;
CREATE PROPERTY Location.rinfUri STRING;
CREATE PROPERTY Location.rinfSignature STRING;
CREATE PROPERTY Location.name STRING;
CREATE PROPERTY Location.type STRING;
CREATE PROPERTY Location.wkt STRING;
CREATE PROPERTY Location.plc STRING;

CREATE EDGE TYPE NEXT_LINK;
CREATE EDGE TYPE HAS_LINK;
CREATE EDGE TYPE HAS_PLACECENTER;
CREATE EDGE TYPE NEXT_LOCATION;
CREATE PROPERTY NEXT_LOCATION.meters FLOAT;

-- --------------------------------------------------------- Link vertices ----
-- Create Link nodes from CSV
IMPORT DATABASE file:///home/arcadedb/import/link.csv WITH
  documentType = LinkCsv,
  documentPropertiesInclude = 'LINKSEQUENCE_OID,START_NODE_OID,END_NODE_OID',
  maxPropertySize = 1000000,
  commitEvery = 50000;

LET $linkRows = SELECT FROM LinkCsv;
FOREACH ($r IN $linkRows) {
  INSERT INTO Link SET id = $r.LINKSEQUENCE_OID, fromNode = $r.START_NODE_OID, toNode = $r.END_NODE_OID;
}

DROP TYPE LinkCsv;

CREATE INDEX ON Link (id) UNIQUE;
CREATE INDEX ON Link (fromNode) NOTUNIQUE;
CREATE INDEX ON Link (toNode) NOTUNIQUE;

-- ------------------------------------------------------ NEXT_LINK edges  ----
-- A link is followed by every link that starts where it ends.
-- The Link(fromNode) index makes each lookup an index probe instead of a scan.

LET $links = SELECT FROM Link;
FOREACH ($l IN $links) {
  CREATE EDGE NEXT_LINK FROM $l TO (SELECT FROM Link WHERE fromNode = $l.toNode);
}

-- ------------------------------------------------------ Link.length      ----
-- lank.csv carries a WKT geometry column far above the CSV parser's default
-- 4096 chars per column, hence maxPropertySize.

IMPORT DATABASE file:///home/arcadedb/import/lank.csv WITH
  documentType = LankCsv,
  documentPropertiesInclude = 'ELEMENT_ID,Sparlangd',
  maxPropertySize = 1000000,
  commitEvery = 50000;

LET $lengths = SELECT ELEMENT_ID, Sparlangd FROM LankCsv;
FOREACH ($r IN $lengths) {
  UPDATE Link SET length = $r.Sparlangd WHERE id = $r.ELEMENT_ID;
}

DROP TYPE LankCsv;

-- --------------------------------------------------- PlaceCenter + edges ----
-- platsmitt.csv is keyed by the id of the Link the place centre sits on.

-- Create PlaceCenter nodes from CSV
IMPORT DATABASE file:///home/arcadedb/import/platsmitt.csv WITH
  documentType = PlaceCsv,
  documentPropertiesInclude = 'ELEMENT_ID,Signatur,Platsnamn,Plc_kod',
  maxPropertySize = 1000000,
  commitEvery = 50000;

LET $placeRows = SELECT FROM PlaceCsv;
FOREACH ($r IN $placeRows) {
  INSERT INTO PlaceCenter SET id = $r.ELEMENT_ID, signature = $r.Signatur.toUpperCase(), name = $r.Platsnamn, plc = $r.Plc_kod;
}

DROP TYPE PlaceCsv;

CREATE INDEX ON PlaceCenter (signature) NOTUNIQUE;

LET $places = SELECT FROM PlaceCenter;
FOREACH ($p IN $places) {
  CREATE EDGE HAS_LINK FROM $p TO (SELECT FROM Link WHERE id = $p.id);
}

-- ------------------------------------------------------------- Location  ----
-- rinf-op.csv is the master for Location: every row is a RINF operational
-- point, keyed by its uopid with the country prefix stripped and upper-cased
-- (the same signature PlaceCenter and Link ultimately key against). The file
-- lists 4424 rows for only 2123 distinct signatures, so rows are merged by
-- signature (UPSERT) rather than plain-inserted.

-- No WKT parsing/conversion is needed here (unlike the Neo4j/Memgraph seeds):
-- ArcadeDB has native geospatial support and the raw WKT string is stored as-is.

IMPORT DATABASE file:///home/arcadedb/import/rinf-op.csv WITH
  documentType = RinfOpCsv,
  delimiter = ';',
  documentPropertiesInclude = 'era_OperationalPoint,era_OperationalPoint_era_opName,era_OperationalPoint_era_uopid,era_OperationalPoint_era_opType__label,era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT',
  maxPropertySize = 1000000,
  commitEvery = 50000;

CREATE INDEX ON Location (signature) UNIQUE;

-- UPSERT needs that index to exist; it also keeps this section safe to run on
-- its own against a Location type that is already populated.

-- UPSERT's WHERE must reference the field expression directly (a LET-bound
-- variable there fails with "Upsert must involve an index"), so the signature
-- expression is repeated rather than computed once.
LET $rinfOpRows = SELECT FROM RinfOpCsv;
FOREACH ($r IN $rinfOpRows) {
  UPDATE Location
    SET signature     = $r.era_OperationalPoint_era_uopid.replace('SE','').toUpperCase(),
        rinfUri       = $r.era_OperationalPoint,
        name          = $r.era_OperationalPoint_era_opName,
        rinfSignature = $r.era_OperationalPoint_era_uopid,
        type          = $r.era_OperationalPoint_era_opType__label,
        wkt           = $r.era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT
    UPSERT
    WHERE signature = $r.era_OperationalPoint_era_uopid.replace('SE','').toUpperCase();
}

DROP TYPE RinfOpCsv;

-- Looked up later (NEXT_LOCATION edges below, and by application queries), so
-- it needs its own index. Not unique: a handful of rinfUri values get
-- overwritten by a later duplicate row sharing the same signature.
CREATE INDEX ON Location (rinfUri) NOTUNIQUE;

-- ---------------------------------------------------- NEXT_LOCATION edges ----
-- rinf-sections.csv connects two operational points (by rinfUri) with a
-- section length in kilometres; stored in metres like the other seeds.

IMPORT DATABASE file:///home/arcadedb/import/rinf-sections.csv WITH
  documentType = RinfSectionsCsv,
  delimiter = ';',
  documentPropertiesInclude = 'era_SectionOfLine_era_opStart,era_SectionOfLine_era_opEnd,era_SectionOfLine_era_lengthOfSectionOfLine',
  maxPropertySize = 1000000,
  commitEvery = 50000;

LET $sectionRows = SELECT FROM RinfSectionsCsv;
FOREACH ($r IN $sectionRows) {
  CREATE EDGE NEXT_LOCATION
    FROM (SELECT FROM Location WHERE rinfUri = $r.era_SectionOfLine_era_opStart)
    TO (SELECT FROM Location WHERE rinfUri = $r.era_SectionOfLine_era_opEnd)
    SET meters = $r.era_SectionOfLine_era_lengthOfSectionOfLine * 1000;
}

DROP TYPE RinfSectionsCsv;

-- ------------------------------------------------------- trainstations.json --
-- Enriches Location with TRV data (advertised name, PLC code) and links it to
-- its PlaceCenter. trainstations.json is one object wrapping a "TrainStation"
-- array; the importer chokes on leading whitespace before the opening brace,
-- so the file must not be indented as a whole.

-- Identity is LocationSignature, not PrimaryLocationCode: 255 of the 1750 records
-- carry no PrimaryLocationCode, and 14 codes are shared between a Swedish and a
-- Danish station, so keying on it silently drops stations on import and inserts
-- the code-less ones afresh on every run. LocationSignature is unique across all
-- 1750 records and is the same identifier PlaceCenter.signature and rinf-op.csv's
-- derived signature use.

IMPORT DATABASE file:///home/arcadedb/import/trainstations.json WITH
  mapping = {
    "TrainStation": [{
      "@cat": "d",
      "@type": "LocationImport",
      "@id": "LocationSignature",
      "@idType": "string",
      "@strategy": "merge"
    }]
  },
  commitEvery = 5000;

-- Reuses the Location(signature) unique index created above; UPSERT merges
-- into the rows rinf-op.csv already created rather than creating new ones.

LET $importedLocations = SELECT FROM LocationImport;
FOREACH ($source IN $importedLocations) {
  UPDATE Location
    SET signature = $source.LocationSignature.toUpperCase(),
        name      = $source.AdvertisedLocationName,
        plc       = $source.PrimaryLocationCode,
        wkt       = $source.Geometry.WGS84
    UPSERT
    WHERE signature = $source.LocationSignature.toUpperCase();
}
DROP TYPE LocationImport;

-- Create relationships from Location to PlaceCenter
LET $locations = SELECT FROM Location;
FOREACH ($l IN $locations) {
  CREATE EDGE HAS_PLACECENTER FROM $l TO (SELECT FROM PlaceCenter WHERE signature = $l.signature);
}

-- Geospatial index over the WKT string, built after both rinf-op.csv and
-- trainstations.json have written Location.wkt (there is no separate coords
-- property; the WKT string is the geometry).
-- Most rows are POINTs, but some rinf-op geometries are GEOMETRYCOLLECTIONs of
-- long LINESTRINGs (up to ~145k chars). At the default precision 11 (~2.4 m)
-- those explode into huge numbers of GeoHash cells and the build takes ~65 s;
-- precision 7 (~153 m) builds in ~3 s. Queries stay exact (the index only
-- pre-filters, then an exact predicate is applied).
CREATE INDEX ON Location (wkt) GEOSPATIAL METADATA { "precision": 7 };



-- ---------------------------------------------------------------- report ----