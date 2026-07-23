#!/usr/bin/env bash
set -euo pipefail

operation="${1:-}"
scope="${2:-}"
wave_size="${3:-500}"
batch_size="${4:-25}"
confirm_write="${5:-false}"
confirm_rights="${6:-false}"

repo_dir="${SPINE_DEPLOY_DIR:-$HOME/projects/spine-deploy}"
env_file="${SPINE_DEPLOY_ENV_FILE:-$HOME/projects/spine/.env.production}"
expected_sha="${SPINE_EXPECTED_SHA:-}"
state_dir="$repo_dir/backups/external-ratings"
summary_file="${GITHUB_STEP_SUMMARY:-}"

scopes=(
  tmdb_movie
  mdblist_movie
  tmdb_tv
  mdblist_tv
  tmdb_season
  mdblist_season
  tmdb_episode
  imdb_episode
  mal_anime
  mal_manga
  mangaupdates_manga
  igdb_game
  metacritic_game
  openlibrary_book
  hardcover_book
  musicbrainz_music
)

die() {
  echo "$1" >&2
  exit 1
}

append_summary() {
  [[ -n "$summary_file" ]] || return 0
  printf '%s\n' "$1" >> "$summary_file"
}

case "$operation" in
  inventory | backup | canary | backfill) ;;
  *) die "Invalid operation: $operation" ;;
esac

if [[ "$scope" != "all" ]] && [[ ! " ${scopes[*]} " =~ " $scope " ]]; then
  die "Invalid external-rating scope: $scope"
fi
if [[ ! "$wave_size" =~ ^(100|250|500|1000)$ ]]; then
  die "wave-size must be one of 100, 250, 500, or 1000"
fi
if [[ ! "$batch_size" =~ ^(10|25|50|100)$ ]]; then
  die "batch-size must be one of 10, 25, 50, or 100"
fi
if [[ "$operation" =~ ^(canary|backfill)$ && "$scope" == "all" ]]; then
  die "$operation requires one explicit scope"
fi
if [[ "$operation" == "backup" && "$scope" != "all" ]]; then
  die "backup requires scope all"
fi
if [[ "$operation" =~ ^(canary|backfill)$ && "$confirm_write" != "true" ]]; then
  die "$operation requires confirm_production_write"
fi
if [[ "$operation" == "backup" && "$confirm_rights" != "true" ]]; then
  die "backup requires confirm_provider_rights"
fi
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] || die "SPINE_EXPECTED_SHA must be a full Git commit SHA"
[[ -d "$repo_dir/.git" ]] || die "Missing deployed repository: $repo_dir"
[[ -f "$env_file" ]] || die "Missing production environment file"

deployed_sha="$(git -C "$repo_dir" rev-parse HEAD)"
if [[ -n "$expected_sha" && "$deployed_sha" != "$expected_sha" ]]; then
  die "Workflow commit $expected_sha does not match deployed commit $deployed_sha"
fi

compose=(
  docker compose
  --project-name spine
  --env-file "$env_file"
  -f "$repo_dir/docker-compose.production.yml"
)

manage() {
  "${compose[@]}" exec -T app python manage.py "$@"
}

celery() {
  "${compose[@]}" exec -T app celery -A config "$@"
}

preflight() {
  curl --fail --silent --show-error http://127.0.0.1:8000/health/ >/dev/null
  "${compose[@]}" exec -T redis redis-cli ping | grep -qx PONG
  container_sha="$("${compose[@]}" exec -T app printenv SPINE_COMMIT_SHA)"
  [[ "$container_sha" == "$deployed_sha" ]] || \
    die "Running app container $container_sha does not match deployed commit $deployed_sha"

  migrations="$(manage showmigrations app)"
  grep -q '\[X\] 0073_externalrating' <<<"$migrations"
  grep -q '\[X\] 0074_migrate_legacy_external_ratings' <<<"$migrations"

  for _ in {1..12}; do
    if celery inspect ping >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  celery inspect ping >/dev/null
  registered="$(celery inspect registered)"
  grep -q 'Enrich external ratings' <<<"$registered"
  grep -q 'Enrich external ratings batch' <<<"$registered"
}

scope_args() {
  case "$1" in
    tmdb_movie) args=(--rating-source tmdb --media-type movie --item-source tmdb) ;;
    mdblist_movie) args=(--rating-source imdb --rating-source letterboxd --rating-source tomatoes --media-type movie --item-source tmdb) ;;
    tmdb_tv) args=(--rating-source tmdb --media-type tv --item-source tmdb) ;;
    mdblist_tv) args=(--rating-source imdb --rating-source letterboxd --rating-source tomatoes --media-type tv --item-source tmdb) ;;
    tmdb_season) args=(--rating-source tmdb --media-type season --item-source tmdb) ;;
    mdblist_season) args=(--rating-source imdb --rating-source letterboxd --rating-source tomatoes --media-type season --item-source tmdb) ;;
    tmdb_episode) args=(--rating-source tmdb --media-type episode --item-source tmdb) ;;
    imdb_episode) args=(--rating-source imdb --media-type episode --item-source tmdb) ;;
    mal_anime) args=(--rating-source mal --media-type anime --item-source mal) ;;
    mal_manga) args=(--rating-source mal --media-type manga --item-source mal) ;;
    mangaupdates_manga) args=(--rating-source mangaupdates --media-type manga --item-source mangaupdates) ;;
    igdb_game) args=(--rating-source igdb --media-type game --item-source igdb) ;;
    metacritic_game) args=(--rating-source metacritic --media-type game --item-source igdb) ;;
    openlibrary_book) args=(--rating-source openlibrary --media-type book --item-source openlibrary) ;;
    hardcover_book) args=(--rating-source hardcover --media-type book --item-source hardcover) ;;
    musicbrainz_music) args=(--rating-source musicbrainz --media-type music --item-source musicbrainz) ;;
    *) die "Unsupported scope: $1" ;;
  esac
}

scope_enabled() {
  case "$1" in
    imdb_episode)
      manage shell -c \
        "from app.providers.imdb import is_configured; raise SystemExit(0 if is_configured() else 1)" \
        >/dev/null
      ;;
    musicbrainz_music)
      manage shell -c \
        "from django.conf import settings; raise SystemExit(0 if settings.MUSICBRAINZ_EXTERNAL_RATINGS_ENABLED else 1)" \
        >/dev/null
      ;;
    *) return 0 ;;
  esac
}

inventory_scope() {
  local selected_scope="$1"
  scope_args "$selected_scope"
  if ! scope_enabled "$selected_scope"; then
    echo "{\"event\":\"gated\",\"scope\":\"$selected_scope\",\"status\":\"runtime_disabled\"}"
    return 0
  fi
  manage backfill_external_ratings \
    "${args[@]}" \
    --coverage-only \
    --dry-run \
    --json
}

require_campaign() {
  campaign_marker="$state_dir/campaign-$deployed_sha.json"
  [[ -f "$campaign_marker" ]] || die "No verified external-rating campaign backup for deployed commit $deployed_sha"
  python3 - "$campaign_marker" "$deployed_sha" <<'PY'
import hashlib
import json
import os
import sys

marker_path, expected_commit = sys.argv[1:]
with open(marker_path, encoding="utf-8") as stream:
    marker = json.load(stream)
backup = marker.get("backup", "")
if (
    marker.get("commit") != expected_commit
    or marker.get("provider_rights_confirmed") is not True
    or not os.path.isfile(backup)
):
    raise SystemExit("Campaign backup marker is invalid")
digest = hashlib.sha256()
with open(backup, "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
if digest.hexdigest() != marker.get("checksum"):
    raise SystemExit("Campaign backup checksum does not match")
PY
}

require_canary() {
  canary_marker="$state_dir/canary-$deployed_sha-$scope.json"
  [[ -f "$canary_marker" ]] || die "No successful canary for scope $scope at deployed commit $deployed_sha"
  python3 - "$canary_marker" "$deployed_sha" "$scope" <<'PY'
import json
import sys

marker_path, expected_commit, expected_scope = sys.argv[1:]
with open(marker_path, encoding="utf-8") as stream:
    marker = json.load(stream)
if marker != {
    "commit": expected_commit,
    "scope": expected_scope,
    "status": "passed",
}:
    raise SystemExit("Scope canary marker is invalid")
PY
}

append_log_summary() {
  local log_file="$1"
  local selected_scope="$2"
  [[ -n "$summary_file" ]] || return 0
  python3 - "$log_file" "$summary_file" "$selected_scope" "$deployed_sha" <<'PY'
import json
import sys

log_path, summary_path, scope, commit = sys.argv[1:]
events = []
with open(log_path, encoding="utf-8") as stream:
    for line in stream:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
terminal = next(
    (event for event in reversed(events) if event.get("event") in {"complete", "paused", "failed"}),
    {},
)
rows = (
    ("Scope", scope),
    ("Deployed commit", commit[:12]),
    ("Status", terminal.get("status", "unknown")),
    ("Reason", terminal.get("reason", "")),
    ("Eligible pairs", terminal.get("eligible_pairs", "")),
    ("Starting covered pairs", terminal.get("starting_covered_pairs", "")),
    ("Ending covered pairs", terminal.get("ending_covered_pairs", "")),
    ("Starting pending pairs", terminal.get("starting_pending_pairs", "")),
    ("Ending pending pairs", terminal.get("ending_pending_pairs", "")),
    ("Batches completed", terminal.get("batches_completed", 0)),
    ("Items requested", terminal.get("items_requested", 0)),
    ("Available", terminal.get("available", 0)),
    ("Unavailable", terminal.get("unavailable", 0)),
    ("Failed", terminal.get("failed", 0)),
    ("Retrying items", terminal.get("retrying_items", 0)),
    ("Elapsed seconds", terminal.get("elapsed_seconds", 0)),
)
with open(summary_path, "a", encoding="utf-8") as summary:
    summary.write("\n| External-rating run | Result |\n|---|---|\n")
    for label, value in rows:
        summary.write(f"| {label} | {value} |\n")
PY
}

run_drain() {
  local selected_scope="$1"
  local max_items="${2:-}"
  local selected_wave="$wave_size"
  local selected_batch="$batch_size"
  scope_args "$selected_scope"
  scope_enabled "$selected_scope" || die "Scope $selected_scope is disabled or not configured"

  if [[ -n "$max_items" ]]; then
    selected_wave=10
    selected_batch=10
  fi
  command=(
    backfill_external_ratings
    "${args[@]}"
    --coverage-only
    --drain
    --limit "$selected_wave"
    --batch-size "$selected_batch"
    --max-runtime-seconds 14400
    --wait-timeout-seconds 1800
    --json
  )
  if [[ -n "$max_items" ]]; then
    command+=(--max-items "$max_items")
  fi

  log_file="$(mktemp -t spine-external-ratings.XXXXXX)"
  if ! manage "${command[@]}" | tee "$log_file"; then
    append_log_summary "$log_file" "$selected_scope"
    rm -f "$log_file"
    return 1
  fi
  if [[ -n "$max_items" ]]; then
    if ! python3 - "$log_file" "$max_items" <<'PY'
import json
import sys

log_path, expected_items = sys.argv[1], int(sys.argv[2])
with open(log_path, encoding="utf-8") as stream:
    events = [json.loads(line) for line in stream]
terminal = next(
    (event for event in reversed(events) if event.get("event") in {"complete", "paused"}),
    {},
)
if terminal.get("items_requested") != expected_items:
    raise SystemExit(
        f"Canary processed {terminal.get('items_requested', 0)} Items; expected {expected_items}",
    )
PY
    then
      append_log_summary "$log_file" "$selected_scope"
      rm -f "$log_file"
      return 1
    fi
  fi
  append_log_summary "$log_file" "$selected_scope"
  rm -f "$log_file"
}

preflight
append_summary "## External Ratings Production Operation"
append_summary ""
append_summary "- Operation: \`$operation\`"
append_summary "- Scope: \`$scope\`"
append_summary "- Deployed commit: \`${deployed_sha:0:12}\`"
if [[ -f "$state_dir/campaign-$deployed_sha.json" ]]; then
  append_summary "- Campaign backup marker before run: present"
else
  append_summary "- Campaign backup marker before run: missing"
fi
if [[ "$scope" == "all" ]]; then
  append_summary "- Scope canary marker before run: not applicable"
elif [[ -f "$state_dir/canary-$deployed_sha-$scope.json" ]]; then
  append_summary "- Scope canary marker before run: present"
else
  append_summary "- Scope canary marker before run: missing"
fi

case "$operation" in
  inventory)
    append_summary ""
    append_summary '```json'
    if [[ "$scope" == "all" ]]; then
      for selected_scope in "${scopes[@]}"; do
        echo "{\"event\":\"scope\",\"scope\":\"$selected_scope\"}"
        inventory_scope "$selected_scope"
      done | tee /dev/stderr | {
        if [[ -n "$summary_file" ]]; then
          cat >> "$summary_file"
        else
          cat >/dev/null
        fi
      }
    else
      inventory_scope "$scope" | tee /dev/stderr | {
        if [[ -n "$summary_file" ]]; then
          cat >> "$summary_file"
        else
          cat >/dev/null
        fi
      }
    fi
    append_summary '```'
    ;;
  backup)
    mkdir -p "$state_dir"
    database_bytes="$("${compose[@]}" exec -T db psql -U spine -d spine -Atc "SELECT pg_database_size(current_database())")"
    available_bytes="$(df -Pk "$state_dir" | awk 'NR == 2 {printf "%.0f\n", $4 * 1024}')"
    (( available_bytes >= database_bytes * 2 )) || die "Insufficient disk space for a verified production backup"

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup="$state_dir/spine-external-ratings-$timestamp-${deployed_sha:0:12}.dump"
    partial="$backup.partial"
    trap 'rm -f "$partial"' EXIT
    "${compose[@]}" exec -T db pg_dump -U spine -d spine -Fc > "$partial"
    "${compose[@]}" exec -T db pg_restore --list < "$partial" >/dev/null
    checksum="$(shasum -a 256 "$partial" | awk '{print $1}')"
    mv "$partial" "$backup"
    campaign_marker="$state_dir/campaign-$deployed_sha.json"
    python3 - "$campaign_marker" "$backup" "$checksum" "$deployed_sha" "$timestamp" <<'PY'
import json
import sys

marker, backup, checksum, commit, created_at = sys.argv[1:]
with open(marker, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "backup": backup,
            "checksum": checksum,
            "commit": commit,
            "created_at": created_at,
            "provider_rights_confirmed": True,
        },
        stream,
        sort_keys=True,
    )
    stream.write("\n")
PY
    chmod 600 "$campaign_marker" "$backup"
    append_summary "- Backup: \`$(basename "$backup")\`"
    append_summary "- Backup verification: passed"
    ;;
  canary)
    require_campaign
    run_drain "$scope" 10
    curl --fail --silent --show-error http://127.0.0.1:8000/health/ >/dev/null
    canary_marker="$state_dir/canary-$deployed_sha-$scope.json"
    printf '{"commit":"%s","scope":"%s","status":"passed"}\n' \
      "$deployed_sha" "$scope" > "$canary_marker"
    chmod 600 "$canary_marker"
    append_summary "- Campaign backup gate: passed"
    append_summary "- Scope canary gate: passed"
    ;;
  backfill)
    require_campaign
    require_canary
    run_drain "$scope"
    curl --fail --silent --show-error http://127.0.0.1:8000/health/ >/dev/null
    append_summary "- Campaign backup gate: passed"
    append_summary "- Scope canary gate: passed"
    ;;
esac
