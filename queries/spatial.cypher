/*
Fetch all locations near 'HRBG' within 1000 meters
*/

// Memgraph and Neo4j
MATCH (l1:Location {signature: 'HRBG'})
MATCH (l2:Location) WHERE point.distance(l1.coords, l2.coords) < 1000
RETURN l2;


// ArcadeDB
MATCH (l1:Location {signature: 'HRBG'})
MATCH (l2:Location) WHERE geo.distance(l1.wkt, l2.wkt) < 1000
RETURN l2;


// LadybugDB: no spatial types, so haversine on the lon/lat columns
// (earth radius 6378140 m)
MATCH (l1:Location {signature: 'HRBG'})
MATCH (l2:Location)
WHERE 2 * 6378140 * asin(sqrt(
        pow(sin(radians(l2.lat - l1.lat) / 2), 2)
        + cos(radians(l1.lat)) * cos(radians(l2.lat))
          * pow(sin(radians(l2.lon - l1.lon) / 2), 2))) < 1000
RETURN l2;

// Apache AGE: no spatial types either, so the same haversine on lon/lat, but
// AGE has no pow()/power() function, so squaring uses ^ instead, and roughly
// a ninth of Locations have no lon/lat at all (see readme.md's "Seeding
// Apache AGE" section) since their source WKT is a LINESTRING/GEOMETRYCOLLECTION,
// not a POINT — filtered out explicitly rather than silently propagating NULL:
SELECT * FROM cypher('benchmark', $$
  MATCH (l1:Location {signature: 'HRBG'})
  MATCH (l2:Location)
  WHERE l2.lon IS NOT NULL AND 2 * 6378140 * asin(sqrt(
          sin(radians(l2.lat - l1.lat) / 2) ^ 2
          + cos(radians(l1.lat)) * cos(radians(l2.lat))
            * sin(radians(l2.lon - l1.lon) / 2) ^ 2)) < 1000
  RETURN l2
$$) AS (l2 agtype);


/*
    Fetch all locations in Stockholm bounding box
*/

// Neo4j and Memgraph
WITH point({latitude: 59.220, longitude: 17.729}) AS sw, 
    point({latitude: 59.44, longitude: 18.287}) AS ne
MATCH (l:Location)
WHERE point.withinBBox(l.coords, sw, ne)
RETURN l;

// ArcadeDB
WITH geo.geomFromText('POINT (17.729 59.220)') as sw,  geo.geomFromText('POINT (18.287 59.44)') as ne 
WITH geo.envelope(geo.lineString([sw, ne])) AS bbox
MATCH (l:Location)
WHERE geo.within(l.wkt, bbox)
RETURN l;

// LadybugDB has no spatial types, so this compares the lon/lat columns directly
MATCH (l:Location)
WHERE l.lon >= 17.729 AND l.lon <= 18.287
  AND l.lat >= 59.220 AND l.lat <= 59.44
RETURN l;

// Apache AGE: same lon/lat comparison, wrapped in the cypher() SQL call. NULL
// lon/lat (see above) compares to neither bound and is excluded automatically,
// no IS NOT NULL needed here.
SELECT * FROM cypher('benchmark', $$
  MATCH (l:Location)
  WHERE l.lon >= 17.729 AND l.lon <= 18.287
    AND l.lat >= 59.220 AND l.lat <= 59.44
  RETURN l
$$) AS (l agtype);
