CREATE CONSTRAINT link_id IF NOT EXISTS FOR (n:Link) REQUIRE n.id IS UNIQUE;
CREATE INDEX link_id IF NOT EXISTS FOR (n:Link) ON (n.id);
CREATE INDEX link_from IF NOT EXISTS FOR (n:Link) ON (n.from);
CREATE INDEX link_to IF NOT EXISTS FOR (n:Link) ON (n.to);
CREATE INDEX placecenter_signature IF NOT EXISTS FOR (n:PlaceCenter) ON (n.signature);
CREATE INDEX placecenter_id IF NOT EXISTS FOR (n:PlaceCenter) ON (n.id);
CREATE INDEX location_signature IF NOT EXISTS FOR (n:Location) ON (n.signature);
CREATE INDEX location_rinfSignature IF NOT EXISTS FOR (n:Location) ON (n.rinfSignature);
CREATE INDEX location_rinfUri IF NOT EXISTS FOR (n:Location) ON (n.rinfUri);


// Create Link nodes from link CSV
LOAD CSV WITH HEADERS FROM 'file:///link.csv' AS row
MERGE (l:Link {id:row.LINKSEQUENCE_OID})
SET l.from = row.START_NODE_OID, 
    l.to = row.END_NODE_OID;

MATCH (l1:Link)
MATCH (l2:Link {from:l1.to})
MERGE (l1)-[:NEXT_LINK]->(l2);

// Update Link nodes with length from lank CSV
LOAD CSV WITH HEADERS FROM 'file:///lank.csv' AS row
MATCH (l:Link {id: row.ELEMENT_ID})
SET l.length = toFloat(row.Sparlangd);

// Create PlaceCenter nodes from CSV
LOAD CSV WITH HEADERS FROM 'file:///platsmitt.csv' AS row
MERGE (p:PlaceCenter {id:row.ELEMENT_ID})
SET p.signature = toUpper(row.Signatur), p.name = row.Platsnamn,
p.plc = toInteger(row.Plc_kod)
with p, row
match (l:Link {id: row.ELEMENT_ID})
MERGE (p)-[r:HAS_LINK]->(l);

// Create Location from rinf-op.csv
LOAD CSV WITH HEADERS FROM 'file:///rinf-op.csv' AS row
FIELDTERMINATOR ';'

with row, 
    toUpper(replace(row.era_OperationalPoint_era_uopid,'SE','')) as signature,
    split(trim(replace(replace(replace(row.era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT, "POINT", ""), "(", ""), ")", "")), " ") AS coords

MERGE (l:Location {signature:signature})
SET l.rinfUri = row.era_OperationalPoint,
  l.name = row.era_OperationalPoint_era_opName,
  l.rinfSignature = row.era_OperationalPoint_era_uopid,
  l.type = row.era_OperationalPoint_era_opType__label,
  l.wkt = row.era_OperationalPoint_era_netReference_geosparql_hasGeometry_geosparql_asWKT,
  l.coords = point(
    {
        longitude: toFloat(coords[0]),
        latitude: toFloat(coords[1]),
        crs: 'wgs-84'
    });

// Create NEXT_SECTION relationships between Location nodes based on rinf-sections.csv
LOAD CSV WITH HEADERS FROM 'file:///rinf-sections.csv' AS row
    FIELDTERMINATOR ';'
with row
match (from:Location {rinfUri: row.era_SectionOfLine_era_opStart})
match (to:Location {rinfUri: row.era_SectionOfLine_era_opEnd})
merge (from)-[:NEXT_LOCATION {meters:toFloat(row.era_SectionOfLine_era_lengthOfSectionOfLine)*1000}]->(to);

// Update Location nodes from TRV-JSON and create relationships to PlaceCenter nodes
CALL apoc.load.json("file:///trainstations.json") YIELD value
UNWIND value.TrainStation AS row
with row, split(trim(replace(replace(replace(row.Geometry.WGS84, "POINT", ""), "(", ""), ")", "")), " ") AS coords
MERGE (s:Location {signature: toUpper(row.LocationSignature)})
SET s.name = row.AdvertisedLocationName,
    s.plc = toInteger(row.PrimaryLocationCode),
    s.wkt = row.Geometry.WGS84,
    s.coords = point(
        {
            longitude: toFloat(coords[0]),
            latitude: toFloat(coords[1]),
            crs: 'wgs-84'
        })  
WITH s, row
MATCH (pc:PlaceCenter {signature:s.signature})
MERGE (s)-[:HAS_PLACECENTER]->(pc);