#!/usr/bin/env bash
# =============================================================================
# deploy.sh -- Manufacturing OEE & Maintenance Decision Copilot
#
#   ./sql/deploy.sh                          # full deploy, batched (fast)
#   ./sql/deploy.sh HACK2SKILL_DEMO          # explicit connection
#   ./sql/deploy.sh HACK2SKILL_DEMO 60       # resume from 60_*
#   ./sql/deploy.sh HACK2SKILL_DEMO 00 --per-file   # one session per file (debugging)
#
# Filenames encode dependency order; do not reorder them. Every file is idempotent
# (CREATE OR REPLACE / IF NOT EXISTS / INSERT OVERWRITE) so a full re-run is safe.
#
# WHY BATCHED BY DEFAULT
# ----------------------
# Measured cost of a single `snow sql` invocation against this account:
#     ~2.2 s  Python interpreter + CLI imports   (`snow --help` alone costs this)
#     ~2.8 s  Snowflake connection + auth handshake
#     ~0.9 s  PyPI version check over the network
#     ~5.9 s  total, per invocation, before any SQL executes
#
# One invocation per file therefore cost ~77 s of pure overhead across 13 files --
# more than the actual SQL work in most runs. Batching collapses that to one
# handshake. The version check is disabled via the environment variable.
#
# File-level attribution is preserved by emitting a marker SELECT before each file,
# so the last marker printed identifies the file that failed.
#
# The corpus upload has to sit between 42 (creates the stage) and 45 (reads from it),
# so a full deploy is two batches with a PUT in between, not one.
# =============================================================================
set -uo pipefail

CONNECTION="${1:-HACK2SKILL_DEMO}"
START_FROM="${2:-00}"
MODE="${3:-batch}"
SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SNOWFLAKE_CLI_IGNORE_NEW_VERSION_WARNING=true

run_sql_file() { snow sql -c "${CONNECTION}" -f "$1" 2>&1; }

upload_corpus() {
  printf '=== put   %-40s' "documents/maintenance_approved/*.md"
  if out="$(snow stage copy "${SQL_DIR}/../documents/maintenance_approved/" \
               '@MFG_COPILOT_DB.GOVERNANCE.PROCEDURE_DOCS' \
               --overwrite -c "${CONNECTION}" 2>&1)"; then
    echo "OK"
    return 0
  fi
  echo "FAILED"; echo "$out" | tail -20; return 1
}

echo "==> Target connection: ${CONNECTION}   (mode: ${MODE}, from: ${START_FROM}_)"
snow sql -c "${CONNECTION}" -q \
  "SELECT CURRENT_ACCOUNT() AS account, CURRENT_ROLE() AS role, CURRENT_REGION() AS region" \
  2>/dev/null | grep -E '^\|' || true
echo

# Collect the files in scope.
files=()
for f in "${SQL_DIR}"/*.sql; do
  base="$(basename "$f")"
  [[ "${base%%_*}" < "${START_FROM}" ]] && continue
  files+=("$f")
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "==> Nothing to deploy at or after ${START_FROM}_"; exit 0
fi

# -----------------------------------------------------------------------------
# Per-file mode: one session per file. Slower, but isolates a failure cleanly.
# -----------------------------------------------------------------------------
if [[ "${MODE}" == "--per-file" ]]; then
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    printf '=== run   %-40s' "${base}"
    if out="$(run_sql_file "$f")"; then echo "OK"; else
      echo "FAILED"; echo "$out" | tail -25
      echo; echo "==> Fix ${base} and re-run:  ./sql/deploy.sh ${CONNECTION} ${base%%_*}"
      exit 1
    fi
    [[ "${base%%_*}" == "42" ]] && { upload_corpus || exit 1; }
    if [[ "${base%%_*}" == "95" ]]; then
      printf '=== put   %-40s' "app/streamlit/* -> STREAMLIT_STAGE"
      if out="$(snow stage copy "${SQL_DIR}/../app/streamlit/" '@MFG_COPILOT_DB.APP.STREAMLIT_STAGE' --overwrite -c "${CONNECTION}" 2>&1)"; then echo "OK"; else
        echo "FAILED"; echo "$out" | tail -20; exit 1
      fi
    fi
  done
  echo; echo "==> Deploy complete."
  exit 0
fi

# -----------------------------------------------------------------------------
# Batch mode: concatenate into at most two sessions, split at the corpus upload.
# -----------------------------------------------------------------------------
batch_dir="$(mktemp -d)"
trap 'rm -rf "${batch_dir}"' EXIT

pre="${batch_dir}/pre.sql"; post="${batch_dir}/post.sql"
: > "$pre"; : > "$post"
needs_upload=0; pre_files=(); post_files=()

for f in "${files[@]}"; do
  base="$(basename "$f")"
  if [[ "${base%%_*}" -le 42 ]] 2>/dev/null; then
    target="$pre"; pre_files+=("$base")
    [[ "${base%%_*}" == "42" ]] && needs_upload=1
  else
    target="$post"; post_files+=("$base")
  fi
  # Marker so a failure can be attributed to a file within the batch.
  printf "\nSELECT '>>> %s' AS deploy_step;\n" "$base" >> "$target"
  cat "$f" >> "$target"
done

run_batch() {
  local batch_file="$1"; shift
  local -a names=("$@")
  [[ ! -s "$batch_file" ]] && return 0

  # ${names[-1]} needs bash 4.3+; macOS still ships 3.2, so index explicitly.
  local n=${#names[@]}
  local first="${names[0]}"
  local last_name="${names[$((n - 1))]}"

  printf '=== batch %-40s' "${n} file(s): ${first} .. ${last_name}"
  if out="$(run_sql_file "$batch_file")"; then
    echo "OK"
    return 0
  fi
  echo "FAILED"
  local last
  last="$(grep -o '>>> [0-9A-Za-z_.]*\.sql' <<<"$out" | tail -1)"
  echo
  echo "--- failed in: ${last:-<before the first marker>}"
  echo "$out" | tail -25
  if [[ -n "${last}" ]]; then
    local prefix="${last#>>> }"; prefix="${prefix%%_*}"
    echo; echo "==> Re-run from there:  ./sql/deploy.sh ${CONNECTION} ${prefix} --per-file"
  fi
  return 1
}

# Guard against an empty array being splatted into run_batch under `set -u`.
if [[ ${#pre_files[@]} -gt 0 ]]; then
  run_batch "$pre" "${pre_files[@]}" || exit 1
fi
[[ "${needs_upload}" -eq 1 ]] && { upload_corpus || exit 1; }
if [[ ${#post_files[@]} -gt 0 ]]; then
  run_batch "$post" "${post_files[@]}" || exit 1
fi

echo; echo "==> Deploy complete."
