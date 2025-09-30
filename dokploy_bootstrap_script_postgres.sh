#!/usr/bin/env bash
set -euo pipefail

# === Fixed config ===
DOKPLOY_URL="http://88.119.165.37:3000"   # always this
API_HEADER_NAME="x-api-key"               # Dokploy expects this header
ENV_FILE="${ENV_FILE:-.env}"             # your local .env
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yaml}"

# === Prompt for token missing ===
TOKEN="${TOKEN-}"
if [ -z "${TOKEN}" ]; then
  read -rsp "Enter Dokploy API token: " TOKEN; echo
fi

# === Helpers ===
auth=(-H "$API_HEADER_NAME: $TOKEN" -H "Content-Type: application/json")
api() { curl -sfS "${auth[@]}" "$DOKPLOY_URL/api/$1" -d "$2"; }
get() { curl -sfS "${auth[@]}" "$DOKPLOY_URL/api/$1"; }

jqcheck() { command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }; }
filecheck() { [ -f "$1" ] || { echo "missing file: $1" >&2; exit 1; }; }

jqcheck

# === 1) auth sanity check ===
echo "Checking API reachability..." >&2
get project.all >/dev/null || { echo "Auth or network failed" >&2; exit 1; }
echo "OK" >&2

# === Prompt for required inputs if missing ===
PROJECT_NAME="${PROJECT_NAME-}"
if [ -z "${PROJECT_NAME}" ]; then
  read -rp "Enter Project name: " PROJECT_NAME
fi

APP_NAME="${APP_NAME-}"
if [ -z "${APP_NAME}" ]; then
  read -rp "Enter Convex app name: " APP_NAME
fi

# Ask whether to create Postgres
CREATE_PG="${CREATE_PG-}"
if [ -z "${CREATE_PG}" ]; then
  read -rp "Create Postgres database? [y/N]: " CREATE_PG
fi
CREATE_PG=${CREATE_PG:-N}

# === 2) create project ===
PROJECT_ID="$(api project.create "$(jq -nc --arg n "$PROJECT_NAME" '{name:$n,description:null}')" | jq -r '.data.id // .id')"
echo "projectId=$PROJECT_ID"

# === 3) create app ===
APP_ID="$(api application.create "$(jq -nc --arg n "$APP_NAME" --arg pid "$PROJECT_ID" '{name:$n, appName:$n, projectId:$pid, serverId:null, description:null}')" | jq -r '.data.id // .id')"
echo "applicationId=$APP_ID"

# Set build to Docker Compose or Dockerfile depending on presence of compose file
if [ -f "$COMPOSE_FILE" ]; then
  echo "Uploading docker-compose.yaml" >&2
  COMPOSE_CONTENT=$(jq -Rs . < "$COMPOSE_FILE")
  # NOTE: endpoint name may vary by Dokploy version. Using application.saveComposeContent.
  api application.saveComposeContent "$(jq -nc --arg id "$APP_ID" --arg content "$(cat "$COMPOSE_FILE")" '{applicationId:$id, composeContent:$content}')" >/dev/null || {
    echo "compose upload endpoint not supported; skipping compose upload" >&2
  }
  # Switch build type to compose if supported
  api application.saveBuildType "$(jq -nc --arg id "$APP_ID" '{applicationId:$id, buildType:"compose"}')" >/dev/null || true
else
  echo "No $COMPOSE_FILE. Using Dockerfile build." >&2
  api application.saveBuildType "$(jq -nc --arg id "$APP_ID" '{applicationId:$id, buildType:"dockerfile", dockerfile:"Dockerfile", dockerContextPath:"/"}')" >/dev/null || true
fi

# === 4) optional Postgres ===
POSTGRES_URL=""
if [[ "$CREATE_PG" =~ ^[Yy]$ ]]; then
  PG_NAME="convex_self_hosted"
  PG_DB="convex_self_hosted"
  PG_USER="${PG_USER:-appuser}"
  if [ -z "${PG_PASS-}" ]; then
    read -rsp "Enter Postgres password: " PG_PASS; echo
  fi

  PG_ID="$(api postgres.create "$(jq -nc --arg name "$PG_NAME" --arg app "$PG_NAME" --arg db "$PG_DB" --arg user "$PG_USER" --arg pass "$PG_PASS" --arg pid "$PROJECT_ID" '{name:$name, appName:$app, databaseName:$db, databaseUser:$user, databasePassword:$pass, dockerImage:"postgres:15", projectId:$pid, description:null, serverId:null}')" | jq -r '.data.id // .id')"
  api postgres.deploy "$(jq -nc --arg id "$PG_ID" '{postgresId:$id}')" >/dev/null

  PG_JSON="$(get "postgres.one?postgresId=$PG_ID")"
  RAW_URL="$(jq -r '.data.internalConnectionUrl // .internalConnectionUrl // empty' <<<"$PG_JSON")"
  if [ -z "$RAW_URL" ]; then
    HOST="$(jq -r '.data.internalHost // .internalHost // .data.appName // .appName' <<<"$PG_JSON")"
    PORT="$(jq -r '.data.internalPort // .internalPort // 5432' <<<"$PG_JSON")"
    RAW_URL="postgres://$PG_USER:$PG_PASS@$HOST:$PORT/$PG_DB"
  fi
  # Strip trailing /<dbname>
  POSTGRES_URL="${RAW_URL%/$PG_DB}"
  echo "postgresId=$PG_ID"
  echo "POSTGRES_URL=$POSTGRES_URL"
fi

# === 5) derived URLs based on project name ===
NEXT_PUBLIC_DEPLOYMENT_URL="https://api-${PROJECT_NAME}.convex.giltine.com"
CONVEX_CLOUD_ORIGIN="$NEXT_PUBLIC_DEPLOYMENT_URL"
CONVEX_SITE_ORIGIN="https://actions-${PROJECT_NAME}.convex.giltine.com"

# === 6) S3 bucket names ===
S3_STORAGE_EXPORTS_BUCKET="convex-snapshot-exports-${PROJECT_NAME}"
S3_STORAGE_SNAPSHOT_IMPORTS_BUCKET="convex-snapshot-imports-${PROJECT_NAME}"
S3_STORAGE_MODULES_BUCKET="convex-modules-${PROJECT_NAME}"
S3_STORAGE_FILES_BUCKET="convex-user-files-${PROJECT_NAME}"
S3_STORAGE_SEARCH_BUCKET="convex-search-indexes-${PROJECT_NAME}"

# static envs
S3_ENDPOINT_URL="http://minio:9000"
AWS_S3_FORCE_PATH_STYLE=true
AWS_REGION="giltine"

# === 7) assemble env and push ===
APP_ENV_TMP=$(mktemp)
[ -f "$ENV_FILE" ] && cat "$ENV_FILE" > "$APP_ENV_TMP" || true
{
  echo "NEXT_PUBLIC_DEPLOYMENT_URL=$NEXT_PUBLIC_DEPLOYMENT_URL"
  echo "CONVEX_CLOUD_ORIGIN=$CONVEX_CLOUD_ORIGIN"
  echo "CONVEX_SITE_ORIGIN=$CONVEX_SITE_ORIGIN"
  echo "S3_ENDPOINT_URL=$S3_ENDPOINT_URL"
  echo "AWS_S3_FORCE_PATH_STYLE=$AWS_S3_FORCE_PATH_STYLE"
  echo "AWS_REGION=$AWS_REGION"
  echo "S3_STORAGE_EXPORTS_BUCKET=$S3_STORAGE_EXPORTS_BUCKET"
  echo "S3_STORAGE_SNAPSHOT_IMPORTS_BUCKET=$S3_STORAGE_SNAPSHOT_IMPORTS_BUCKET"
  echo "S3_STORAGE_MODULES_BUCKET=$S3_STORAGE_MODULES_BUCKET"
  echo "S3_STORAGE_FILES_BUCKET=$S3_STORAGE_FILES_BUCKET"
  echo "S3_STORAGE_SEARCH_BUCKET=$S3_STORAGE_SEARCH_BUCKET"
  if [ -n "$POSTGRES_URL" ]; then echo "POSTGRES_URL=$POSTGRES_URL"; fi
} >> "$APP_ENV_TMP"

api application.saveEnvironment "$(jq -nc --arg id "$APP_ID" --rawfile env "$APP_ENV_TMP" '{applicationId:$id, env:$env, buildArgs:null}')" >/dev/null
rm -f "$APP_ENV_TMP"

# === 8) domains (printed + best-effort create; endpoint may vary) ===
A_DOMAIN="api-${PROJECT_NAME}.convex.giltine.com"
ACT_DOMAIN="actions-${PROJECT_NAME}.convex.giltine.com"
echo "Domains to create in Dokploy: $A_DOMAIN, $ACT_DOMAIN" >&2
# Attempt generic domain creation if supported (may vary by version)
api domain.create "$(jq -nc --arg pid "$PROJECT_ID" --arg aid "$APP_ID" --arg d "$A_DOMAIN" '{projectId:$pid, applicationId:$aid, domain:$d}')" >/dev/null || true
api domain.create "$(jq -nc --arg pid "$PROJECT_ID" --arg aid "$APP_ID" --arg d "$ACT_DOMAIN" '{projectId:$pid, applicationId:$aid, domain:$d}')" >/dev/null || true

# === 9) deploy app (prompt user) ===
DEPLOY="${DEPLOY-}"
if [ -z "${DEPLOY}" ]; then
  read -rp "Redeploy application now? [Y/n]: " DEPLOY
fi
DEPLOY=${DEPLOY:-Y}

if [[ "$DEPLOY" =~ ^[Yy]$ ]]; then
  api application.redeploy "$(jq -nc --arg id "$APP_ID" '{applicationId:$id}')" >/dev/null
  echo "Deployment triggered."
else
  echo "Skipping deployment."
fi

echo "Done."
