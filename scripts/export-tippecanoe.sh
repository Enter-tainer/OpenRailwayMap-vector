#!/usr/bin/env bash
# Export ORM vector tiles using ogr2ogr (FlatGeobuf) + tippecanoe → PMTiles
# This replaces the slow martin-cp approach with a much faster pipeline.
#
# Usage: ./scripts/export-tippecanoe.sh
#
# Environment variables:
#   DATABASE_URL  - PostgreSQL connection string (default: postgresql://osm:osm@localhost:5432/osm)
#   OUTPUT_DIR    - Output directory (default: ./output)
#   MAX_ZOOM      - Maximum zoom level (default: 15)
#   LAYERS        - Which style layers to export: "standard" (default) or "all"
#   CONCURRENCY   - parallel PostGIS exports in Phase 1 (default: nproc)
#   PROGRESS_INTERVAL - seconds between tippecanoe progress updates (default: 60;
#                   each update becomes a log line in CI)

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://osm:osm@localhost:5432/osm}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
MAX_ZOOM="${MAX_ZOOM:-15}"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"
BBOX="${BBOX:-}"
LAYERS="${LAYERS:-standard}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-60}"
FGB_DIR="${OUTPUT_DIR}/fgb"

mkdir -p "${FGB_DIR}"

echo "=== ORM PMTiles Export (tippecanoe) ==="
echo "Database: ${DATABASE_URL}"
echo "Output: ${OUTPUT_DIR}"
echo "Max zoom: ${MAX_ZOOM}"
echo "Layers: ${LAYERS}"
echo "Concurrency: ${CONCURRENCY}"
if [ -n "${BBOX}" ]; then
  echo "BBOX filter: ${BBOX}"
  # Convert BBOX from EPSG:4326 to EPSG:3857 for -spat (since -spat_srs is incompatible with -sql)
  IFS=',' read -r minlon minlat maxlon maxlat <<< "${BBOX}"
  SPAT_3857=$(python3 -c "
import math
def to_3857(lon, lat):
    x = lon * 20037508.342789244 / 180.0
    y = math.log(math.tan((90 + lat) * math.pi / 360.0)) / (math.pi / 180.0)
    y = y * 20037508.342789244 / 180.0
    return x, y
x1, y1 = to_3857($minlon, $minlat)
x2, y2 = to_3857($maxlon, $maxlat)
print(f'{x1} {y1} {x2} {y2}')
")
  echo "BBOX (EPSG:3857): ${SPAT_3857}"
fi
echo ""

# Helper: export a SQL query to FlatGeobuf
export_layer_now() {
  local layer_name="$1"
  local sql="$2"
  local geom_col="${3:-way}"

  local outfile="${FGB_DIR}/${layer_name}.fgb"
  if [ -f "${outfile}" ]; then
    echo "  [skip] ${layer_name} (already exists)"
    return 0
  fi

  echo "  [export] ${layer_name}..."
  local start_time=$(date +%s)

  # Build ogr2ogr command
  local ogr_args=(
    -f FlatGeobuf
    "${outfile}"
    PG:"${DATABASE_URL}"
    -sql "${sql}"
    -nln "${layer_name}"
    -lco SPATIAL_INDEX=NO
    -t_srs EPSG:4326
    --config PG_USE_COPY YES
  )

  # Add spatial filter if BBOX is set (minlon,minlat,maxlon,maxlat)
  # Note: -spat_srs is not compatible with -sql, so we convert bbox to EPSG:3857
  if [ -n "${BBOX}" ]; then
    ogr_args+=(-spat ${SPAT_3857})
  fi

  if ! ogr2ogr "${ogr_args[@]}" 2>&1 | tail -5; then
    echo "  [ERROR] ${layer_name} export failed" >&2
    rm -f "${outfile}"
    return 1
  fi

  local end_time=$(date +%s)
  local duration=$((end_time - start_time))
  local size=$(du -sh "${outfile}" 2>/dev/null | cut -f1)
  echo "  [done] ${layer_name}: ${size} in ${duration}s"
}

# Run exports in the background, at most CONCURRENCY at a time. The queries
# are independent, and the slow ones are database-bound, so overlapping them
# shortens Phase 1 considerably. A failed export leaves a marker file that is
# checked once all exports have finished.
export_layer() {
  while (( $(jobs -rp | wc -l) >= CONCURRENCY )); do
    wait -n || true
  done
  local layer_name="$1"
  ( export_layer_now "$@" || touch "${FGB_DIR}/.failed-${layer_name}" ) &
}

rm -f "${FGB_DIR}"/.failed-*

# Station dot colors and line colors are worked out here, not by style
# expressions: MapLibre copies a layer's data-driven paint expression into every
# tile result its workers send, and the browser's main thread unpacks each one.
# The expression that compared a station's first 16 route colors serialized a
# copy of its bound bindings at every use, some 650k nodes per paint property,
# which cost up to 350 ms per railway tile and about 6 s over a zoom and pan
# across Tokyo. Same rules as that expression had.
psql "${DATABASE_URL}" -v ON_ERROR_STOP=1 -q <<'SQL'
SET client_min_messages = warning;
CREATE OR REPLACE FUNCTION orm_color_rgb(color text) RETURNS int[] LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN c ~ '^#[0-9a-f]{3,4}$' THEN ARRAY[
      ('x' || repeat(substr(c, 2, 1), 2))::bit(8)::int,
      ('x' || repeat(substr(c, 3, 1), 2))::bit(8)::int,
      ('x' || repeat(substr(c, 4, 1), 2))::bit(8)::int]
    WHEN c ~ '^#([0-9a-f]{6}|[0-9a-f]{8})$' THEN ARRAY[
      ('x' || substr(c, 2, 2))::bit(8)::int,
      ('x' || substr(c, 4, 2))::bit(8)::int,
      ('x' || substr(c, 6, 2))::bit(8)::int]
    ELSE (SELECT array_agg(v::int ORDER BY i) FROM jsonb_array_elements_text(
      '{"aliceblue":[240,248,255],"antiquewhite":[250,235,215],"aqua":[0,255,255],"aquamarine":[127,255,212],"azure":[240,255,255],"beige":[245,245,220],"bisque":[255,228,196],"black":[0,0,0],"blanchedalmond":[255,235,205],"blue":[0,0,255],"blueviolet":[138,43,226],"brown":[165,42,42],"burlywood":[222,184,135],"cadetblue":[95,158,160],"chartreuse":[127,255,0],"chocolate":[210,105,30],"coral":[255,127,80],"cornflowerblue":[100,149,237],"cornsilk":[255,248,220],"crimson":[220,20,60],"cyan":[0,255,255],"darkblue":[0,0,139],"darkcyan":[0,139,139],"darkgoldenrod":[184,134,11],"darkgray":[169,169,169],"darkgreen":[0,100,0],"darkgrey":[169,169,169],"darkkhaki":[189,183,107],"darkmagenta":[139,0,139],"darkolivegreen":[85,107,47],"darkorange":[255,140,0],"darkorchid":[153,50,204],"darkred":[139,0,0],"darksalmon":[233,150,122],"darkseagreen":[143,188,143],"darkslateblue":[72,61,139],"darkslategray":[47,79,79],"darkslategrey":[47,79,79],"darkturquoise":[0,206,209],"darkviolet":[148,0,211],"deeppink":[255,20,147],"deepskyblue":[0,191,255],"dimgray":[105,105,105],"dimgrey":[105,105,105],"dodgerblue":[30,144,255],"firebrick":[178,34,34],"floralwhite":[255,250,240],"forestgreen":[34,139,34],"fuchsia":[255,0,255],"gainsboro":[220,220,220],"ghostwhite":[248,248,255],"gold":[255,215,0],"goldenrod":[218,165,32],"gray":[128,128,128],"green":[0,128,0],"greenyellow":[173,255,47],"grey":[128,128,128],"honeydew":[240,255,240],"hotpink":[255,105,180],"indianred":[205,92,92],"indigo":[75,0,130],"ivory":[255,255,240],"khaki":[240,230,140],"lavender":[230,230,250],"lavenderblush":[255,240,245],"lawngreen":[124,252,0],"lemonchiffon":[255,250,205],"lightblue":[173,216,230],"lightcoral":[240,128,128],"lightcyan":[224,255,255],"lightgoldenrodyellow":[250,250,210],"lightgray":[211,211,211],"lightgreen":[144,238,144],"lightgrey":[211,211,211],"lightpink":[255,182,193],"lightsalmon":[255,160,122],"lightseagreen":[32,178,170],"lightskyblue":[135,206,250],"lightslategray":[119,136,153],"lightslategrey":[119,136,153],"lightsteelblue":[176,196,222],"lightyellow":[255,255,224],"lime":[0,255,0],"limegreen":[50,205,50],"linen":[250,240,230],"magenta":[255,0,255],"maroon":[128,0,0],"mediumaquamarine":[102,205,170],"mediumblue":[0,0,205],"mediumorchid":[186,85,211],"mediumpurple":[147,112,219],"mediumseagreen":[60,179,113],"mediumslateblue":[123,104,238],"mediumspringgreen":[0,250,154],"mediumturquoise":[72,209,204],"mediumvioletred":[199,21,133],"midnightblue":[25,25,112],"mintcream":[245,255,250],"mistyrose":[255,228,225],"moccasin":[255,228,181],"navajowhite":[255,222,173],"navy":[0,0,128],"oldlace":[253,245,230],"olive":[128,128,0],"olivedrab":[107,142,35],"orange":[255,165,0],"orangered":[255,69,0],"orchid":[218,112,214],"palegoldenrod":[238,232,170],"palegreen":[152,251,152],"paleturquoise":[175,238,238],"palevioletred":[219,112,147],"papayawhip":[255,239,213],"peachpuff":[255,218,185],"peru":[205,133,63],"pink":[255,192,203],"plum":[221,160,221],"powderblue":[176,224,230],"purple":[128,0,128],"rebeccapurple":[102,51,153],"red":[255,0,0],"rosybrown":[188,143,143],"royalblue":[65,105,225],"saddlebrown":[139,69,19],"salmon":[250,128,114],"sandybrown":[244,164,96],"seagreen":[46,139,87],"seashell":[255,245,238],"sienna":[160,82,45],"silver":[192,192,192],"skyblue":[135,206,235],"slateblue":[106,90,205],"slategray":[112,128,144],"slategrey":[112,128,144],"snow":[255,250,250],"springgreen":[0,255,127],"steelblue":[70,130,180],"tan":[210,180,140],"teal":[0,128,128],"thistle":[216,191,216],"tomato":[255,99,71],"turquoise":[64,224,208],"violet":[238,130,238],"wheat":[245,222,179],"white":[255,255,255],"whitesmoke":[245,245,245],"yellow":[255,255,0],"yellowgreen":[154,205,50]}'::jsonb -> c) WITH ORDINALITY AS e(v, i))
  END
  FROM (SELECT lower(trim(color)) AS c) input
$$;
CREATE OR REPLACE FUNCTION orm_station_colors(routes text, state text)
RETURNS TABLE (station_color text, station_kind text) LANGUAGE sql IMMUTABLE AS $$
  WITH colors AS (
    SELECT n, lower(split_part(route, U&'\001E', 2)) AS color
    FROM unnest(string_to_array(routes, U&'\001D')) WITH ORDINALITY AS r(route, n)
    WHERE n <= 16
  ), first AS (
    SELECT color, coalesce(orm_color_rgb(color), ARRAY[0, 0, 0]) AS rgb FROM colors WHERE color <> '' ORDER BY n LIMIT 1
  )
  SELECT
    (SELECT color FROM first),
    CASE
      WHEN coalesce(state, 'present') <> 'present' THEN 'inactive'
      WHEN NOT EXISTS (SELECT 1 FROM first) THEN 'plain'
      WHEN EXISTS (
        SELECT 1
        FROM colors c
        CROSS JOIN first f
        CROSS JOIN LATERAL (SELECT coalesce(orm_color_rgb(c.color), ARRAY[0, 0, 0]) AS rgb) o
        WHERE c.color <> ''
          AND greatest(abs(o.rgb[1] - f.rgb[1]), abs(o.rgb[2] - f.rgb[2]), abs(o.rgb[3] - f.rgb[3])) > 48
      ) THEN 'interchange'
      ELSE 'line'
    END
$$;

-- One color per line, so parallel tracks and services through-running from
-- another operator do not split a line into several colors: every segment of a
-- line (same name, same operator) takes the color its routes give by
-- length-weighted majority, each segment counting each color once.
DROP TABLE IF EXISTS line_color_votes;
DROP TABLE IF EXISTS line_colors_export;
CREATE TABLE line_color_votes AS
SELECT
  lv.name,
  coalesce(lv.primary_operator, '') AS line_operator,
  lower(route_item -> 'color') AS color,
  sum(greatest(coalesce(lv.way_length, 0), 1)) AS weight
FROM railway_line_view lv
CROSS JOIN LATERAL unnest(lv.line_routes) AS routes(route_item)
WHERE lv.name IS NOT NULL
  AND coalesce(route_item -> 'color', '') <> ''
GROUP BY 1, 2, 3;
CREATE TABLE line_colors_export AS
SELECT DISTINCT ON (name, line_operator) name, line_operator, color
FROM line_color_votes
ORDER BY name, line_operator, weight DESC, color;
CREATE INDEX ON line_colors_export (name, line_operator);
ANALYZE line_colors_export;
SQL

# A segment's line color: the color of its line, else the first color set among
# its own routes (unnamed station tracks, connecting curves, lines whose routes
# have no color).
LINE_COLOR_JOIN="LEFT JOIN (SELECT name AS line_name, line_operator, color FROM line_colors_export) lcx
  ON lcx.line_name = lv.name AND lcx.line_operator = coalesce(lv.primary_operator, '')
LEFT JOIN LATERAL (
  SELECT route_item -> 'color' AS color
  FROM unnest(lv.line_routes) AS routes(route_item)
  WHERE coalesce(route_item -> 'color', '') <> ''
  ORDER BY (route_item -> 'route_id')::int8
  LIMIT 1
) rc ON true"
LINE_COLOR_SQL="coalesce(lcx.color, rc.color)"

echo "--- Phase 1: Export layers from PostGIS to FlatGeobuf ---"
echo ""

# ============================================================
# Shared layers (used by all styles)
# ============================================================

echo "[Shared layers]"

# railway_line_high (z7+)
#
# Keep this as a single tippecanoe input. Multiple input files with the same
# output layer name are merged by tippecanoe before high-zoom tiles are emitted,
# so zoom-split FGBs would stack duplicate railway_line_high features in z12+.
# That is especially visible for tunnel layers because the semitransparent
# tunnel cover is drawn repeatedly.
# Only attributes something reads are kept: the style, the client-side railway
# filter, the route highlight or the popup. Left out as unused or redundant:
# id (osm_id plus a segment suffix; hover uses tippecanoe's generated ids),
# rank (only orders features here), osm_type (always W for lines),
# gauge0-2 (text copies of gaugeint0-2 and gauges) and route_count (the
# length of line_routes). way_length only gates tunnel and bridge decorations
# while zoomed out, so other segments go without it and it is rounded to
# metres; as a unique decimal per segment it was the largest attribute.
export_railway_line_high() {
  local layer_name="$1"
  local where_clause="$2"
  local include_popup_fields="${3:-false}"
  local popup_columns=""

  if [ "${include_popup_fields}" = "true" ]; then
    popup_columns=",
  osm_id,
  track_class,
  nullif(array_to_string(reporting_marks, U&'\001E'), '') as reporting_marks,
  maxspeed,
  speed_label,
  train_protection_rank,
  train_protection[1] as train_protection0,
  train_protection[2] as train_protection1,
  train_protection[3] as train_protection2,
  train_protection_construction_rank,
  train_protection_construction,
  electrification_state,
  voltage,
  frequency,
  maximum_current,
  future_voltage,
  future_frequency,
  future_maximum_current,
  gaugeint0,
  gaugeint1,
  gaugeint2,
  array_to_string(gauges, ', ') as gauges,
  loading_gauge,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  primary_operator,
  owner,
  traffic_mode,
  radio,
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(lv.line_routes) AS route_items(route_item)) as line_routes,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description"
  fi

  export_layer "${layer_name}" "
SELECT
  way,
  CASE WHEN tunnel OR bridge THEN round(way_length) END AS way_length,
  feature,
  state,
  usage,
  service,
  highspeed,
  tunnel,
  bridge,
  name,
  ref,
  track_ref,
  preferred_direction${popup_columns},
  ${LINE_COLOR_SQL} as line_color
FROM railway_line_view lv
${LINE_COLOR_JOIN}
WHERE ${where_clause}
ORDER BY
  layer,
  rank NULLS LAST,
  maxspeed NULLS FIRST
"
}

export_railway_line_high "railway_line_high" "true" true

# railway_text_km — kilometer markers
# Martin serves only zero markers at z10-12 and all markers at z13+. Export
# everything once; the Phase 2 feature filter applies the zoom rule.
export_layer "railway_text_km" "
SELECT
  id,
  osm_id,
  way,
  railway,
  position_text as pos,
  position_exact as pos_exact,
  zero,
  round(position_numeric) as pos_int,
  type,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description
FROM railway_positions
ORDER BY zero
"

# ============================================================
# Standard style layers
# ============================================================

# station_routes for railway_text_stations rows. The view's own station_routes
# column looks routes up with ARRAY[osm_id] <@ route_ids, which cannot use an
# index and scans every route per station (~15 min per query on a planet DB).
# Rebuild the same serialized value through the routes primary key instead;
# PostgreSQL skips the view's subquery when the column is not selected.
# The import links stations to routes only through stop positions with the
# station's name, nearby platforms or stop areas, so a route that lists the
# station node itself as a stop (common for mainline trains, e.g. JR lines in
# Japan) was missing. Those routes are added through route_stop's stop_id
# index; stop members carry no OSM type, so only node ids are matched.
STATION_ROUTES_SQL="(SELECT nullif(array_to_string(array_agg(
    r.osm_id::text || U&'\001E' ||
    coalesce(r.color, '') || U&'\001E' ||
    coalesce(r.name, '')
    ORDER BY r.osm_id::text
  ), U&'\001D'), '')
  FROM routes r
  WHERE r.osm_id IN (
    SELECT unnest(g.route_ids) FROM grouped_stations_with_importance g WHERE g.id = s.id
    UNION
    SELECT rs.route_id
    FROM unnest(s.osm_id, s.osm_type) AS member(osm_id, osm_type)
    JOIN route_stop rs ON rs.stop_id = member.osm_id
    WHERE member.osm_type = 'N'
  ))"

# A station's routes are looked up once, and its dot color and kind come from
# them (orm_station_colors); the style only reads the two attributes.
STATION_COLORS_JOIN="CROSS JOIN LATERAL (SELECT ${STATION_ROUTES_SQL} AS station_routes) sr
CROSS JOIN LATERAL orm_station_colors(sr.station_routes, s.state) sc"

echo ""
echo "[Standard style layers]"

# standard_railway_line_low (z0-7) — main lines for the zoomed-out map.
# Only the attributes the low-zoom style and the client-side railway filter
# read; everything else (routes, links, ids, signalling...) lives in
# railway_line_high from z7. `ref` stays because the low-zoom line labels read
# it, and so do the `bridge`/`tunnel` flags: the low-zoom layers filter on them
# to skip the tunnel cover and bridge fill, and a missing flag would paint every
# tunnel as ordinary track. way_length only gated the tunnel/bridge decorations
# at z8+, which this layer never reaches, so it goes.
# Without per-segment values, adjacent segments with identical attributes are
# merged: ST_LineMerge joins them and ST_Dump splits the result into plain
# LineStrings (MULTILINESTRINGs crashed tippecanoe). This turns ~1.2M short
# segments into ~200k line sections, shrinking a z2 tile several times over.
# The merged sections have no single osm_id, so features below z8 no longer
# open a popup; railway_line_high carries that from z7 on.
export_layer "standard_railway_line_low" "
SELECT
  feature,
  state,
  usage,
  highspeed,
  name,
  ref,
  maxspeed,
  electrification_state,
  gaugeint0,
  gaugeint1,
  traffic_mode,
  operator,
  line_color,
  tunnel,
  bridge,
  way
FROM (
  SELECT
    feature,
    state,
    usage,
    highspeed,
    name,
    ref,
    maxspeed,
    electrification_state,
    gaugeint0,
    gaugeint1,
    traffic_mode,
    nullif(array_to_string(operator, U&'\001E'), '') as operator,
    tunnel,
    bridge,
    ${LINE_COLOR_SQL} as line_color,
    max(rank) as rank,
    (ST_Dump(ST_LineMerge(ST_Collect(way)))).geom AS way
  FROM railway_line_view lv
  ${LINE_COLOR_JOIN}
  WHERE state = 'present'
    AND feature IN ('rail', 'ferry')
    AND usage = 'main'
    AND service IS NULL
  GROUP BY
    feature, state, usage, highspeed, name, ref, maxspeed, electrification_state,
    gaugeint0, gaugeint1, traffic_mode, nullif(array_to_string(operator, U&'\001E'), ''),
    tunnel, bridge, ${LINE_COLOR_SQL}
) merged
ORDER BY rank NULLS LAST
"

# Station text layers — all from railway_text_stations view
# We export the full view and use it for all station zoom levels
# The style handles zoom filtering via minzoom/maxzoom
export_layer "standard_railway_text_stations" "
SELECT
  id,
  center AS way,
  nullif(array_to_string(s.osm_id, U&'\001E'), '') as osm_id,
  nullif(array_to_string(s.osm_type, U&'\001E'), '') as osm_type,
  feature,
  state,
  station,
  station_size,
  map_reference as label,
  name,
  name as localized_name,
  count,
  (SELECT nullif(array_to_string(array_agg(e.k || U&'\001E' || e.v ORDER BY e.k), U&'\001D'), '') FROM each(s.\"references\") AS e(k, v)) as references,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  nullif(array_to_string(network, U&'\001E'), '') as network,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  nullif(array_to_string(wikidata, U&'\001E'), '') as wikidata,
  nullif(array_to_string(wikimedia_commons, U&'\001E'), '') as wikimedia_commons,
  nullif(array_to_string(wikimedia_commons_file, U&'\001E'), '') as wikimedia_commons_file,
  nullif(array_to_string(image, U&'\001E'), '') as image,
  nullif(array_to_string(mapillary, U&'\001E'), '') as mapillary,
  nullif(array_to_string(wikipedia, U&'\001E'), '') as wikipedia,
  nullif(array_to_string(note, U&'\001E'), '') as note,
  nullif(array_to_string(description, U&'\001E'), '') as description,
  nullif(array_to_string(yard_purpose, U&'\001E'), '') as yard_purpose,
  yard_hump,
  ${STATION_ROUTES_SQL} as station_routes,
  sc.station_color,
  sc.station_kind,
  discr_iso
FROM railway_text_stations s
${STATION_COLORS_JOIN}
WHERE name IS NOT NULL
ORDER BY
  rank DESC NULLS LAST,
  importance DESC NULLS LAST
"

# Station low-zoom layers. Martin applies a z-dependent discr_iso threshold
# (213000 * exp(-0.33 * z) - 18000 < discr_iso). The threshold loosens as z
# grows, so export once at the highest zoom of each range; the Phase 2 feature
# filter tightens it per zoom using the discr_iso attribute.
STATIONS_LOW_ZOOMS=(4 5 6 7)
STATIONS_MED_ZOOMS=(7 8)
station_discr_threshold() {
  awk -v z="$1" 'BEGIN { printf "%.3f", 213000 * exp(-0.33 * z) - 18000 }'
}

z="${STATIONS_LOW_ZOOMS[-1]}"
export_layer "standard_railway_text_stations_low" "
SELECT
  id, center AS way,
  nullif(array_to_string(s.osm_id, U&'\001E'), '') as osm_id,
  nullif(array_to_string(s.osm_type, U&'\001E'), '') as osm_type,
  feature, state, station,
  map_reference as label, name, name as localized_name,
  station_size,
  (SELECT nullif(array_to_string(array_agg(e.k || U&'\001E' || e.v ORDER BY e.k), U&'\001D'), '') FROM each(s.\"references\") AS e(k, v)) as references,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  nullif(array_to_string(network, U&'\001E'), '') as network,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  nullif(array_to_string(wikidata, U&'\001E'), '') as wikidata,
  nullif(array_to_string(wikimedia_commons, U&'\001E'), '') as wikimedia_commons,
  nullif(array_to_string(wikimedia_commons_file, U&'\001E'), '') as wikimedia_commons_file,
  nullif(array_to_string(image, U&'\001E'), '') as image,
  nullif(array_to_string(mapillary, U&'\001E'), '') as mapillary,
  nullif(array_to_string(wikipedia, U&'\001E'), '') as wikipedia,
  nullif(array_to_string(note, U&'\001E'), '') as note,
  nullif(array_to_string(description, U&'\001E'), '') as description,
  nullif(array_to_string(yard_purpose, U&'\001E'), '') as yard_purpose,
  yard_hump,
  ${STATION_ROUTES_SQL} as station_routes,
  sc.station_color,
  sc.station_kind,
  discr_iso
FROM railway_text_stations s
${STATION_COLORS_JOIN}
WHERE feature = 'station' AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
  AND 213000 * exp(-0.33 * ${z}) - 18000 < discr_iso
  AND station_size IN ('large', 'normal')
ORDER BY importance DESC NULLS LAST
"

# z7-8: all station types except light_rail/monorail/subway.
z="${STATIONS_MED_ZOOMS[-1]}"
export_layer "standard_railway_text_stations_med" "
SELECT
  id, center AS way,
  nullif(array_to_string(s.osm_id, U&'\001E'), '') as osm_id,
  nullif(array_to_string(s.osm_type, U&'\001E'), '') as osm_type,
  feature, state, station,
  map_reference as label, name, name as localized_name,
  station_size,
  (SELECT nullif(array_to_string(array_agg(e.k || U&'\001E' || e.v ORDER BY e.k), U&'\001D'), '') FROM each(s.\"references\") AS e(k, v)) as references,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  nullif(array_to_string(network, U&'\001E'), '') as network,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  nullif(array_to_string(wikidata, U&'\001E'), '') as wikidata,
  nullif(array_to_string(wikimedia_commons, U&'\001E'), '') as wikimedia_commons,
  nullif(array_to_string(wikimedia_commons_file, U&'\001E'), '') as wikimedia_commons_file,
  nullif(array_to_string(image, U&'\001E'), '') as image,
  nullif(array_to_string(mapillary, U&'\001E'), '') as mapillary,
  nullif(array_to_string(wikipedia, U&'\001E'), '') as wikipedia,
  nullif(array_to_string(note, U&'\001E'), '') as note,
  nullif(array_to_string(description, U&'\001E'), '') as description,
  nullif(array_to_string(yard_purpose, U&'\001E'), '') as yard_purpose,
  yard_hump,
  ${STATION_ROUTES_SQL} as station_routes,
  sc.station_color,
  sc.station_kind,
  discr_iso
FROM railway_text_stations s
${STATION_COLORS_JOIN}
WHERE feature = 'station' AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
  AND 213000 * exp(-0.33 * ${z}) - 18000 < discr_iso
ORDER BY importance DESC NULLS LAST
"

# standard_railway_turntables (z10+)
export_layer "standard_railway_turntables" "
SELECT id, osm_id, osm_type, way, replace(feature, 'general/', '') AS feature FROM pois
WHERE feature IN ('general/turntable', 'general/traverser')
  AND ST_GeometryType(way) IN ('ST_Polygon', 'ST_MultiPolygon')
"

# standard_station_entrances (z16+)
export_layer "standard_station_entrances" "
SELECT
  id, osm_id, osm_type, way, type, name, ref, label,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM standard_station_entrances_view
"

# standard_railway_symbols — from poi_view, standard layer.
# Keep all symbols needed by the archive and let the style's
# "zoom >= minzoom" filter decide visibility. If the archive max zoom is below
# the official max, include the highest-detail POIs because the demo style caps
# those layers down to the archive max zoom.
symbols_effective_max_zoom="${MAX_ZOOM}"
if (( MAX_ZOOM < 17 )); then
  symbols_effective_max_zoom=17
fi
export_layer "standard_railway_symbols" "
SELECT
  id, osm_id, osm_type, center AS way, feature, ref, name, minzoom,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM pois
WHERE feature IN ('general/aei','general/buffer_stop','general/car-dumper','general/car-shuttle','general/carrier-truck-pit','general/coaling_facility','general/compressed_air_supply','general/container-terminal','general/crossing','general/defect_detector','general/derail','general/engine_shed','general/ferry-terminal','general/fuel','general/gauge-conversion','general/hirail_access','general/hump_yard','general/level-crossing','general/level-crossing-barrier','general/level-crossing-light','general/level-crossing-light-barrier','general/loading-rack','general/loading-ramp','general/loading-tower','general/loading_gauge','general/lubricator','general/museum','general/museum-rail-transport','general/phone','general/pit','general/preheating','general/radio-antenna','general/radio-mast','general/retarder','general/rolling_highway','general/sand_store','general/track-scale','general/unloading-hole','general/wash','general/waste_disposal','general/water_crane','general/water_tower','general/workshop')
  AND minzoom <= ${symbols_effective_max_zoom}
ORDER BY rank DESC
"

# standard_railway_platforms (z15+)
export_layer "standard_railway_platforms" "
SELECT
  id, osm_id, osm_type, way, feature, name,
  nullif(array_to_string(ref, U&'\001E'), '') as ref,
  height, surface, elevator, shelter, lit, bin, bench,
  wheelchair, departures_board, tactile_paving,
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(p.platform_routes) AS route_items(route_item)) as platform_routes
FROM standard_railway_platforms_view p
"

# standard_railway_platform_edges (z17+)
export_layer "standard_railway_platform_edges" "
SELECT
  id, osm_id, osm_type, way, feature, ref, height, tactile_paving
FROM standard_railway_platform_edges_view
"

# standard_railway_stop_positions (z16+)
export_layer "standard_railway_stop_positions" "
SELECT
  id, osm_id, osm_type, way, name, type, ref, local_ref,
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(sp.stop_position_routes) AS route_items(route_item)) as stop_position_routes
FROM standard_railway_stop_positions_view sp
"

# standard_railway_switch_ref (z17+)
export_layer "standard_railway_switch_ref" "
SELECT
  id, osm_id, osm_type, way, railway, ref, type,
  turnout_side, local_operated, resetting,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM standard_railway_switch_view
ORDER BY char_length(ref)
"

# standard_railway_grouped_stations (z13+) — clustered station areas
export_layer "standard_railway_grouped_stations" "
SELECT
  id,
  buffered as way,
  nullif(array_to_string(s.osm_id, U&'\001E'), '') as osm_id,
  nullif(array_to_string(s.osm_type, U&'\001E'), '') as osm_type,
  feature,
  state,
  station,
  map_reference as label,
  name,
  name as localized_name,
  (SELECT nullif(array_to_string(array_agg(e.k || U&'\001E' || e.v ORDER BY e.k), U&'\001D'), '') FROM each(s.\"references\") AS e(k, v)) as references,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  nullif(array_to_string(network, U&'\001E'), '') as network,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  nullif(array_to_string(wikidata, U&'\001E'), '') as wikidata,
  nullif(array_to_string(wikimedia_commons, U&'\001E'), '') as wikimedia_commons,
  nullif(array_to_string(wikimedia_commons_file, U&'\001E'), '') as wikimedia_commons_file,
  nullif(array_to_string(image, U&'\001E'), '') as image,
  nullif(array_to_string(mapillary, U&'\001E'), '') as mapillary,
  nullif(array_to_string(wikipedia, U&'\001E'), '') as wikipedia,
  nullif(array_to_string(note, U&'\001E'), '') as note,
  nullif(array_to_string(description, U&'\001E'), '') as description,
  nullif(array_to_string(yard_purpose, U&'\001E'), '') as yard_purpose,
  yard_hump,
  ${STATION_ROUTES_SQL} as station_routes
FROM railway_text_stations s
"

# standard_railway_grouped_station_areas (z13+)
# Station area outlines group several stops (an interchange). Flag which kinds
# of station they contain so clients can hide urban-only interchanges together
# with urban transit stations (same member path as stop_area_groups_buffered).
export_layer "standard_railway_grouped_station_areas" "
SELECT
  v.id,
  v.osm_id,
  v.osm_type,
  v.feature,
  v.way,
  coalesce(k.has_urban_station, false) as has_urban_station,
  coalesce(k.has_rail_station, true) as has_rail_station
FROM standard_railway_grouped_station_areas_view v
LEFT JOIN (
  SELECT
    sag.osm_id,
    bool_or(s.station IN ('subway', 'light_rail', 'monorail', 'funicular', 'tram')) as has_urban_station,
    bool_or(s.station IS NULL OR s.station NOT IN ('subway', 'light_rail', 'monorail', 'funicular', 'tram')) as has_rail_station
  FROM stop_area_groups sag
  JOIN stop_areas sa ON sa.osm_id = ANY(sag.stop_area_ref_ids)
  JOIN stations_stop_areas ssa ON ssa.stop_area_osm_id = sa.osm_id
  JOIN stations s ON ssa.station_id = s.id
  GROUP BY sag.osm_id
) k ON k.osm_id = v.osm_id
"

# ============================================================
# Speed style layers
# ============================================================

if [ "${LAYERS}" = "all" ]; then
echo ""
echo "[Speed style layers]"

# speed_railway_line_low (z0-7)
export_layer "speed_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage,
  maxspeed, ref, speed_label, rank
FROM railway_line_low
"

# speed_railway_signals (z13+) — from speed_railway_signals_view (expanded
# feature0/1, deactivated0/1, offset0/1 columns; position stringified)
export_layer "speed_railway_signals" "
SELECT
  id, way, osm_id, osm_type, rank, railway, direction_both,
  ref, caption,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  azimuth, type,
  feature0, feature1, feature2, feature3, feature4, feature5,
  deactivated0, deactivated1, deactivated2, deactivated3, deactivated4, deactivated5,
  offset0, offset1, offset2, offset3, offset4, offset5
FROM speed_railway_signals_view
"

# ============================================================
# Signals style layers
# ============================================================

echo ""
echo "[Signals style layers]"


# signals_railway_line_low (z0-7)
export_layer "signals_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref,
  train_protection_rank,
  train_protection[1] as train_protection0,
  train_protection[2] as train_protection1,
  train_protection[3] as train_protection2,
  train_protection_construction_rank, train_protection_construction,
  rank
FROM railway_line_low
"

# signals_signal_boxes (z8-14) — point at medium zoom, geometry at z14
export_layer "signals_signal_boxes_low" "
SELECT
  id,
  0 as zoom_part,
  center as way,
  feature,
  ref,
  name,
  operator_color,
  operator_bright
FROM signal_boxes_view
"

export_layer "signals_signal_boxes_high" "
SELECT
  id,
  1 as zoom_part,
  way,
  feature,
  ref,
  name,
  operator_color,
  operator_bright
FROM signal_boxes_view
"

# signals_railway_signals (z13+) — all signal features
# Upstream now stores multi-signal arrays; the *_signals_view expands them
# into feature0-5 / deactivated0-5 / offset0-5 columns (FlatGeobuf cannot
# hold StringList), matching what the style renders. position is a text[]
# column on the signals table, so it must be stringified here.
export_layer "signals_railway_signals" "
SELECT
  id, way, osm_id, osm_type, rank, railway, direction_both,
  ref, caption,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  azimuth, type,
  feature0, feature1, feature2, feature3, feature4, feature5,
  deactivated0, deactivated1, deactivated2, deactivated3, deactivated4, deactivated5,
  offset0, offset1, offset2, offset3, offset4, offset5
FROM signals_railway_signals_view
"

# ============================================================
# Electrification style layers
# ============================================================

echo ""
echo "[Electrification style layers]"

# electrification_railway_line_low (z0-7)
export_layer "electrification_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref,
  electrification_state, voltage, frequency, maximum_current,
  rank
FROM railway_line_low
"

# electrification_signals (z13+) — from electrification_signals_view
# (expanded columns; position stringified)
export_layer "electrification_signals" "
SELECT
  id, way, osm_id, osm_type, rank, railway, direction_both,
  ref, caption,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  azimuth, type,
  feature0, feature1, feature2, feature3, feature4, feature5,
  deactivated0, deactivated1, deactivated2, deactivated3, deactivated4, deactivated5,
  offset0, offset1, offset2, offset3, offset4, offset5
FROM electrification_signals_view
"

# electrification_railway_symbols (z13+) — from poi_view, electrification layer
export_layer "electrification_railway_symbols" "
SELECT
  id, way, feature, ref, minzoom
FROM poi_view
WHERE layer = 'electrification' AND minzoom <= 17
ORDER BY rank DESC
"

# electrification_catenary (z14+)
export_layer "electrification_catenary" "
SELECT
  id, way, feature, ref, transition
FROM electrification_catenary_view
"

# electrification_substation (z13+)
export_layer "electrification_substation" "
SELECT
  id, way, name
FROM electrification_substation_view
"

# ============================================================
# Track style layers
# ============================================================

echo ""
echo "[Track style layers]"

# track_railway_line_low (z0-7)
# Query railway_line_view directly (not railway_line_low) to get the gauges
# array, which the style uses for the gauge label. railway_line_low lacks it.
export_layer "track_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref,
  gaugeint0, gauge0,
  array_to_string(gauges, ', ') as gauges,
  track_class, loading_gauge, rank
FROM railway_line_view
WHERE state = 'present'
  AND feature IN ('rail', 'ferry')
  AND usage = 'main'
  AND service IS NULL
"

# ============================================================
# Operator style layers
# ============================================================

echo ""
echo "[Operator style layers]"

# operator_railway_line_low (z0-7)
export_layer "operator_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  operator_color, operator_bright, primary_operator, owner, rank
FROM railway_line_low
"

# operator_railway_symbols (z13+) — from poi_view, operator layer
export_layer "operator_railway_symbols" "
SELECT
  id, way, feature, ref, minzoom
FROM poi_view
WHERE layer = 'operator' AND minzoom <= 17
ORDER BY rank DESC
"

# ============================================================
# Route style layers
# ============================================================

echo ""
echo "[Route style layers]"

# route_railway_line_low (z0-7)
export_layer "route_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, highspeed,
  (select count(*) from route_line rl join routes r on rl.route_id = r.osm_id where rl.line_id = l.osm_id) as route_count,
  name, ref, rank
FROM railway_line_low l
"

fi  # end LAYERS=all

echo ""
wait
failed_exports=("${FGB_DIR}"/.failed-*)
if [ -e "${failed_exports[0]}" ]; then
  echo "Phase 1 failed for: ${failed_exports[*]##*/.failed-}" >&2
  exit 1
fi

echo "--- Phase 1 complete ---"
echo ""

# Count exported files
fgb_count=$(ls -1 "${FGB_DIR}"/*.fgb 2>/dev/null | wc -l)
total_size=$(du -sh "${FGB_DIR}" 2>/dev/null | cut -f1)
echo "Exported ${fgb_count} layers, total size: ${total_size}"
echo ""

# ============================================================
# Phase 2: Generate PMTiles with tippecanoe
# ============================================================

echo "--- Phase 2: Generate PMTiles with tippecanoe ---"
echo ""

PMTILES_FILE="${OUTPUT_DIR}/openrailwaymap.pmtiles"

# Build tippecanoe command with all layers and their zoom ranges
# Format: -L layer_name:minzoom:maxzoom:file.fgb
TIPPECANOE_ARGS=(
  --output="${PMTILES_FILE}"
  --force
  --maximum-zoom="${MAX_ZOOM}"
  --minimum-zoom=0

  # General settings
  --no-tile-size-limit
  --no-feature-limit
  --generate-ids
  --progress-interval="${PROGRESS_INTERVAL}"
  -r1  # Keep all features at all zoom levels (no density-based dropping)

  # Attribution
  --name="OpenRailwayMap"
  --description="OpenRailwayMap vector tiles"
  --attribution="© OpenStreetMap contributors | Style: OpenRailwayMap"

  # Numeric type coercion — tippecanoe's FlatGeobuf reader converts all
  # numeric columns to strings; -T forces them back to the correct types.
  # Float attributes
  -T way_length:float
  -T maxspeed:float
  -T frequency:float
  -T future_frequency:float
  -T height:float
  -T position_numeric:float
  # Integer attributes
  -T rank:int
  -T voltage:int
  -T maximum_current:int
  -T future_voltage:int
  -T future_maximum_current:int
  -T train_protection_rank:int
  -T train_protection_construction_rank:int
  -T gaugeint0:int
  -T gaugeint1:int
  -T gaugeint2:int
  -T route_count:int
  -T count:int
  -T importance:int
  -T discr_iso:float
  -T pos_int:int
  -T minzoom:int
  -T zoom_part:int
  -T way_area:float
  # Signal feature columns (expanded from arrays by the *_signals_view)
  -T offset0:float
  -T offset1:float
  -T offset2:float
  -T offset3:float
  -T offset4:float
  -T offset5:float
  -T deactivated0:bool
  -T deactivated1:bool
  -T deactivated2:bool
  -T deactivated3:bool
  -T deactivated4:bool
  -T deactivated5:bool
  -T azimuth:float
  -T direction_both:bool
)

# Register each layer with the zoom range from the martin configuration.
#
# tippecanoe's -L accepts only file/layer/description/format, so zoom ranges
# cannot go there (they would be silently ignored and every layer would land
# in every zoom). Instead each output layer gets a feature filter (-j) that
# tests $zoom, plus any attribute rules Martin applies per zoom.
#
# Filter caveat: tippecanoe's ["==", attr, true] matches every feature, so
# boolean tests must be written as ["!=", attr, false].
declare -A LAYER_FILTERS=()

zoom_range_filter() {
  local minzoom="$1" maxzoom="$2"
  printf '["all",[">=","$zoom",%s],["<=","$zoom",%s]]' "${minzoom}" "${maxzoom}"
}

# Clamp a zoom range to MAX_ZOOM. Prints "min max", or nothing if empty.
clamp_zoom_range() {
  local minzoom="$1" maxzoom="$2"
  if (( minzoom > MAX_ZOOM )); then
    return 0
  fi
  if (( maxzoom > MAX_ZOOM )); then
    maxzoom="${MAX_ZOOM}"
  fi
  if (( maxzoom >= minzoom )); then
    echo "${minzoom} ${maxzoom}"
  fi
}

# Add an input file under an output layer name, with a full filter expression.
add_layer_filtered() {
  local file_name="$1"
  local layer_name="$2"
  local filter="$3"
  local file="${FGB_DIR}/${file_name}.fgb"

  if [ ! -s "${file}" ]; then
    echo "  [skip] ${file_name} -> ${layer_name} (no data)"
    return 0
  fi
  TIPPECANOE_ARGS+=("-L" "{\"file\":\"${file}\",\"layer\":\"${layer_name}\"}")
  if [ -n "${filter}" ]; then
    LAYER_FILTERS[${layer_name}]="${filter}"
  fi
}

# Add a layer whose features all share one zoom range.
add_layer() {
  local name="$1"
  local range
  range=$(clamp_zoom_range "$2" "$3")
  if [ -z "${range}" ]; then
    echo "  [skip] ${name} (zoom range $2-$3 outside 0-${MAX_ZOOM})"
    return 0
  fi
  add_layer_filtered "${name}" "${name}" "$(zoom_range_filter ${range})"
}

# Layers whose official minzoom is above MAX_ZOOM are still included at
# MAX_ZOOM, so clients can overzoom them.
add_layer_capped_to_max() {
  local name="$1" minzoom="$2" maxzoom="$3"
  if (( minzoom > MAX_ZOOM )); then
    minzoom="${MAX_ZOOM}"
  fi
  add_layer "${name}" "${minzoom}" "${maxzoom}"
}

# Layers carrying a per-feature minzoom attribute: from the layer's minzoom,
# keep a feature at zoom z only if minzoom <= z. At MAX_ZOOM keep everything,
# since clients overzoom that level.
add_layer_with_feature_minzoom() {
  local name="$1" layer_minzoom="$2"
  if (( layer_minzoom > MAX_ZOOM )); then
    layer_minzoom="${MAX_ZOOM}"
  fi
  local clauses=("[\">=\",\"\$zoom\",${MAX_ZOOM}]")
  local z
  for (( z = layer_minzoom; z < MAX_ZOOM; z++ )); do
    clauses+=("[\"all\",[\"==\",\"\$zoom\",${z}],[\"<=\",\"minzoom\",${z}]]")
  done
  local IFS=,
  add_layer_filtered "${name}" "${name}" "[\"all\",[\">=\",\"\$zoom\",${layer_minzoom}],[\"any\",${clauses[*]}]]"
}

# Station label layers: Martin's discr_iso threshold for each zoom.
add_station_layer() {
  local name="$1"
  shift
  local clauses=() z
  for z in "$@"; do
    if (( z <= MAX_ZOOM )); then
      clauses+=("[\"all\",[\"==\",\"\$zoom\",${z}],[\">\",\"discr_iso\",$(station_discr_threshold "${z}")]]")
    fi
  done
  if (( ${#clauses[@]} == 0 )); then
    echo "  [skip] ${name} (zooms $* outside 0-${MAX_ZOOM})"
    return 0
  fi
  local IFS=,
  add_layer_filtered "${name}" "${name}" "[\"any\",${clauses[*]}]"
}

# Shared
# railway_line_high: each segment only from the zoom the standard style first
# draws its kind at (public/orm/style/standard.json; the style's filters only
# test feature, usage and state). Below that zoom it is invisible, yet at z7-9
# it made up roughly half of each tile. Segments on a route are kept from z7
# because the route highlight draws routes from z7 tiles and traces them
# below z7. Keep these categories in step with the style.
railway_line_high_filter() {
  local z9=$(( MAX_ZOOM < 9 ? MAX_ZOOM : 9 ))
  local z10=$(( MAX_ZOOM < 10 ? MAX_ZOOM : 10 ))
  local z11=$(( MAX_ZOOM < 11 ? MAX_ZOOM : 11 ))
  local z12=$(( MAX_ZOOM < 12 ? MAX_ZOOM : 12 ))
  local active='["in","state","present","construction","proposed"]'
  # z7-8: main and branch lines, ferries.
  local from7="[\"all\",${active},[\"any\",[\"all\",[\"==\",\"feature\",\"rail\"],[\"in\",\"usage\",\"main\",\"branch\"]],[\"==\",\"feature\",\"ferry\"]]]"
  # z9: urban transit, test and military, tourism or preserved, industrial.
  local from9="[\"any\",[\"all\",${active},[\"in\",\"feature\",\"subway\",\"tram\",\"light_rail\",\"monorail\"]],[\"all\",${active},[\"==\",\"feature\",\"rail\"],[\"in\",\"usage\",\"test\",\"military\"]],[\"all\",[\"in\",\"state\",\"present\",\"construction\",\"proposed\",\"preserved\"],[\"any\",[\"==\",\"usage\",\"tourism\"],[\"==\",\"state\",\"preserved\"]]],[\"all\",${active},[\"==\",\"usage\",\"industrial\"],[\"in\",\"feature\",\"rail\",\"narrow_gauge\"]]]"
  # z10: narrow gauge, and rail without a usage (service tracks).
  local from10="[\"any\",[\"all\",${active},[\"==\",\"feature\",\"narrow_gauge\"],[\"any\",[\"!has\",\"usage\"],[\"!=\",\"usage\",\"industrial\"]]],[\"all\",${active},[\"==\",\"feature\",\"rail\"],[\"!has\",\"usage\"]]]"
  # z11: disused. Everything else (abandoned, razed, miniature, funicular,
  # kinds the style does not draw) from z12.
  local from11='["==","state","disused"]'
  printf '["all",%s,["any",[">=","$zoom",%s],["has","line_routes"],["all",[">=","$zoom",%s],%s],["all",[">=","$zoom",%s],%s],["all",[">=","$zoom",%s],%s],%s]]' \
    "$(zoom_range_filter 7 "${MAX_ZOOM}")" "${z12}" "${z11}" "${from11}" "${z10}" "${from10}" "${z9}" "${from9}" "${from7}"
}
add_layer_filtered "railway_line_high" "railway_line_high" "$(railway_line_high_filter)"
# railway_text_km: z10-12 zero markers only, z13+ all markers
add_layer_filtered "railway_text_km" "railway_text_km" \
  "[\"any\",[\">=\",\"\$zoom\",13],[\"all\",[\">=\",\"\$zoom\",10],[\"!=\",\"zero\",false]]]"

# Standard
add_layer "standard_railway_line_low"             0  7
add_station_layer "standard_railway_text_stations_low" "${STATIONS_LOW_ZOOMS[@]}"
add_station_layer "standard_railway_text_stations_med" "${STATIONS_MED_ZOOMS[@]}"
add_layer "standard_railway_text_stations"        8  "${MAX_ZOOM}"
add_layer "standard_railway_turntables"           10 "${MAX_ZOOM}"
add_layer_capped_to_max "standard_station_entrances"     16 "${MAX_ZOOM}"
add_layer_with_feature_minzoom "standard_railway_symbols" 12
add_layer "standard_railway_platforms"             15 "${MAX_ZOOM}"
add_layer_capped_to_max "standard_railway_platform_edges" 17 "${MAX_ZOOM}"
add_layer_capped_to_max "standard_railway_stop_positions" 16 "${MAX_ZOOM}"
add_layer_capped_to_max "standard_railway_switch_ref"     17 "${MAX_ZOOM}"
add_layer "standard_railway_grouped_stations"      13 "${MAX_ZOOM}"
add_layer "standard_railway_grouped_station_areas" 13 "${MAX_ZOOM}"

if [ "${LAYERS}" = "all" ]; then
# Speed
add_layer "speed_railway_line_low"                0  7
add_layer "speed_railway_signals"                 13 "${MAX_ZOOM}"

# Signals
add_layer "signals_railway_line_low"              0  7
# Signal boxes: points (zoom_part 0) at z8-13, full geometry (zoom_part 1) at z14
signal_boxes_filter="[\"any\",[\"all\",[\"==\",\"zoom_part\",0],$(zoom_range_filter 8 13)],[\"all\",[\"==\",\"zoom_part\",1],$(zoom_range_filter 14 14)]]"
add_layer_filtered "signals_signal_boxes_low" "signals_signal_boxes" "${signal_boxes_filter}"
add_layer_filtered "signals_signal_boxes_high" "signals_signal_boxes" "${signal_boxes_filter}"
add_layer "signals_railway_signals"               13 "${MAX_ZOOM}"

# Electrification
add_layer "electrification_railway_line_low"      0  7
add_layer "electrification_signals"               13 "${MAX_ZOOM}"
add_layer_with_feature_minzoom "electrification_railway_symbols" 13
add_layer "electrification_catenary"              14 "${MAX_ZOOM}"
add_layer "electrification_substation"            13 "${MAX_ZOOM}"

# Track
add_layer "track_railway_line_low"                0  7

# Operator
add_layer "operator_railway_line_low"             0  7
add_layer_with_feature_minzoom "operator_railway_symbols" 13

# Route
add_layer "route_railway_line_low"                0  7
fi  # end LAYERS=all

filter_json=""
for layer_name in "${!LAYER_FILTERS[@]}"; do
  filter_json+="${filter_json:+,}\"${layer_name}\":${LAYER_FILTERS[${layer_name}]}"
done
TIPPECANOE_ARGS+=(-j "{${filter_json}}")

echo ""
echo "Running tippecanoe with ${#TIPPECANOE_ARGS[@]} arguments..."
echo ""

tippecanoe "${TIPPECANOE_ARGS[@]}" 2>&1

echo ""
echo "--- Phase 2 complete ---"
echo ""

pmtiles_size=$(du -sh "${PMTILES_FILE}" 2>/dev/null | cut -f1)
echo "Output: ${PMTILES_FILE} (${pmtiles_size})"
echo ""
echo "=== Export complete ==="
