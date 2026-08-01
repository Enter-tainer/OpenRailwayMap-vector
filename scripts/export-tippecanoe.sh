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
#   CONCURRENCY   - tippecanoe parallelism (default: nproc)

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://osm:osm@localhost:5432/osm}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
MAX_ZOOM="${MAX_ZOOM:-15}"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"
BBOX="${BBOX:-}"
LAYERS="${LAYERS:-standard}"
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
export_layer() {
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
export_railway_line_high() {
  local layer_name="$1"
  local where_clause="$2"
  local include_popup_fields="${3:-false}"
  local popup_columns=""

  if [ "${include_popup_fields}" = "true" ]; then
    popup_columns=",
  osm_id,
  osm_type,
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
  gauge0,
  gaugeint1,
  gauge1,
  gaugeint2,
  gauge2,
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
  route_count,
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
  id,
  way,
  way_length,
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
  preferred_direction,
  rank${popup_columns}
FROM railway_line_view lv
WHERE ${where_clause}
ORDER BY
  layer,
  rank NULLS LAST,
  maxspeed NULLS FIRST
"
}

export_railway_line_high "railway_line_high" "true" true

# railway_text_km — kilometer markers
# Split into two layers matching Martin's zoom-dependent filtering:
# z10-12: only zero markers (zero=true), z13+: all markers
export_layer "railway_text_km_low" "
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
WHERE zero = true
"

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

echo ""
echo "[Standard style layers]"

# standard_railway_line_low (z0-7) — simplified low-zoom lines
# Note: Martin aggregates with GROUP BY + st_collect + st_simplify, but this
# produces MULTILINESTRING geometries that cause tippecanoe segfaults.
# With -r1 (no feature dropping), individual segments render correctly at low zoom.
export_layer "standard_railway_line_low" "
SELECT
  id,
  osm_id,
  osm_type,
  way,
  way_length,
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
  track_class,
  nullif(array_to_string(reporting_marks, U&'\001E'), '') as reporting_marks,
  preferred_direction,
  rank,
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
  gauge0,
  gaugeint1,
  gauge1,
  gaugeint2,
  gauge2,
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
  route_count,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description
FROM railway_line_view lv
WHERE state = 'present'
  AND feature IN ('rail', 'ferry')
  AND usage = 'main'
  AND service IS NULL
ORDER BY rank NULLS LAST
"

# Station text layers — all from railway_text_stations view
# We export the full view and use it for all station zoom levels
# The style handles zoom filtering via minzoom/maxzoom
export_layer "standard_railway_text_stations" "
SELECT
  id,
  way,
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
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(s.station_routes) AS route_items(route_item)) as station_routes,
  discr_iso
FROM railway_text_stations s
WHERE name IS NOT NULL
ORDER BY
  rank DESC NULLS LAST,
  importance DESC NULLS LAST
"

# Station low-zoom layers. Split per zoom to match Martin's z-dependent
# discr_iso threshold while keeping discr_iso available in the PMTiles.
for z in 4 5 6 7; do
  export_layer "standard_railway_text_stations_low_z${z}" "
SELECT
  id, way,
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
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(s.station_routes) AS route_items(route_item)) as station_routes,
  discr_iso
FROM railway_text_stations s
WHERE feature = 'station' AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
  AND 213000 * exp(-0.33 * ${z}) - 18000 < discr_iso
  AND station_size IN ('large', 'normal')
ORDER BY importance DESC NULLS LAST
"
done

# z7-8: all station types except light_rail/monorail/subway.
for z in 7 8; do
  export_layer "standard_railway_text_stations_med_z${z}" "
SELECT
  id, way,
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
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(s.station_routes) AS route_items(route_item)) as station_routes,
  discr_iso
FROM railway_text_stations s
WHERE feature = 'station' AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
  AND 213000 * exp(-0.33 * ${z}) - 18000 < discr_iso
ORDER BY importance DESC NULLS LAST
"
done

# standard_railway_turntables (z10+)
export_layer "standard_railway_turntables" "
SELECT id, osm_id, osm_type, way, feature FROM standard_railway_turntables_view
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
  id, osm_id, osm_type, way, feature, ref, name, minzoom,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM poi_view
WHERE layer = 'standard' AND minzoom <= ${symbols_effective_max_zoom}
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
  (SELECT nullif(array_to_string(array_agg(
    (route_item -> 'route_id') || U&'\001E' ||
    coalesce(route_item -> 'color', '') || U&'\001E' ||
    coalesce(route_item -> 'label', '')
    ORDER BY route_item -> 'route_id'
  ), U&'\001D'), '') FROM unnest(s.station_routes) AS route_items(route_item)) as station_routes
FROM railway_text_stations s
"

# standard_railway_grouped_station_areas (z13+)
export_layer "standard_railway_grouped_station_areas" "
SELECT
  id,
  osm_id,
  osm_type,
  feature,
  way
FROM standard_railway_grouped_station_areas_view
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
for z in 13 14 15 16 17; do
  export_layer "electrification_railway_symbols_z${z}" "
SELECT
  id, way, feature, ref, minzoom
FROM poi_view
WHERE layer = 'electrification' AND minzoom <= ${z}
ORDER BY rank DESC
"
done

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
for z in 13 14 15 16 17; do
  export_layer "operator_railway_symbols_z${z}" "
SELECT
  id, way, feature, ref, minzoom
FROM poi_view
WHERE layer = 'operator' AND minzoom <= ${z}
ORDER BY rank DESC
"
done

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

# Add each layer with zoom range from martin configuration
add_layer() {
  local name="$1"
  local minzoom="$2"
  local maxzoom="$3"
  local file="${FGB_DIR}/${name}.fgb"

  if (( minzoom > MAX_ZOOM )); then
    echo "  [skip] ${name} (minzoom ${minzoom} > MAX_ZOOM ${MAX_ZOOM})"
    return 0
  fi
  if (( maxzoom > MAX_ZOOM )); then
    maxzoom="${MAX_ZOOM}"
  fi
  if (( maxzoom < minzoom )); then
    echo "  [skip] ${name} (empty zoom range ${minzoom}-${maxzoom})"
    return 0
  fi

  if [ -f "${file}" ] && [ -s "${file}" ]; then
    TIPPECANOE_ARGS+=("-L" "{\"file\":\"${file}\",\"layer\":\"${name}\",\"minzoom\":${minzoom},\"maxzoom\":${maxzoom}}")
  else
    echo "  [skip] ${name} (no data)"
  fi
}

# Add a layer with a different file name than layer name
# Useful for splitting one logical layer into multiple zoom-ranged FGBs
add_layer_named() {
  local file_name="$1"
  local layer_name="$2"
  local minzoom="$3"
  local maxzoom="$4"
  local file="${FGB_DIR}/${file_name}.fgb"

  if (( minzoom > MAX_ZOOM )); then
    echo "  [skip] ${file_name} -> ${layer_name} (minzoom ${minzoom} > MAX_ZOOM ${MAX_ZOOM})"
    return 0
  fi
  if (( maxzoom > MAX_ZOOM )); then
    maxzoom="${MAX_ZOOM}"
  fi
  if (( maxzoom < minzoom )); then
    echo "  [skip] ${file_name} -> ${layer_name} (empty zoom range ${minzoom}-${maxzoom})"
    return 0
  fi

  if [ -f "${file}" ] && [ -s "${file}" ]; then
    TIPPECANOE_ARGS+=("-L" "{\"file\":\"${file}\",\"layer\":\"${layer_name}\",\"minzoom\":${minzoom},\"maxzoom\":${maxzoom}}")
  else
    echo "  [skip] ${file_name} -> ${layer_name} (no data)"
  fi
}

add_layer_capped_to_max() {
  local name="$1"
  local minzoom="$2"
  local maxzoom="$3"

  if (( minzoom > MAX_ZOOM )); then
    add_layer_named "${name}" "${name}" "${MAX_ZOOM}" "${MAX_ZOOM}"
  else
    add_layer "${name}" "${minzoom}" "${maxzoom}"
  fi
}

# Shared
add_layer "railway_line_high" 7 "${MAX_ZOOM}"
# railway_text_km: z10-12 zero markers only, z13+ all markers
# Both use the same tippecanoe layer name for seamless zoom transitions
add_layer_named "railway_text_km_low" "railway_text_km" 10 12
add_layer "railway_text_km"                       13 "${MAX_ZOOM}"

# Standard
add_layer "standard_railway_line_low"             0  7
for z in 4 5 6 7; do
  add_layer_named "standard_railway_text_stations_low_z${z}" "standard_railway_text_stations_low" "${z}" "${z}"
done
for z in 7 8; do
  add_layer_named "standard_railway_text_stations_med_z${z}" "standard_railway_text_stations_med" "${z}" "${z}"
done
add_layer "standard_railway_text_stations"        8  "${MAX_ZOOM}"
add_layer "standard_railway_turntables"           10 "${MAX_ZOOM}"
add_layer_capped_to_max "standard_station_entrances"     16 "${MAX_ZOOM}"
add_layer "standard_railway_symbols"              12 "${MAX_ZOOM}"
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
add_layer_named "signals_signal_boxes_low" "signals_signal_boxes" 8  13
add_layer_named "signals_signal_boxes_high" "signals_signal_boxes" 14 14
add_layer "signals_railway_signals"               13 "${MAX_ZOOM}"

# Electrification
add_layer "electrification_railway_line_low"      0  7
add_layer "electrification_signals"               13 "${MAX_ZOOM}"
for z in 13 14 15 16 17; do
  add_layer_named "electrification_railway_symbols_z${z}" "electrification_railway_symbols" "${z}" "${z}"
done
add_layer "electrification_catenary"              14 "${MAX_ZOOM}"
add_layer "electrification_substation"            13 "${MAX_ZOOM}"

# Track
add_layer "track_railway_line_low"                0  7

# Operator
add_layer "operator_railway_line_low"             0  7
for z in 13 14 15 16 17; do
  add_layer_named "operator_railway_symbols_z${z}" "operator_railway_symbols" "${z}" "${z}"
done

# Route
add_layer "route_railway_line_low"                0  7
fi  # end LAYERS=all

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
