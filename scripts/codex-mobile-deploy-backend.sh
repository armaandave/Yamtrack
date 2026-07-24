#!/usr/bin/env bash
set -euo pipefail

branch="${1:-}"
source_repo_dir="${SPINE_SOURCE_REPO_DIR:-$HOME/projects/spine}"
repo_dir="${SPINE_DEPLOY_DIR:-$HOME/projects/spine-deploy}"
env_file="${SPINE_DEPLOY_ENV_FILE:-$source_repo_dir/.env.production}"
repo_url="${SPINE_DEPLOY_REPO_URL:-}"

if [[ -z "$branch" ]]; then
  echo "Usage: $0 <branch>" >&2
  exit 2
fi

if [[ "$branch" == -* ]] || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  echo "Invalid branch: $branch" >&2
  exit 2
fi

if [[ ! -f "$env_file" ]]; then
  echo "Missing production env file: $env_file" >&2
  exit 1
fi

if ! grep -q '^STEAMGRIDDB_API_KEY=' "$env_file"; then
  echo "Missing STEAMGRIDDB_API_KEY in production env file: $env_file" >&2
  exit 1
fi

if ! grep -Eq '^NYT_BOOKS_API_KEY=.+$' "$env_file"; then
  echo "Missing or empty NYT_BOOKS_API_KEY in production env file: $env_file" >&2
  exit 1
fi

if [[ -z "$repo_url" ]]; then
  if [[ -d "$source_repo_dir/.git" ]]; then
    repo_url="$(git -C "$source_repo_dir" remote get-url origin)"
  else
    repo_url="https://github.com/armaandave/spine.git"
  fi
fi

source_repo_abs=""
if [[ -d "$source_repo_dir" ]]; then
  source_repo_abs="$(cd "$source_repo_dir" && pwd -P)"
fi
repo_parent="$(dirname "$repo_dir")"
repo_abs="$(mkdir -p "$repo_parent" && cd "$repo_parent" && pwd -P)/$(basename "$repo_dir")"
if [[ -n "$source_repo_abs" && "$repo_abs" == "$source_repo_abs" ]]; then
  echo "Deploy directory must be separate from source repo: $repo_dir" >&2
  exit 1
fi

if [[ -e "$repo_dir" && ! -d "$repo_dir/.git" ]]; then
  echo "Deploy directory exists but is not a Git repo: $repo_dir" >&2
  exit 1
fi

if [[ ! -d "$repo_dir/.git" ]]; then
  mkdir -p "$(dirname "$repo_dir")"
  git clone "$repo_url" "$repo_dir"
fi

cd "$repo_dir"

git remote set-url origin "$repo_url"
git fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch"
git checkout -B "$branch" "origin/$branch"
git reset --hard "origin/$branch"
echo "Deploying $branch at $(git rev-parse --short HEAD) from $repo_dir"
export SPINE_COMMIT_SHA
SPINE_COMMIT_SHA="$(git rev-parse HEAD)"

if [[ ! -e .env.production && ! -L .env.production ]]; then
  ln -s "$env_file" .env.production
fi

docker compose --project-name spine --env-file "$env_file" -f docker-compose.production.yml up -d --build
docker compose --project-name spine --env-file "$env_file" -f docker-compose.production.yml exec app python manage.py shell -c "from django.core.cache import cache; cache.clear()"

sync_queued=false
for attempt in 1 2 3; do
  if docker compose --project-name spine --env-file "$env_file" -f docker-compose.production.yml exec app \
    python manage.py shell -c \
    "from lists.tasks import sync_nyt_featured_lists; print(sync_nyt_featured_lists.delay().id)"; then
    sync_queued=true
    break
  fi
  echo "NYT featured-list enqueue attempt $attempt failed; retrying..." >&2
  sleep 5
done

if [[ "$sync_queued" != "true" ]]; then
  echo "Could not enqueue the initial NYT featured-list synchronization." >&2
  exit 1
fi
