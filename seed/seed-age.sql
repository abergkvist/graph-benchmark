-- Apache AGE seed — Link / PlaceCenter / Location graph
-- Loads data/link.csv, data/lank.csv, data/platsmitt.csv, data/rinf-op.csv,
-- data/rinf-sections.csv and data/trainstations.json, which docker-compose
-- mounts read-only at /data inside the age container.

-- Run against the `benchmark` database created by the image on first boot:
--   docker compose exec -T age psql -U postgres -d benchmark < seed/seed-age.sql
-- Re-running is safe: the graph is dropped and recreated at the top.

-- Ingest strategy:
--   AGE has no LOAD CSV, so CSVs/JSON are loaded server-side into plain
--   Postgres staging tables first (COPY for CSV, pg_read_file for the JSON,
--   since it isn't line-delimited). Vertices are then bulk-created with a
--   single UNWIND per staging table instead of once per row: the whole
--   table is aggregated into one JSON value shaped like {"rows": [...]}.
--   cypher()'s third argument (the query parameters) must be an actual bind
--   parameter, not an expression — passing a literal or a subquery both fail
--   with "third argument of cypher function must be a parameter" — so each
--   UNWIND block runs inside a DO block that computes the JSON text, then
--   EXECUTEs a statement referencing $1 as that argument, binding the text
--   (cast to agtype) via EXECUTE ... USING.
--   Edges either reuse the same UNWIND+MATCH approach (when they need a
--   row-carried property, e.g. NEXT_LOCATION.meters) or a plain MATCH/MATCH
--   cartesian join keyed on the properties already on the vertices
--   (NEXT_LINK, HAS_LINK, HAS_PLACECENTER), mirroring the Neo4j seed; those
--   take no parameters so they call cypher() directly.
--   Property indexes are created right after each label's vertices exist,
--   using AGE's documented agtype_access_operator index pattern, since the
--   MATCH statements below rely on them for the join.

CREATE EXTENSION IF NOT EXISTS age;
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'benchmark') THEN
    PERFORM drop_graph('benchmark', true);
  END IF;
END $$;

SELECT create_graph('benchmark');

-- ------------------------------------------------------------- staging  ----

DROP TABLE IF EXISTS link_csv, lank_csv, platsmitt_csv, rinfop_csv, rinfsections_csv;

CREATE TABLE link_csv (
  id text, linksequence_oid text, valid_from text, valid_to text,
  start_node_oid text, end_node_oid text, start_measure text, end_measure text,
  length text, extent_length text
);
COPY link_csv FROM '/data/link.csv' WITH (FORMAT csv, HEADER true);

CREATE TABLE lank_csv (
  wkt text, id text, element_id text, valid_from text, valid_to text,
  start_measure text, end_measure text, extent_length text, orglank_id_plnfr text,
  bisobjektnr text, bisobjekttypnr text, kmtal text, kmtalti text, lanklangd text,
  lnr text, nodnrfr text, nodnrti text, nodsignfr text, nodsignti text, plnrti text,
  plsignfr text, plsignti text, schematiska_koordinater text, senast_andrad_orglank text,
  sparlangd text
);
COPY lank_csv FROM '/data/lank.csv' WITH (FORMAT csv, HEADER true);

CREATE TABLE platsmitt_csv (
  id text, element_id text, valid_from text, valid_to text, measure text,
  bisobjektnr text, bisobjekttypnr text, dignitet text, easting text,
  inkopplingsdatum text, kmtal text, kmtalti text, moh text, northing text,
  platsnamn text, platsstatus text, platstyp text, platstyp_beskr text,
  plc_kod text, signatur text
);
COPY platsmitt_csv FROM '/data/platsmitt.csv' WITH (FORMAT csv, HEADER true);

CREATE TABLE rinfop_csv (
  era_operationalpoint text, era_optype text, era_optype_label text, era_uopid text,
  era_primarylocation text, era_primarylocation_label text, wkt text, opname text,
  in_country text, in_country_label text
);
COPY rinfop_csv FROM '/data/rinf-op.csv' WITH (FORMAT csv, HEADER true, DELIMITER ';');

CREATE TABLE rinfsections_csv (
  era_sectionofline text, opstart text, opstart_label text, national_line text,
  length_km text, opend text, opend_label text, in_country text, in_country_label text,
  type_col text, label_col text
);
COPY rinfsections_csv FROM '/data/rinf-sections.csv' WITH (FORMAT csv, HEADER true, DELIMITER ';');

-- --------------------------------------------------------- Link vertices ----

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object(
           'id', id, 'fromNode', "fromNode", 'toNode', "toNode")))::text
    INTO params_json
    FROM (SELECT linksequence_oid AS id, start_node_oid AS "fromNode", end_node_oid AS "toNode"
          FROM link_csv) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      CREATE (:Link {id: row.id, fromNode: row.fromNode, toNode: row.toNode})
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

CREATE INDEX ON benchmark."Link" (ag_catalog.agtype_access_operator(properties, '"id"'::agtype));
CREATE INDEX ON benchmark."Link" (ag_catalog.agtype_access_operator(properties, '"fromNode"'::agtype));
CREATE INDEX ON benchmark."Link" (ag_catalog.agtype_access_operator(properties, '"toNode"'::agtype));

-- ------------------------------------------------------ NEXT_LINK edges  ----
-- A link is followed by every link that starts where it ends.

SELECT * FROM cypher('benchmark', $$
  MATCH (l1:Link), (l2:Link)
  WHERE l2.fromNode = l1.toNode
  CREATE (l1)-[:NEXT_LINK]->(l2)
$$) AS (a agtype);

-- ------------------------------------------------------ Link.length      ----

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object('id', id, 'length', length)))::text
    INTO params_json
    FROM (SELECT element_id AS id, sparlangd::float8 AS length FROM lank_csv) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      MATCH (l:Link {id: row.id})
      SET l.length = row.length
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

-- --------------------------------------------------- PlaceCenter + edges ----
-- platsmitt.csv is keyed by the id of the Link the place centre sits on.

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object(
           'id', id, 'signature', signature, 'name', name, 'plc', plc)))::text
    INTO params_json
    FROM (SELECT element_id AS id, upper(signatur) AS signature, platsnamn AS name,
                 NULLIF(plc_kod, '')::int AS plc
          FROM platsmitt_csv) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      CREATE (:PlaceCenter {id: row.id, signature: row.signature, name: row.name, plc: row.plc})
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

CREATE INDEX ON benchmark."PlaceCenter" (ag_catalog.agtype_access_operator(properties, '"id"'::agtype));
CREATE INDEX ON benchmark."PlaceCenter" (ag_catalog.agtype_access_operator(properties, '"signature"'::agtype));

SELECT * FROM cypher('benchmark', $$
  MATCH (p:PlaceCenter), (l:Link)
  WHERE p.id = l.id
  CREATE (p)-[:HAS_LINK]->(l)
$$) AS (a agtype);

-- ------------------------------------------------------------- Location  ----
-- rinf-op.csv is the master for Location: every row is a RINF operational
-- point, keyed by its uopid with the country prefix stripped and upper-cased
-- (the same signature PlaceCenter and Link ultimately key against). The file
-- lists more rows than distinct signatures, so rows are merged by signature
-- (MERGE) rather than plain-created.
--
-- AGE has no point type (like Ladybug), so Location stores wkt plus lon/lat
-- doubles, parsed out of the WKT "POINT(lon lat)" string here in SQL rather
-- than in cypher.

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object(
           'signature', signature, 'rinfUri', "rinfUri", 'name', name,
           'rinfSignature', "rinfSignature", 'type', type, 'wkt', wkt,
           'lon', lon, 'lat', lat)))::text
    INTO params_json
    FROM (
      SELECT upper(replace(era_uopid, 'SE', '')) AS signature,
             era_operationalpoint AS "rinfUri",
             opname AS name,
             era_uopid AS "rinfSignature",
             era_optype_label AS type,
             wkt AS wkt,
             (regexp_match(wkt, 'POINT\(([-0-9.]+) ([-0-9.]+)\)'))[1]::float8 AS lon,
             (regexp_match(wkt, 'POINT\(([-0-9.]+) ([-0-9.]+)\)'))[2]::float8 AS lat
      FROM rinfop_csv
    ) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      MERGE (l:Location {signature: row.signature})
      SET l.rinfUri = row.rinfUri,
          l.name = row.name,
          l.rinfSignature = row.rinfSignature,
          l.type = row.type,
          l.wkt = row.wkt,
          l.lon = row.lon,
          l.lat = row.lat
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

CREATE INDEX ON benchmark."Location" (ag_catalog.agtype_access_operator(properties, '"signature"'::agtype));
CREATE INDEX ON benchmark."Location" (ag_catalog.agtype_access_operator(properties, '"rinfUri"'::agtype));
CREATE INDEX ON benchmark."Location" (ag_catalog.agtype_access_operator(properties, '"rinfSignature"'::agtype));

-- ---------------------------------------------------- NEXT_LOCATION edges ----
-- rinf-sections.csv connects two operational points (by rinfUri) with a
-- section length in kilometres; stored in metres like the other seeds.

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object(
           'fromUri', "fromUri", 'toUri', "toUri", 'meters', meters)))::text
    INTO params_json
    FROM (SELECT opstart AS "fromUri", opend AS "toUri", length_km::float8 * 1000 AS meters
          FROM rinfsections_csv) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      MATCH (from:Location {rinfUri: row.fromUri})
      MATCH (to:Location {rinfUri: row.toUri})
      MERGE (from)-[:NEXT_LOCATION {meters: row.meters}]->(to)
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

-- ------------------------------------------------------- trainstations.json --
-- Enriches Location with TRV data (advertised name, PLC code) and links it to
-- its PlaceCenter. The file is one JSON object wrapping a "TrainStation"
-- array, so it's read whole with pg_read_file rather than COPY.
--
-- Identity is LocationSignature, not PrimaryLocationCode, for the same reason
-- as the other seeds: some records carry no PrimaryLocationCode and some
-- codes are shared between a Swedish and a Danish station, so keying on it
-- would silently drop or merge the wrong stations. LocationSignature is
-- unique across all records and is the same identifier the rinf-derived
-- signature above uses.

DO $do$
DECLARE
  params_json text;
BEGIN
  SELECT jsonb_build_object('rows', jsonb_agg(jsonb_build_object(
           'signature', signature, 'name', name, 'plc', plc, 'wkt', wkt,
           'lon', lon, 'lat', lat)))::text
    INTO params_json
    FROM (
      SELECT upper(station->>'LocationSignature') AS signature,
             station->>'AdvertisedLocationName' AS name,
             NULLIF(station->>'PrimaryLocationCode', '')::int AS plc,
             station->'Geometry'->>'WGS84' AS wkt,
             (regexp_match(station->'Geometry'->>'WGS84', 'POINT\(([-0-9.]+) ([-0-9.]+)\)'))[1]::float8 AS lon,
             (regexp_match(station->'Geometry'->>'WGS84', 'POINT\(([-0-9.]+) ([-0-9.]+)\)'))[2]::float8 AS lat
      FROM jsonb_array_elements(
        pg_read_file('/data/trainstations.json')::jsonb -> 'TrainStation'
      ) AS station
    ) t;

  EXECUTE $q$
    SELECT * FROM cypher('benchmark', $cy$
      UNWIND $rows AS row
      MERGE (l:Location {signature: row.signature})
      SET l.name = row.name,
          l.plc = row.plc,
          l.wkt = row.wkt,
          l.lon = row.lon,
          l.lat = row.lat
    $cy$, $1) AS (a agtype)
  $q$ USING params_json::agtype;
END
$do$;

-- Create relationships from Location to PlaceCenter

SELECT * FROM cypher('benchmark', $$
  MATCH (l:Location), (p:PlaceCenter)
  WHERE l.signature = p.signature
  CREATE (l)-[:HAS_PLACECENTER]->(p)
$$) AS (a agtype);

DROP TABLE link_csv, lank_csv, platsmitt_csv, rinfop_csv, rinfsections_csv;

-- ---------------------------------------------------------------- report ----

SELECT * FROM cypher('benchmark', $$ MATCH (n:Link) RETURN 'Link', count(n) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH (n:PlaceCenter) RETURN 'PlaceCenter', count(n) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH (n:Location) RETURN 'Location', count(n) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH ()-[r:NEXT_LINK]->() RETURN 'NEXT_LINK', count(r) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH ()-[r:HAS_LINK]->() RETURN 'HAS_LINK', count(r) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH ()-[r:NEXT_LOCATION]->() RETURN 'NEXT_LOCATION', count(r) $$) AS (type agtype, count agtype)
UNION ALL SELECT * FROM cypher('benchmark', $$ MATCH ()-[r:HAS_PLACECENTER]->() RETURN 'HAS_PLACECENTER', count(r) $$) AS (type agtype, count agtype);
