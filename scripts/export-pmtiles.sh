#!/usr/bin/env bash
# Export ORM standard-style vector tiles to PMTiles format.
#
# Prerequisites:
#   - PostgreSQL with ORM data imported (DATABASE_URL set)
#   - martin binary available in PATH
#   - pmtiles CLI available in PATH
#
# Usage:
#   export DATABASE_URL=postgresql://postgres@localhost:5432/gis
#   ./scripts/export-pmtiles.sh [output_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_DIR/output}"
MARTIN_CONFIG="$REPO_DIR/martin/export-config.yaml"
MBTILES_FILE="$OUTPUT_DIR/railway-standard.mbtiles"
PMTILES_FILE="$OUTPUT_DIR/railway-standard.pmtiles"
MIN_ZOOM="${MIN_ZOOM:-0}"
MAX_ZOOM="${MAX_ZOOM:-14}"
CONCURRENCY="${CONCURRENCY:-8}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "ERROR: DATABASE_URL is not set." >&2
  echo "Example: export DATABASE_URL=postgresql://postgres@localhost:5432/gis" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Exporting ORM standard tiles (z${MIN_ZOOM}-${MAX_ZOOM}) ==="
echo "Config: $MARTIN_CONFIG"
echo "Output: $OUTPUT_DIR"

# Step 1: Export to MBTiles via martin-cp
echo ""
echo "--- Step 1/2: martin-cp → MBTiles ---"
rm -f "$MBTILES_FILE"

martin-cp \
  --config "$MARTIN_CONFIG" \
  --output-file "$MBTILES_FILE" \
  --min-zoom "$MIN_ZOOM" \
  --max-zoom "$MAX_ZOOM" \
  --concurrency "$CONCURRENCY" \
  --encoding gzip

MBTILES_SIZE=$(du -h "$MBTILES_FILE" | cut -f1)
echo "MBTiles created: $MBTILES_FILE ($MBTILES_SIZE)"

# Step 2: Convert MBTiles → PMTiles
echo ""
echo "--- Step 2/2: MBTiles → PMTiles ---"
rm -f "$PMTILES_FILE"

pmtiles convert "$MBTILES_FILE" "$PMTILES_FILE"

PMTILES_SIZE=$(du -h "$PMTILES_FILE" | cut -f1)
echo "PMTiles created: $PMTILES_FILE ($PMTILES_SIZE)"

# Cleanup intermediate MBTiles (optional, keep for debugging)
# rm -f "$MBTILES_FILE"

echo ""
echo "=== Done ==="
echo "PMTiles file: $PMTILES_FILE ($PMTILES_SIZE)"
