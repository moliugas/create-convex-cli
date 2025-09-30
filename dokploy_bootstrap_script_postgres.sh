#!/usr/bin/env bash
set -euo pipefail

# === Pretty output helpers ===
if [ -t 1 ] && [ -z "${NO_COLOR-}" ]; then
  RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m";
  RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m";
else
  RESET=""; BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN="";
fi
info()    { printf "%b\n" "${BLUE}➜${RESET} $*"; }
success() { printf "%b\n" "${GREEN}✔${RESET} $*"; }
warn()    { printf "%b\n" "${YELLOW}⚠${RESET} $*"; }
error()   { printf "%b\n" "${RED}✖${RESET} $*"; }
section() { printf "\n%b\n" "${BOLD}${MAGENTA}==>${RESET} $*"; }

# === Help ===
usage() {
  section "Usage"
  printf "%b\n" "${BOLD}./dokploy_bootstrap_script_postgres.sh${RESET} [options]"
  printf "\n"
  printf "%b\n" "Options:"
  printf "  %b\n" "-h, --help            Show this help and exit"
  printf "\n"
  section "Environment Variables"
  printf "  %b\n" "TOKEN                 Dokploy API token (x-api-key)"
  printf "  %b\n" "PROJECT_NAME          Project name (prompted if missing)"
  printf "  %b\n" "APP_NAME              App/Compose name (prompted if missing)"
  printf "  %b\n" "ENV_NAME              Environment name (default: dev)"
  printf "  %b\n" "COMPOSE_FILE          Compose file path (default: docker-compose.yaml)"
  printf "  %b\n" "CREATE_PG             y/N to create Postgres (default: N)"
  printf "  %b\n" "DEPLOY_PG_NOW         Y/n to deploy Postgres now (needed for URL)"
  printf "  %b\n" "CREATE_DASH_DOMAIN    y/N to create dashboard domain (default: N)"
  printf "  %b\n" "ENV_FILE              Extra env to merge into Compose env (default: .env)"
  printf "  %b\n" "DRY_RUN               1 to print intended requests without calling API"
  printf "  %b\n" "NO_COLOR              1 to disable colored output"
  printf "  %b\n" "S3_ENDPOINT_URL       e.g., http://minio:9000 (default)"
  printf "  %b\n" "AWS_S3_FORCE_PATH_STYLE  true/false (default: true)"
  printf "  %b\n" "AWS_REGION            Region label (default: giltine)"
  printf "\n"
  section "Examples"
  printf "  %b\n" "DRY_RUN=1 TOKEN=... PROJECT_NAME=myproj APP_NAME=myapp ./dokploy_bootstrap_script_postgres.sh"
  printf "  %b\n" "CREATE_PG=Y DEPLOY_PG_NOW=Y CREATE_DASH_DOMAIN=Y TOKEN=... ./dokploy_bootstrap_script_postgres.sh"
}

# Show help and exit
case "${1-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  *) ;;
esac

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
api() {
  if [ "${DRY_RUN-}" = "1" ]; then
    echo "curl -sfS -H '$API_HEADER_NAME: $TOKEN' -H 'Content-Type: application/json' '$DOKPLOY_URL/api/$1' -d '$2'"
  else
    curl -sfS "${auth[@]}" "$DOKPLOY_URL/api/$1" -d "$2"
  fi
}
get() {
  if [ "${DRY_RUN-}" = "1" ]; then
    echo "curl -sfS -H '$API_HEADER_NAME: $TOKEN' -H 'Content-Type: application/json' '$DOKPLOY_URL/api/$1'"
  else
    curl -sfS "${auth[@]}" "$DOKPLOY_URL/api/$1"
  fi
}

jqcheck() { command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }; }
filecheck() { [ -f "$1" ] || { echo "missing file: $1" >&2; exit 1; }; }

jqcheck

# === 1) auth sanity check ===
section "Auth Check"
info "Checking API reachability..."
get project.all >/dev/null || { echo "Auth or network failed" >&2; exit 1; }
success "API reachable"

# === Prompt for required inputs if missing ===
PROJECT_NAME="${PROJECT_NAME-}"
if [ -z "${PROJECT_NAME}" ]; then
  read -rp "Enter Project name: " PROJECT_NAME
fi

APP_NAME="${APP_NAME-}"
if [ -z "${APP_NAME}" ]; then
  read -rp "Enter Convex app name: " APP_NAME
fi

# Default environment name
ENV_NAME="${ENV_NAME:-dev}"

# Ask whether to create Postgres
CREATE_PG="${CREATE_PG-}"
if [ -z "${CREATE_PG}" ]; then
  read -rp "Create Postgres database? [y/N]: " CREATE_PG
fi
CREATE_PG=${CREATE_PG:-N}

# If creating Postgres, ask whether to deploy it now (needed to get connection string)
if [[ "$CREATE_PG" =~ ^[Yy]$ ]]; then
  DEPLOY_PG_NOW="${DEPLOY_PG_NOW-}"
  if [ -z "${DEPLOY_PG_NOW}" ]; then
    read -rp "Deploy Postgres now? [Y/n]: " DEPLOY_PG_NOW
  fi
  DEPLOY_PG_NOW=${DEPLOY_PG_NOW:-Y}
fi

# Ask whether to create a Convex dashboard domain
CREATE_DASH_DOMAIN="${CREATE_DASH_DOMAIN-}"
if [ -z "${CREATE_DASH_DOMAIN}" ]; then
  read -rp "Create Convex dashboard domain? [y/N]: " CREATE_DASH_DOMAIN
fi
CREATE_DASH_DOMAIN=${CREATE_DASH_DOMAIN:-N}

# If dashboard is not desired, try to use a dashless compose template
if [[ ! "$CREATE_DASH_DOMAIN" =~ ^[Yy]$ ]]; then
  ALT_COMPOSE="docker-compose-dashless.yaml"
  if [ -f "$ALT_COMPOSE" ]; then
    COMPOSE_FILE="$ALT_COMPOSE"
    echo "Using dashless compose file: $COMPOSE_FILE" >&2
  else
    echo "Dashless compose file '$ALT_COMPOSE' not found, using default '$COMPOSE_FILE'" >&2
  fi
fi

# === 2) create project and capture environment ===
PROJECT_CREATE_JSON="$(api project.create "$(jq -nc --arg n "$PROJECT_NAME" --arg env "$ENV_NAME" '{name:$n,description:null,env:$env}')")"
PROJECT_ID="$(jq -r '.data.project.projectId // .project.projectId // .data.projectId // .projectId' <<<"$PROJECT_CREATE_JSON")"
ENV_ID="$(jq -r '.data.environment.environmentId // .environment.environmentId // .data.environmentId // .environmentId' <<<"$PROJECT_CREATE_JSON")"
success "Project created: ${BOLD}$PROJECT_ID${RESET}"
success "Environment: ${BOLD}$ENV_ID${RESET} (${ENV_NAME})"

# Try to set environment name to the chosen default (e.g., dev)
api environment.update "$(jq -nc --arg id "$ENV_ID" --arg name "$ENV_NAME" '{environmentId:$id, name:$name}')" >/dev/null || true

# === 3) create compose service ===
filecheck "$COMPOSE_FILE"
section "Compose"
info "Creating Compose service from ${BOLD}$COMPOSE_FILE${RESET}"
COMPOSE_ID="$(api compose.create "$(jq -n \
  --arg n "$APP_NAME" \
  --arg an "$APP_NAME" \
  --arg env "$ENV_ID" \
  --rawfile cf "$COMPOSE_FILE" \
  '{name:$n, appName:$an, environmentId:$env, composeType:"docker-compose", composeFile:$cf, description:""}')" \
  | jq -r '.data.composeId // .composeId // .data.id // .id')"
success "Compose created: ${BOLD}$COMPOSE_ID${RESET}"

# Set sourceType via update (raw)
api compose.update "$(jq -nc --arg id "$COMPOSE_ID" '{composeId:$id, sourceType:"raw"}')" >/dev/null || true

# === 4) optional Postgres ===
POSTGRES_URL=""
if [[ "$CREATE_PG" =~ ^[Yy]$ ]]; then
  # defaults
  PG_NAME="${PG_NAME:-convex-db}"
  PG_DB="${PG_DB:-convex_self_hosted}"
  PG_USER="${PG_USER:-appuser}"
  if [ -z "${PG_PASS-}" ]; then
    PG_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16 || true)"
  fi

  if [ "${DRY_RUN-}" = "1" ]; then
    info "DRY_RUN: would create Postgres '${BOLD}$PG_NAME${RESET}' in environment '$ENV_ID'"
    PG_ID="pg_dryrun_$(date +%s)"
  else
    # Create Postgres (may return boolean true)
    PG_CREATE_JSON="$(api postgres.create "$(jq -n \
      --arg name "$PG_NAME" \
      --arg app "$PG_NAME" \
      --arg db "$PG_DB" \
      --arg user "$PG_USER" \
      --arg pass "$PG_PASS" \
      --arg env "$ENV_ID" \
      '{name:$name, appName:$app, databaseName:$db, databaseUser:$user, databasePassword:$pass, dockerImage:"postgres:15", environmentId:$env, description:""}')")" || { echo "Postgres create request failed" >&2; exit 1; }

    # Extract id if object-shaped
    PG_ID="$(jq -r 'if type=="object" then (.data.postgresId // .postgresId // .data.id // .id // empty) else empty end' <<<"$PG_CREATE_JSON")"

    # Fallback lookup by name in environment
    if [ -z "$PG_ID" ]; then
      for i in 1 2 3 4 5; do
        ENV_JSON="$(get "environment.one?environmentId=$ENV_ID")" || true
        PG_ID="$(jq -r --arg n "$PG_NAME" '
          (
            .data.environment.postgres // .environment.postgres //
            .data.postgres // .postgres // []
          ) as $list
          | ($list | map(select((.name==$n) or (.appName==$n))) | .[0].postgresId) // empty
        ' <<<"$ENV_JSON")"
        [ -n "$PG_ID" ] && break
        sleep 1
      done
    fi

    if [ -z "$PG_ID" ]; then
      echo "Could not determine postgresId. Server response: $PG_CREATE_JSON" >&2
      exit 1
    fi

    # Deploy now if requested; otherwise warn and skip connection string logic
    if [[ "${DEPLOY_PG_NOW:-Y}" =~ ^[Yy]$ ]]; then
      if [ "${DRY_RUN-}" = "1" ]; then
        info "DRY_RUN: would deploy Postgres '${BOLD}$PG_ID${RESET}' now to retrieve connection string."
      else
        info "Deploying Postgres to retrieve connection string (cannot get it without deploy)."
        api postgres.deploy "$(jq -nc --arg id "$PG_ID" '{postgresId:$id}')" >/dev/null
      fi
    else
      warn "Skipping Postgres deploy now; connection string will not be available until it is deployed."
    fi
  fi

  success "Postgres created: ${BOLD}$PG_ID${RESET}"

  # Fetch connection info only if we deployed now (and not in dry run)
  if [[ "${DEPLOY_PG_NOW:-Y}" =~ ^[Yy]$ ]] && [ "${DRY_RUN-}" != "1" ]; then
    PG_JSON="$(get "postgres.one?postgresId=$PG_ID")"
    RAW_URL="$(jq -r '.data.internalConnectionUrl // .internalConnectionUrl // empty' <<<"$PG_JSON")"
    if [ -z "$RAW_URL" ]; then
      HOST="$(jq -r '.data.internalHost // .internalHost // .data.appName // .appName' <<<"$PG_JSON")"
      PORT="$(jq -r '.data.internalPort // .internalPort // 5432' <<<"$PG_JSON")"
      RAW_URL="postgres://$PG_USER:$PG_PASS@$HOST:$PORT/$PG_DB"
    fi
    # Strip trailing /<dbname>
    POSTGRES_URL="${RAW_URL%/$PG_DB}"
    success "Postgres URL captured"
  fi
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

# S3 defaults (can be overridden via env)
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-http://minio:9000}"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-true}"
AWS_REGION="${AWS_REGION:-giltine}"

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

# Save env on the compose service
api compose.update "$(jq -nc --arg id "$COMPOSE_ID" --rawfile env "$APP_ENV_TMP" '{composeId:$id, env:$env}')" >/dev/null
rm -f "$APP_ENV_TMP"

# === 8) domains (printed + best-effort create; endpoint may vary) ===
A_DOMAIN="api-${PROJECT_NAME}.convex.giltine.com"
ACT_DOMAIN="actions-${PROJECT_NAME}.convex.giltine.com"
DASH_DOMAIN="dashboard-${PROJECT_NAME}.convex.giltine.com"
section "Domains"
info "Configuring: $A_DOMAIN:3210 (service: backend), $ACT_DOMAIN:3211 (service: backend)"
# Create API domain -> port 3210 with Let's Encrypt
api domain.create "$(jq -nc --arg cid "$COMPOSE_ID" --arg h "$A_DOMAIN" --arg ct "letsencrypt" --arg svc "backend" --argjson p 3210 --argjson https true '{composeId:$cid, host:$h, serviceName:$svc, port:$p, https:$https, certificateType:$ct, domainType:"compose"}')" >/dev/null || true
# Create Actions domain -> port 3211 with Let's Encrypt
api domain.create "$(jq -nc --arg cid "$COMPOSE_ID" --arg h "$ACT_DOMAIN" --arg ct "letsencrypt" --arg svc "backend" --argjson p 3211 --argjson https true '{composeId:$cid, host:$h, serviceName:$svc, port:$p, https:$https, certificateType:$ct, domainType:"compose"}')" >/dev/null || true
if [[ "$CREATE_DASH_DOMAIN" =~ ^[Yy]$ ]]; then
  info "Also creating dashboard domain: $DASH_DOMAIN:6791 (service: dashboard)"
  api domain.create "$(jq -nc --arg cid "$COMPOSE_ID" --arg h "$DASH_DOMAIN" --arg ct "letsencrypt" --arg svc "dashboard" --argjson p 6791 --argjson https true '{composeId:$cid, host:$h, serviceName:$svc, port:$p, https:$https, certificateType:$ct, domainType:"compose"}')" >/dev/null || true
fi

# === 9) deploy app (prompt user) ===
DEPLOY="${DEPLOY-}"
if [ -z "${DEPLOY}" ]; then
  read -rp "Redeploy application now? [Y/n]: " DEPLOY
fi
DEPLOY=${DEPLOY:-Y}

section "Deploy"
if [[ "$DEPLOY" =~ ^[Yy]$ ]]; then
  api compose.redeploy "$(jq -nc --arg id "$COMPOSE_ID" '{composeId:$id}')" >/dev/null
  success "Compose deployment triggered"
else
  warn "Skipping deployment"
fi

section "Summary"
printf "%b\n" "Project:        ${BOLD}$PROJECT_ID${RESET}"
printf "%b\n" "Environment:    ${BOLD}$ENV_ID${RESET} (${ENV_NAME})"
printf "%b\n" "Compose:        ${BOLD}$COMPOSE_ID${RESET}"
if [[ "${CREATE_PG:-N}" =~ ^[Yy]$ ]]; then
  printf "%b\n" "Postgres:       ${BOLD}${PG_ID-}${RESET}"
  if [ -n "${POSTGRES_URL-}" ]; then printf "%b\n" "Postgres URL:   ${BOLD}${POSTGRES_URL}${RESET}"; fi
fi
success "Done."
