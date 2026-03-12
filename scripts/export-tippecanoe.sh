#!/usr/bin/env bash
# Export ORM vector tiles using ogr2ogr (FlatGeobuf) + tippecanoe → PMTiles
# This replaces the slow martin-cp approach with a much faster pipeline.
#
# Usage: ./scripts/export-tippecanoe.sh
#
# Environment variables:
#   DATABASE_URL  - PostgreSQL connection string (default: postgresql://osm:osm@localhost:5432/osm)
#   OUTPUT_DIR    - Output directory (default: ./output)
#   MAX_ZOOM      - Maximum zoom level (default: 14)
#   CONCURRENCY   - tippecanoe parallelism (default: nproc)

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://osm:osm@localhost:5432/osm}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
MAX_ZOOM="${MAX_ZOOM:-14}"
CONCURRENCY="${CONCURRENCY:-$(nproc)}"
BBOX="${BBOX:-}"
FGB_DIR="${OUTPUT_DIR}/fgb"

mkdir -p "${FGB_DIR}"

echo "=== ORM PMTiles Export (tippecanoe) ==="
echo "Database: ${DATABASE_URL}"
echo "Output: ${OUTPUT_DIR}"
echo "Max zoom: ${MAX_ZOOM}"
echo "Concurrency: ${CONCURRENCY}"
if [ -n "${BBOX}" ]; then
  echo "BBOX filter: ${BBOX}"
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
  if [ -n "${BBOX}" ]; then
    IFS=',' read -r minlon minlat maxlon maxlat <<< "${BBOX}"
    ogr_args+=(-spat "${minlon}" "${minlat}" "${maxlon}" "${maxlat}" -spat_srs EPSG:4326)
  fi

  ogr2ogr "${ogr_args[@]}" \
    2>&1 | tail -5 || {
      echo "  [WARN] ${layer_name} export failed, creating empty placeholder"
      rm -f "${outfile}"
      return 0
    }

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

# railway_line_high (z7+) — main railway lines with all attributes
# This is the most important and largest layer
export_layer "railway_line_high" "
SELECT
  r.id,
  osm_id,
  way,
  way_length,
  feature,
  state,
  usage,
  service,
  highspeed,
  tunnel,
  bridge,
  CASE
    WHEN ref IS NOT NULL AND r.name IS NOT NULL THEN ref || ' ' || r.name
    ELSE COALESCE(ref, r.name)
  END AS standard_label,
  ref,
  track_ref,
  track_class,
  array_to_string(reporting_marks, ', ') as reporting_marks,
  preferred_direction,
  rank,
  maxspeed,
  speed_label,
  train_protection_rank,
  train_protection,
  train_protection_construction_rank,
  train_protection_construction,
  electrification_state,
  voltage,
  frequency,
  maximum_current,
  railway_electrification_label(COALESCE(voltage, future_voltage), COALESCE(frequency, future_frequency)) AS electrification_label,
  future_voltage,
  future_frequency,
  future_maximum_current,
  railway_to_int(gauges[1]) AS gaugeint0,
  gauges[1] AS gauge0,
  railway_to_int(gauges[2]) AS gaugeint1,
  gauges[2] AS gauge1,
  railway_to_int(gauges[3]) AS gaugeint2,
  gauges[3] AS gauge2,
  (select string_agg(gauge, ' | ') from unnest(gauges) as gauge where gauge ~ '^[0-9]+\$') as gauge_label,
  loading_gauge,
  nullif(array_to_string(operator, U&'\001E'), '') as operator,
  COALESCE(
    ro.color,
    'hsl(' || get_byte(sha256(primary_operator::bytea), 0) || ', 100%, 30%)'
  ) as operator_color,
  primary_operator,
  owner,
  traffic_mode,
  radio,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description
FROM (
  SELECT
    *,
    CASE
      WHEN ARRAY[owner] <@ operator THEN owner
      ELSE operator[1]
    END AS primary_operator
  FROM railway_line
) AS r
LEFT JOIN railway_operator ro
  ON ro.name = primary_operator
"

# railway_text_km (z10+) — kilometer markers
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
"

# ============================================================
# Standard style layers
# ============================================================

echo ""
echo "[Standard style layers]"

# standard_railway_line_low (z0-7) — simplified low-zoom lines
# Uses the railway_line_low view which filters to main present lines
export_layer "standard_railway_line_low" "
SELECT
  id,
  osm_id,
  way,
  feature,
  state,
  usage,
  highspeed,
  ref,
  standard_label,
  rank
FROM railway_line_low
"

# Station text layers — all from railway_text_stations view
# We export the full view and use it for all station zoom levels
# The style handles zoom filtering via minzoom/maxzoom
export_layer "standard_railway_text_stations" "
SELECT
  id,
  way,
  osm_id,
  osm_type,
  feature,
  state,
  station,
  station_size,
  map_reference as label,
  name,
  name as localized_name,
  count,
  operator,
  operator_color,
  network,
  position,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description,
  yard_purpose,
  yard_hump,
  station_routes,
  importance,
  discr_iso,
  rank
FROM railway_text_stations
"

# Export the same data as separate layers for low/med zoom with different filters
# standard_railway_text_stations_low (z4-7): only large/normal present stations
export_layer "standard_railway_text_stations_low" "
SELECT
  id,
  way,
  osm_id,
  osm_type,
  feature,
  state,
  station,
  station_size,
  map_reference as label,
  name,
  name as localized_name,
  operator,
  operator_color,
  network,
  position,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description,
  yard_purpose,
  yard_hump,
  station_routes
FROM railway_text_stations
WHERE feature = 'station'
  AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
  AND station_size IN ('large', 'normal')
"

# standard_railway_text_stations_med (z7-8): similar but more stations
export_layer "standard_railway_text_stations_med" "
SELECT
  id,
  way,
  osm_id,
  osm_type,
  feature,
  state,
  station,
  station_size,
  map_reference as label,
  name,
  name as localized_name,
  operator,
  operator_color,
  network,
  position,
  wikidata,
  wikimedia_commons,
  wikimedia_commons_file,
  image,
  mapillary,
  wikipedia,
  note,
  description,
  yard_purpose,
  yard_hump,
  station_routes
FROM railway_text_stations
WHERE feature = 'station'
  AND state = 'present'
  AND (station IS NULL OR station NOT IN ('light_rail', 'monorail', 'subway'))
"

# standard_railway_turntables (z10+)
export_layer "standard_railway_turntables" "
SELECT id, osm_id, way, feature FROM turntables
"

# standard_station_entrances (z16+)
export_layer "standard_station_entrances" "
SELECT
  id, osm_id, way, type, name, ref,
  CASE
    WHEN name IS NOT NULL AND ref IS NOT NULL THEN CONCAT(name, ' (', ref, ')')
    ELSE COALESCE(name, ref)
  END AS label,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM station_entrances
"

# standard_railway_symbols (z10+) — from pois table, standard layer
export_layer "standard_railway_symbols" "
SELECT
  id, osm_id, osm_type, way, feature, ref, name,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM pois
WHERE layer = 'standard'
"

# standard_railway_platforms (z15+)
export_layer "standard_railway_platforms" "
SELECT
  id, osm_id, osm_type, way,
  'platform' as feature, name,
  nullif(array_to_string(ref, U&'\001E'), '') as ref,
  height, surface, elevator, shelter, lit, bin, bench,
  wheelchair, departures_board, tactile_paving
FROM platforms
"

# standard_railway_platform_edges (z17+)
export_layer "standard_railway_platform_edges" "
SELECT
  id, osm_id, way,
  'platform_edge' as feature,
  ref, height, tactile_paving
FROM platform_edge
"

# standard_railway_stop_positions (z16+)
export_layer "standard_railway_stop_positions" "
SELECT
  id, osm_id, way, name, type, ref, local_ref
FROM stop_positions
"

# standard_railway_switch_ref (z17+)
export_layer "standard_railway_switch_ref" "
SELECT
  id, osm_id, way, railway, ref, type,
  turnout_side, local_operated, resetting,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM railway_switches
"

# standard_railway_grouped_stations (z13+) — clustered station points
export_layer "standard_railway_grouped_stations" "
SELECT
  gs.id,
  center as way,
  nullif(array_to_string(osm_ids, U&'\001E'), '') as osm_id,
  nullif(array_to_string(osm_types, U&'\001E'), '') as osm_type,
  feature,
  state,
  station,
  map_reference as label,
  gs.name,
  uic_ref,
  nullif(array_to_string(gs.operator, U&'\001E'), '') as operator,
  nullif(array_to_string(network, U&'\001E'), '') as network,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  COALESCE(
    ro.color,
    'hsl(' || get_byte(sha256(gs.operator[1]::bytea), 0) || ', 100%, 30%)'
  ) as operator_color,
  nullif(array_to_string(wikidata, U&'\001E'), '') as wikidata,
  nullif(array_to_string(wikimedia_commons, U&'\001E'), '') as wikimedia_commons,
  nullif(array_to_string(wikimedia_commons_file, U&'\001E'), '') as wikimedia_commons_file,
  nullif(array_to_string(image, U&'\001E'), '') as image,
  nullif(array_to_string(mapillary, U&'\001E'), '') as mapillary,
  nullif(array_to_string(wikipedia, U&'\001E'), '') as wikipedia,
  nullif(array_to_string(note, U&'\001E'), '') as note,
  nullif(array_to_string(description, U&'\001E'), '') as description
FROM grouped_stations_with_importance gs
LEFT JOIN railway_operator ro
  ON ro.name = gs.operator[1]
"

# standard_railway_grouped_station_areas (z13+)
export_layer "standard_railway_grouped_station_areas" "
SELECT
  osm_id as id,
  osm_id,
  'station_area_group' as feature,
  way
FROM stop_area_groups_buffered
"

# ============================================================
# Speed style layers
# ============================================================

echo ""
echo "[Speed style layers]"

# speed_railway_line_low (z0-7)
export_layer "speed_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage,
  maxspeed, ref, standard_label, speed_label, rank
FROM railway_line_low
"

# speed_railway_signals (z13+) — from signal_features
export_layer "speed_railway_signals" "
SELECT id, osm_id, way, feature, type, ref, ref_multiline,
  deactivated, speed_limit, speed_limit_speed, direction_both
FROM signal_features
WHERE type IN ('speed', 'speed_main', 'speed_distant', 'speed_construction')
  OR speed_limit IS NOT NULL
  OR speed_limit_speed IS NOT NULL
"

# ============================================================
# Signals style layers
# ============================================================

echo ""
echo "[Signals style layers]"

# signals_railway_line_low (z0-7)
export_layer "signals_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref, standard_label,
  train_protection_rank, train_protection,
  train_protection_construction_rank, train_protection_construction,
  rank
FROM railway_line_low
"

# signals_signal_boxes (z8-14) — from boxes table
export_layer "signals_signal_boxes" "
SELECT
  b.id, osm_id, osm_type,
  center as way,
  feature, ref, b.name, operator,
  COALESCE(
    ro.color,
    'hsl(' || get_byte(sha256(operator::bytea), 0) || ', 100%, 30%)'
  ) as operator_color,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM boxes b
LEFT JOIN railway_operator ro
  ON ro.name = operator
"

# signals_railway_signals (z13+) — all signal features
export_layer "signals_railway_signals" "
SELECT * FROM signal_features
"

# ============================================================
# Electrification style layers
# ============================================================

echo ""
echo "[Electrification style layers]"

# electrification_railway_line_low (z0-7)
export_layer "electrification_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref, standard_label,
  electrification_state, electrification_label,
  voltage, frequency, maximum_current,
  rank
FROM railway_line_low
"

# electrification_signals (z13+)
export_layer "electrification_signals" "
SELECT id, osm_id, way, feature, type, ref, ref_multiline, deactivated
FROM signal_features
WHERE type IN ('electrification', 'catenary')
"

# electrification_railway_symbols (z13+) — from pois, electrification layer
export_layer "electrification_railway_symbols" "
SELECT
  id, osm_id, osm_type, way, feature, ref,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM pois
WHERE layer = 'electrification'
"

# electrification_catenary (z14+)
export_layer "electrification_catenary" "
SELECT
  id, osm_id, osm_type, way, feature, ref,
  transition, structure, supporting, attachment, tensioning, insulator,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  note, description
FROM catenary
"

# electrification_substation (z13+)
export_layer "electrification_substation" "
SELECT
  id, osm_id, way, feature, ref, name, location, operator,
  nullif(array_to_string(voltage, U&'\001E'), '') as voltage,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM substation
"

# ============================================================
# Track style layers
# ============================================================

echo ""
echo "[Track style layers]"

# track_railway_line_low (z0-7)
export_layer "track_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref, standard_label,
  gaugeint0, gauge0, gauge_label, track_class, loading_gauge, rank
FROM railway_line_low
"

# ============================================================
# Operator style layers
# ============================================================

echo ""
echo "[Operator style layers]"

# operator_railway_line_low (z0-7)
export_layer "operator_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref, standard_label,
  operator, operator_color, primary_operator, owner, rank
FROM railway_line_low
"

# operator_railway_symbols (z13+) — from pois, operator layer
export_layer "operator_railway_symbols" "
SELECT
  id, osm_id, osm_type, way, feature, ref, name,
  nullif(array_to_string(position, U&'\001E'), '') as position,
  wikidata, wikimedia_commons, wikimedia_commons_file,
  image, mapillary, wikipedia, note, description
FROM pois
WHERE layer = 'operator'
"

# ============================================================
# Route style layers
# ============================================================

echo ""
echo "[Route style layers]"

# route_railway_line_low (z0-7)
export_layer "route_railway_line_low" "
SELECT
  id, osm_id, way, feature, state, usage, ref, standard_label, rank
FROM railway_line_low
"

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

  # Attribution
  --name="OpenRailwayMap"
  --description="OpenRailwayMap vector tiles"
  --attribution="© OpenStreetMap contributors | Style: OpenRailwayMap"
)

# Add each layer with zoom range from martin configuration
add_layer() {
  local name="$1"
  local minzoom="$2"
  local maxzoom="$3"
  local file="${FGB_DIR}/${name}.fgb"

  if [ -f "${file}" ] && [ -s "${file}" ]; then
    TIPPECANOE_ARGS+=("-L" "{\"file\":\"${file}\",\"layer\":\"${name}\",\"minzoom\":${minzoom},\"maxzoom\":${maxzoom}}")
  else
    echo "  [skip] ${name} (no data)"
  fi
}

# Shared
add_layer "railway_line_high"                     7  "${MAX_ZOOM}"
add_layer "railway_text_km"                       10 "${MAX_ZOOM}"

# Standard
add_layer "standard_railway_line_low"             0  7
add_layer "standard_railway_text_stations_low"    4  7
add_layer "standard_railway_text_stations_med"    7  8
add_layer "standard_railway_text_stations"        8  "${MAX_ZOOM}"
add_layer "standard_railway_turntables"           10 "${MAX_ZOOM}"
add_layer "standard_station_entrances"            16 "${MAX_ZOOM}"
add_layer "standard_railway_symbols"              10 "${MAX_ZOOM}"
add_layer "standard_railway_platforms"             15 "${MAX_ZOOM}"
add_layer "standard_railway_platform_edges"        17 "${MAX_ZOOM}"
add_layer "standard_railway_stop_positions"        16 "${MAX_ZOOM}"
add_layer "standard_railway_switch_ref"            17 "${MAX_ZOOM}"
add_layer "standard_railway_grouped_stations"      13 "${MAX_ZOOM}"
add_layer "standard_railway_grouped_station_areas" 13 "${MAX_ZOOM}"

# Speed
add_layer "speed_railway_line_low"                0  7
add_layer "speed_railway_signals"                 13 "${MAX_ZOOM}"

# Signals
add_layer "signals_railway_line_low"              0  7
add_layer "signals_signal_boxes"                  8  14
add_layer "signals_railway_signals"               13 "${MAX_ZOOM}"

# Electrification
add_layer "electrification_railway_line_low"      0  7
add_layer "electrification_signals"               13 "${MAX_ZOOM}"
add_layer "electrification_railway_symbols"       13 "${MAX_ZOOM}"
add_layer "electrification_catenary"              14 "${MAX_ZOOM}"
add_layer "electrification_substation"            13 "${MAX_ZOOM}"

# Track
add_layer "track_railway_line_low"                0  7

# Operator
add_layer "operator_railway_line_low"             0  7
add_layer "operator_railway_symbols"              13 "${MAX_ZOOM}"

# Route
add_layer "route_railway_line_low"                0  7

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
