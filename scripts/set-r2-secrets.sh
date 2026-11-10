#!/usr/bin/env bash
# Copy R2 credentials from the environment into GitHub Actions secrets
# used by the export-pmtiles and cleanup-r2-test-files workflows.
#
# Usage: ./scripts/set-r2-secrets.sh owner/repo
#
# Reads (first non-empty wins):
#   R2_ACCESS_KEY_ID      or AWS_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY  or AWS_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#
# Values are piped to `gh secret set` on stdin, so they never appear in
# the process list or shell history.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 owner/repo" >&2
  exit 2
fi
REPO="$1"

declare -A SOURCES=(
  [R2_ACCESS_KEY_ID]="R2_ACCESS_KEY_ID AWS_ACCESS_KEY_ID"
  [R2_SECRET_ACCESS_KEY]="R2_SECRET_ACCESS_KEY AWS_SECRET_ACCESS_KEY"
  [R2_ACCOUNT_ID]="R2_ACCOUNT_ID"
)

declare -A VALUES=()
missing=0
for secret in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID; do
  for var in ${SOURCES[$secret]}; do
    if [ -n "${!var:-}" ]; then
      VALUES[$secret]="${!var}"
      break
    fi
  done
  if [ -z "${VALUES[$secret]:-}" ]; then
    echo "error: ${secret} not found (set one of: ${SOURCES[$secret]})" >&2
    missing=1
  fi
done
[ "${missing}" -eq 0 ] || exit 1

echo "Setting secrets on ${REPO}"
for secret in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID; do
  printf '%s' "${VALUES[$secret]}" | gh secret set "${secret}" --repo "${REPO}"
done

gh secret list --repo "${REPO}"
