#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------------
# Setup script for OPEN-DATASPACES-L3 APP (Helm/Kubernetes variant)
# This script follows the same setup flow as SDK-docker-compose/setup/setup_l3.sh,
# but resolves settings from charts/l3/values.yaml and Kubernetes resources.
# -------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
L3_VALUES_FILE="${L3_VALUES_FILE:-$PROJECT_ROOT/charts/l3/values.yaml}"
KEYCLOAK_JSON_DIR="$SCRIPT_DIR/keycloak/json"
OPENFGA_JSON_DIR="$SCRIPT_DIR/openfga"
SQL_DIR="$SCRIPT_DIR/sql"
TMP_DIR="$SCRIPT_DIR/tmp"
LOG_DIR="$SCRIPT_DIR/logs"

DEFAULT_NS="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
NAMESPACE="${NAMESPACE:-${DEFAULT_NS:-default}}"
RELEASE_NAME="${RELEASE_NAME:-}"
KEYCLOAK_SERVICE="${KEYCLOAK_SERVICE:-}"
OPENFGA_SERVICE="${OPENFGA_SERVICE:-}"

KEYCLOAK_HTTP_PORT="${KEYCLOAK_HTTP_PORT:-}"
OPENFGA_API_PORT="${OPENFGA_API_PORT:-}"
KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-}"
OPENFGA_BASE_URL="${OPENFGA_BASE_URL:-}"
ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD:-true}"

KEYCLOAK_REALM="${KEYCLOAK_REALM:-}"
KEYCLOAK_MASTER_REALM="${KEYCLOAK_MASTER_REALM:-}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-}"
KEYCLOAK_USERNAME="${KEYCLOAK_USERNAME:-}"
KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-}"
KEYCLOAK_CLIENT_ID_API_ADMIN="${KEYCLOAK_CLIENT_ID_API_ADMIN:-}"
KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN="${KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN:-open_system_id_sample}"

KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-}"
OPENFGA_DB_PASSWORD="${OPENFGA_DB_PASSWORD:-}"
POSTGRES_HOST="${POSTGRES_HOST:-}"
POSTGRES_PORT="${POSTGRES_PORT:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

L3TBL_API_KEY="${L3TBL_API_KEY:-API-Key-Sample}"
L3TBL_API_KEYS_ID="${L3TBL_API_KEYS_ID:-API-Key-UUID-Sample}"
L3TBL_API_KEYS_NAME="${L3TBL_API_KEYS_NAME:-API-Key-Name-Sample}"
L3TBL_API_KEYS_USECASE="${L3TBL_API_KEYS_USECASE:-tutorials-usecase}"
L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME="${L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME:-}"
L3TBL_CIDRS_CIDR="${L3TBL_CIDRS_CIDR:-0.0.0.0/0}"

LOG_TS="$(date +"%Y%m%d-%H%M%S")"
mkdir -p "$LOG_DIR" "$TMP_DIR"
LOG_FILE="$LOG_DIR/setup-$LOG_TS.log"

exec > >(tee -a "$LOG_FILE") 2>&1

OPENFGA_PF_PID=""
KEYCLOAK_PF_PID=""
OPENFGA_POD=""
POSTGRES_POD=""
API_AUTHZ_STORE_ID=""
REALM_AUTHZ_STORE_ID=""
OPERATOR_PLANT_AUTHZ_STORE_ID=""
REALM_UUID=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: '$1' command not found" >&2
    exit 1
  }
}

strip_quotes() {
  printf '%s' "$1" \
    | sed -e $'1s/^\uFEFF//' \
          -e 's/^[[:space:]]*//' \
          -e 's/[[:space:]]*$//' \
          -e 's/[[:space:]]#.*$//' \
          -e 's/^"//' \
          -e 's/"$//' \
          -e "s/^'//" \
          -e "s/'$//"
}

read_yaml_value() {
  local path="$1"
  local file="$2"
  local raw_value

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  raw_value="$(
    awk -v path="$path" '
      function trim(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
      }

      BEGIN {
        depth_max = split(path, want, /\./)
      }

      {
        line = $0
        sub(/\r$/, "", line)
        if (NR == 1) {
          sub(/^\xef\xbb\xbf/, "", line)
        }
        if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) {
          next
        }

        indent = match(line, /[^ ]/) - 1
        if (indent < 0) {
          next
        }

        content = substr(line, indent + 1)
        if (content ~ /^-/) {
          next
        }

        key = content
        sub(/:.*/, "", key)
        key = trim(key)

        value = content
        sub(/^[^:]*:[[:space:]]*/, "", value)
        value = trim(value)

        depth = int(indent / 2) + 1
        keys[depth] = key
        for (i = depth + 1; i <= 32; i++) {
          delete keys[i]
        }

        if (depth != depth_max) {
          next
        }

        ok = 1
        for (i = 1; i <= depth_max; i++) {
          if (keys[i] != want[i]) {
            ok = 0
          }
        }
        if (ok) {
          print value
          exit
        }
      }
    ' "$file"
  )"

  strip_quotes "$raw_value"
}

finish_error() {
  rollback_store "$API_AUTHZ_STORE_ID"
  rollback_store "$REALM_AUTHZ_STORE_ID"
  rollback_store "$OPERATOR_PLANT_AUTHZ_STORE_ID"
  echo "-------------------------------------------------------------------------"
  echo "ErrorCode: $1, Message: $2"
  exit "$1"
}

check_path() {
  local path="$1"
  local description="$2"
  echo "Checking $description at path: $path"
  if [[ -z "$path" ]]; then
    finish_error 2 "$description not provided."
  fi
  if [[ ! -e "$path" ]]; then
    finish_error 3 "$description '$path' does not exist."
  fi
}

rollback_store() {
  local store_id="$1"
  local http_code=""

  if [[ -n "$store_id" ]] && [[ -n "$OPENFGA_BASE_URL" ]]; then
    echo "Deleting OpenFGA store with ID: $store_id"
    http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
      "$OPENFGA_BASE_URL/stores/$store_id" \
      -H "Content-Type: application/json" || true)"
    if [[ "$http_code" != "204" ]]; then
      echo "Failed to delete OpenFGA store with ID $store_id (HTTP $http_code)."
    else
      echo "OpenFGA store with ID $store_id deleted successfully."
    fi
  fi
}

create_json_keycloak_userprofile() {
  local upcfg_file="$KEYCLOAK_JSON_DIR/user-profile-config.json"
  local up_one_line
  local up_escaped

  rm -f "$TMP_DIR/component_payload.json"
  up_one_line="$(tr -d '\r\n' < "$upcfg_file")"
  up_escaped="$(printf '%s' "$up_one_line" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  cat > "$TMP_DIR/component_payload.json" <<JSON
{
  "name": "user-profile",
  "parentId": "${REALM_UUID}",
  "providerId": "declarative-user-profile",
  "providerType": "org.keycloak.userprofile.UserProfileProvider",
  "config": {
    "kc.user.profile.config": ["${up_escaped}"]
  }
}
JSON

  [[ -f "$TMP_DIR/component_payload.json" ]]
}

create_json_keycloak_password_policy() {
  local password_policy_min_len=8
  local password_policy_max_len=20
  local password_policy_regex='^(?=.*[A-Z])(?=.*[a-z])(?=.*[0-9])(?=.*[!@#\\$%\\^&\\*\\(\\)])[A-Za-z0-9!@#\\$%\\^&\\*\\(\\)]+$'
  local password_policy_regex_escaped
  local policy_string

  rm -f "$TMP_DIR/realm_password_policy.json"
  password_policy_regex_escaped="$(printf '%s' "$password_policy_regex" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  policy_string="length(${password_policy_min_len}) and maxLength(${password_policy_max_len}) and regexPattern(${password_policy_regex_escaped})"

  jq --arg policy "$policy_string" '.passwordPolicy = $policy' "$TMP_DIR/realm.json" > "$TMP_DIR/realm_password_policy.json"
}

detect_release_name() {
  kubectl -n "$NAMESPACE" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | sed -n 's/\(.*\)-l3-openfga$/\1/p' \
    | head -n1
}

resolve_first_pod_name() {
  local label="$1"
  kubectl -n "$NAMESPACE" get pods -l "app=${label}" -o jsonpath='{.items[0].metadata.name}'
}

update_values_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped_value

  if ! grep -q "^[[:space:]]*${key}:" "$file"; then
    finish_error 32 "Failed to update ${key} in ${file}; key was not found."
  fi

  escaped_value="$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g' -e 's/"/\\"/g')"
  sed -i "s|^\([[:space:]]*${key}:[[:space:]]*\).*|\1\"${escaped_value}\"|" "$file"
}

load_chart_defaults() {
  if [[ -z "${KEYCLOAK_HTTP_PORT}" ]]; then
    KEYCLOAK_HTTP_PORT="$(read_yaml_value "keycloak.service.httpPort" "${L3_VALUES_FILE}" || true)"
  fi
  if [[ -z "${OPENFGA_API_PORT}" ]]; then
    OPENFGA_API_PORT="$(read_yaml_value "openfga.service.apiPort" "${L3_VALUES_FILE}" || true)"
  fi
  if [[ -z "${KEYCLOAK_PASSWORD}" ]]; then
    KEYCLOAK_PASSWORD="$(read_yaml_value "secrets.keycloakAdminPassword" "${L3_VALUES_FILE}" || true)"
  fi
  if [[ -z "${KEYCLOAK_DB_PASSWORD}" ]]; then
    KEYCLOAK_DB_PASSWORD="$(read_yaml_value "secrets.keycloakDbPassword" "${L3_VALUES_FILE}" || true)"
  fi
  if [[ -z "${OPENFGA_DB_PASSWORD}" ]]; then
    OPENFGA_DB_PASSWORD="$(read_yaml_value "secrets.openfgaDbPassword" "${L3_VALUES_FILE}" || true)"
  fi
  if [[ -z "${KEYCLOAK_CLIENT_ID_API_ADMIN}" ]]; then
    KEYCLOAK_CLIENT_ID_API_ADMIN="$(read_yaml_value "l3App.keycloakIntrospectClientId" "${L3_VALUES_FILE}" || true)"
  fi

  KEYCLOAK_HTTP_PORT="${KEYCLOAK_HTTP_PORT:-8082}"
  OPENFGA_API_PORT="${OPENFGA_API_PORT:-8083}"
  KEYCLOAK_REALM="${KEYCLOAK_REALM:-master}"
  KEYCLOAK_MASTER_REALM="${KEYCLOAK_MASTER_REALM:-master}"
  KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-admin-cli}"
  KEYCLOAK_USERNAME="${KEYCLOAK_USERNAME:-admin}"
  KEYCLOAK_PASSWORD="${KEYCLOAK_PASSWORD:-password}"
  KEYCLOAK_CLIENT_ID_API_ADMIN="${KEYCLOAK_CLIENT_ID_API_ADMIN:-system-auth-sample}"
  KEYCLOAK_DB_PASSWORD="${KEYCLOAK_DB_PASSWORD:-password}"
  APP_DB_PASSWORD="${APP_DB_PASSWORD:-$KEYCLOAK_DB_PASSWORD}"
  OPENFGA_DB_PASSWORD="${OPENFGA_DB_PASSWORD:-password}"
  POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
  POSTGRES_PORT="${POSTGRES_PORT:-5432}"
  POSTGRES_DB="${POSTGRES_DB:-db_ods}"
  POSTGRES_USER="${POSTGRES_USER:-app_ods}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$APP_DB_PASSWORD}"
  L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME="${L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME:-local}"

  if [[ -z "${KEYCLOAK_BASE_URL}" ]]; then
    KEYCLOAK_BASE_URL="http://127.0.0.1:${KEYCLOAK_HTTP_PORT}"
  fi
  if [[ -z "${OPENFGA_BASE_URL}" ]]; then
    OPENFGA_BASE_URL="http://127.0.0.1:${OPENFGA_API_PORT}"
  fi
}

resolve_targets() {
  if [[ -z "$RELEASE_NAME" ]]; then
    RELEASE_NAME="$(detect_release_name || true)"
  fi
  if [[ -z "$RELEASE_NAME" ]]; then
    finish_error 4 "RELEASE_NAME could not be auto-detected in namespace '$NAMESPACE'. Please set RELEASE_NAME explicitly."
  fi

  if [[ -z "$KEYCLOAK_SERVICE" ]]; then
    KEYCLOAK_SERVICE="${RELEASE_NAME}-l3-keycloak"
  fi
  if [[ -z "$OPENFGA_SERVICE" ]]; then
    OPENFGA_SERVICE="${RELEASE_NAME}-l3-openfga"
  fi

  kubectl -n "$NAMESPACE" get svc "$KEYCLOAK_SERVICE" >/dev/null
  kubectl -n "$NAMESPACE" get svc "$OPENFGA_SERVICE" >/dev/null

  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "app=${RELEASE_NAME}-l3-keycloak" --timeout=180s >/dev/null
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "app=${RELEASE_NAME}-l3-openfga" --timeout=180s >/dev/null
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "app=${RELEASE_NAME}-l3-postgres" --timeout=180s >/dev/null

  OPENFGA_POD="$(resolve_first_pod_name "${RELEASE_NAME}-l3-openfga")"
  POSTGRES_POD="$(resolve_first_pod_name "${RELEASE_NAME}-l3-postgres")"
  if [[ -z "$OPENFGA_POD" ]]; then
    finish_error 30 "Failed to resolve OpenFGA pod."
  fi
  if [[ -z "$POSTGRES_POD" ]]; then
    finish_error 31 "Failed to resolve PostgreSQL pod."
  fi
}

wait_for_url() {
  local url="$1"
  local retries="${2:-60}"
  local sleep_sec="${3:-2}"
  local i

  for ((i = 1; i <= retries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_sec"
  done

  finish_error 4 "Timeout waiting for ${url}."
}

cleanup() {
  if [[ -n "${OPENFGA_PF_PID}" ]] && kill -0 "${OPENFGA_PF_PID}" >/dev/null 2>&1; then
    kill "${OPENFGA_PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${KEYCLOAK_PF_PID}" ]] && kill -0 "${KEYCLOAK_PF_PID}" >/dev/null 2>&1; then
    kill "${KEYCLOAK_PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_port_forward() {
  local service="$1"
  local port="$2"
  local log_file="$3"
  local pid_var="$4"
  local pf_pid=""

  kubectl -n "${NAMESPACE}" port-forward "svc/${service}" "${port}:${port}" >"${log_file}" 2>&1 &
  pf_pid=$!
  sleep 1
  if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
    cat "${log_file}" >&2 || true
    finish_error 4 "Failed to start port-forward for ${service}:${port}."
  fi

  printf -v "${pid_var}" '%s' "${pf_pid}"
}

require_cmd kubectl
require_cmd curl
require_cmd jq
require_cmd sed
require_cmd awk
require_cmd tee
require_cmd envsubst

echo "Starting setup script for OPEN-DATASPACES-L3 APP..."

cd "$PROJECT_ROOT" || exit 1

load_chart_defaults

echo "Start: 1-1. Checking required files..."
check_path "$L3_VALUES_FILE" "<path_to_l3_values_file>"
check_path "$KEYCLOAK_JSON_DIR/user-profile-config.json" "<path_to_keycloak_user_profile_config_json>"
check_path "$OPENFGA_JSON_DIR/01-create-store-api-authz.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/02-create-model-api-authz.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/03-create-tuples-api-authz-role.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/04-create-tuples-api-authz-userid.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/11-create-store-realm-store-binding.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/12-create-model-realm-store-binding.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/21-create-store-operator-plant.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/22-create-model-operator-plant.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/23-create-tuples-operator-plant.json" "<path_to_setup_openfga_json_files>"
check_path "$OPENFGA_JSON_DIR/24-create-tuples-operator-plant-admin.json" "<path_to_setup_openfga_json_files>"
check_path "$SQL_DIR/1_create_app_user.sql" "<path_to_setup_database_sql>"
check_path "$SQL_DIR/2_create_app_db.sql" "<path_to_setup_database_sql>"
check_path "$SQL_DIR/3_setup_app_db.sql" "<path_to_setup_database_sql>"
check_path "$SQL_DIR/4_setup_app_table.sql" "<path_to_setup_database_sql>"
echo "Finish: 1-1. Required files are present."

echo "Start: 1-2. Loading environment variables from charts/l3/values.yaml..."
resolve_targets
echo "Namespace: $NAMESPACE"
echo "Release: $RELEASE_NAME"
echo "Keycloak service: $KEYCLOAK_SERVICE"
echo "OpenFGA service: $OPENFGA_SERVICE"
echo "Keycloak base URL: $KEYCLOAK_BASE_URL"
echo "OpenFGA base URL: $OPENFGA_BASE_URL"
echo "Finish: 1-2. Environment variables loaded from Helm chart values."

echo "Start: 1-3. Checking required environment variables..."
REQUIRED_VARS=(
  KEYCLOAK_BASE_URL
  KEYCLOAK_REALM
  KEYCLOAK_MASTER_REALM
  KEYCLOAK_CLIENT_ID
  KEYCLOAK_USERNAME
  KEYCLOAK_PASSWORD
  KEYCLOAK_CLIENT_ID_API_ADMIN
  KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN
  OPENFGA_BASE_URL
  POSTGRES_HOST
  POSTGRES_PORT
  POSTGRES_DB
  POSTGRES_USER
  POSTGRES_PASSWORD
  L3TBL_API_KEY
  L3TBL_API_KEYS_ID
  L3TBL_API_KEYS_NAME
  L3TBL_API_KEYS_USECASE
  L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME
  L3TBL_CIDRS_CIDR
)
for var in "${REQUIRED_VARS[@]}"; do
  echo "Checking environment variable: $var, value: ${!var}"
  if [[ -z "${!var}" ]]; then
    finish_error 4 "Environment variable '$var' is not set. Please check charts/l3/values.yaml or your shell overrides."
  fi
done
echo "Finish: 1-3. Required environment variables are set."

echo "Start: 1-4. Checking if 'psql' command is available..."
if ! kubectl -n "$NAMESPACE" exec "$POSTGRES_POD" -- sh -lc 'command -v psql >/dev/null 2>&1'; then
  finish_error 5 "'psql' command not found. Please ensure PostgreSQL client is available in the postgres pod."
fi
echo "Finish: 1-4. 'psql' command is available."

if [[ "${ENABLE_PORT_FORWARD}" == "true" ]]; then
  echo "Starting port-forward for OpenFGA (${OPENFGA_SERVICE}:${OPENFGA_API_PORT})"
  start_port_forward "${OPENFGA_SERVICE}" "${OPENFGA_API_PORT}" "${TMP_DIR}/openfga-port-forward.log" OPENFGA_PF_PID

  echo "Starting port-forward for Keycloak (${KEYCLOAK_SERVICE}:${KEYCLOAK_HTTP_PORT})"
  start_port_forward "${KEYCLOAK_SERVICE}" "${KEYCLOAK_HTTP_PORT}" "${TMP_DIR}/keycloak-port-forward.log" KEYCLOAK_PF_PID
fi

# 0. Initialize local resources
echo "Start: 0-1. Running OpenFGA migration..."
kubectl -n "${NAMESPACE}" exec "${OPENFGA_POD}" -- \
  /proc/1/exe migrate \
  --datastore-engine postgres \
  --datastore-uri "postgres://openfga:${OPENFGA_DB_PASSWORD}@${RELEASE_NAME}-l3-postgres-openfga:5432/openfga?sslmode=disable"
if [[ $? -ne 0 ]]; then
  finish_error 30 "Failed to run OpenFGA migration."
fi
echo "Finish: 0-1. OpenFGA migration completed."

echo "Start: 0-2. Initializing application database in PostgreSQL pod..."
kubectl -n "${NAMESPACE}" cp "$SQL_DIR/1_create_app_user.sql" "${POSTGRES_POD}:/tmp/1_create_app_user.sql"
kubectl -n "${NAMESPACE}" cp "$SQL_DIR/2_create_app_db.sql" "${POSTGRES_POD}:/tmp/2_create_app_db.sql"
kubectl -n "${NAMESPACE}" cp "$SQL_DIR/3_setup_app_db.sql" "${POSTGRES_POD}:/tmp/3_setup_app_db.sql"

kubectl -n "${NAMESPACE}" exec "${POSTGRES_POD}" -- \
  env PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" \
  psql -X -P pager=off -U keycloak -d keycloak -q -f /tmp/1_create_app_user.sql -v "user_password=${APP_DB_PASSWORD}"
if [[ $? -ne 0 ]]; then
  finish_error 31 "Failed to execute 1_create_app_user.sql in PostgreSQL pod."
fi

kubectl -n "${NAMESPACE}" exec "${POSTGRES_POD}" -- \
  env PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" \
  psql -X -P pager=off -U keycloak -d keycloak -q -f /tmp/2_create_app_db.sql
if [[ $? -ne 0 ]]; then
  finish_error 31 "Failed to execute 2_create_app_db.sql in PostgreSQL pod."
fi

kubectl -n "${NAMESPACE}" exec "${POSTGRES_POD}" -- \
  env PGPASSWORD="${APP_DB_PASSWORD}" \
  psql -X -P pager=off -U app_ods -d db_ods -q -f /tmp/3_setup_app_db.sql
if [[ $? -ne 0 ]]; then
  finish_error 31 "Failed to execute 3_setup_app_db.sql in PostgreSQL pod."
fi
echo "Finish: 0-2. Application database initialized in PostgreSQL pod."

# 2. Set up Realm
echo "Start: 2-1. Obtaining access token from Keycloak..."
TOKEN_RESPONSE="$(
  curl -sS -f --location -X POST "${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_MASTER_REALM}/protocol/openid-connect/token" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
    --data-urlencode "username=${KEYCLOAK_USERNAME}" \
    --data-urlencode "password=${KEYCLOAK_PASSWORD}"
)"
ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')"
if [[ -z "$ACCESS_TOKEN" ]]; then
  finish_error 7 "Access token not found in Keycloak response."
fi
echo "Finish: 2-1. Access token obtained from Keycloak: $(printf '%.20s' "$ACCESS_TOKEN")..."

echo "Start: 2-2. Checking if realm '$KEYCLOAK_REALM' exists in Keycloak..."
REALM_UUID="$(
  curl -sS -o "${TMP_DIR}/realm_lookup.json" -w "%{http_code}" -X GET \
    "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json"
)"
if [[ "$REALM_UUID" == "200" ]]; then
  REALM_UUID="$(jq -r '.id // empty' "${TMP_DIR}/realm_lookup.json")"
else
  REALM_UUID=""
fi

if [[ -z "$REALM_UUID" ]]; then
  echo "Create: 2-2. Realm '$KEYCLOAK_REALM' does not exist in Keycloak. Creating realm..."
  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_BASE_URL}/admin/realms" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"realm\":\"${KEYCLOAK_REALM}\",\"enabled\":true}")"
  if [[ "$http_code" != "201" ]]; then
    finish_error 8 "Failed to create realm '$KEYCLOAK_REALM' (HTTP $http_code)"
  fi

  REALM_UUID="$(
    curl -sS -f -X GET "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      | jq -r '.id // empty'
  )"
  if [[ -z "$REALM_UUID" ]]; then
    finish_error 9 "Failed to retrieve UUID of realm '$KEYCLOAK_REALM' from Keycloak after creation."
  fi
fi
echo "Finish: 2-2. Realm '$KEYCLOAK_REALM' already exists in Keycloak with UUID: $REALM_UUID"

echo "Start: 2-3. Checking if 'editUsernameAllowed' is set to true in realm configuration in Keycloak realm '$KEYCLOAK_REALM'..."
curl -sS -X GET "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" > "${TMP_DIR}/realm.json"
check_path "${TMP_DIR}/realm.json" "Temporary realm configuration file"

IS_EDIT_USERNAME_ALLOWED="$(jq -r '.editUsernameAllowed // false' "${TMP_DIR}/realm.json")"
if [[ "$IS_EDIT_USERNAME_ALLOWED" != "true" ]]; then
  echo "Update: 2-3. 'editUsernameAllowed' is not set to true. Updating realm configuration..."
  jq '.editUsernameAllowed = true' "${TMP_DIR}/realm.json" > "${TMP_DIR}/realm_updated.json"

  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"${TMP_DIR}/realm_updated.json")"
  if [[ "$http_code" != "204" ]]; then
    finish_error 11 "Failed to update realm configuration in Keycloak (HTTP $http_code)."
  fi

  mv "${TMP_DIR}/realm_updated.json" "${TMP_DIR}/realm.json"
fi
echo "Finish: 2-3. Realm configuration in Keycloak realm '$KEYCLOAK_REALM' is updated to set 'editUsernameAllowed' to true if it was not already set."

echo "Start: 2-4. Setting up user profile configuration in Keycloak realm '$KEYCLOAK_REALM'..."
UPCONF_UUID="$(
  curl -sS -X GET "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/components?type=org.keycloak.userprofile.UserProfileProvider" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    | jq -r '.[0].id // empty'
)"
echo "Checked for user profile configuration component in Keycloak realm '$KEYCLOAK_REALM'. UUID: $UPCONF_UUID"

if [[ -z "$UPCONF_UUID" ]]; then
  echo "Put: 2-4. User profile configuration component does not exist. Setting up user profile configuration..."
  if ! create_json_keycloak_userprofile; then
    finish_error 12 "Failed to create user profile configuration JSON for Keycloak."
  fi

  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"${TMP_DIR}/component_payload.json")"
  if [[ "$http_code" != "201" ]]; then
    finish_error 13 "Failed to create user profile configuration component in Keycloak (HTTP $http_code)."
  fi
fi
echo "Finish: 2-4. User profile configuration is set up in Keycloak realm '$KEYCLOAK_REALM' if it was not already set up."

echo "Start: 2-5. Setting up password policy in Keycloak realm '$KEYCLOAK_REALM'..."
if ! create_json_keycloak_password_policy; then
  finish_error 14 "Failed to create JSON for Keycloak password policy."
fi
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @"${TMP_DIR}/realm_password_policy.json")"
if [[ "$http_code" != "204" ]]; then
  finish_error 15 "Failed to update password policy in Keycloak (HTTP $http_code)."
fi
echo "Finish: 2-5. Password policy is set up in Keycloak realm '$KEYCLOAK_REALM'."

# 3. Create the API Authorization client in Keycloak
echo "Start: 3-1. Checking if API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' exists in Keycloak realm '$KEYCLOAK_REALM'..."
API_ADMIN_CLIENT_UUID="$(
  curl -sS -G "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-urlencode "clientId=${KEYCLOAK_CLIENT_ID_API_ADMIN}" \
    | jq -r '.[0].id // empty'
)"
echo "Checked for API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' in Keycloak realm '$KEYCLOAK_REALM'. UUID: $API_ADMIN_CLIENT_UUID"

if [[ -z "$API_ADMIN_CLIENT_UUID" ]]; then
  echo "Create: 3-1. API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' does not exist in Keycloak realm '$KEYCLOAK_REALM'. Creating client..."
  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${KEYCLOAK_CLIENT_ID_API_ADMIN}\",
      \"protocol\": \"openid-connect\",
      \"name\": \"API Authorization Client\",
      \"enabled\": true,
      \"publicClient\": false,
      \"serviceAccountsEnabled\": true,
      \"standardFlowEnabled\": false,
      \"directAccessGrantsEnabled\": false,
      \"implicitFlowEnabled\": false,
      \"attributes\": {
        \"client_credentials.use_refresh_token\": \"false\"
      }
    }")"
  if [[ "$http_code" != "201" ]]; then
    finish_error 16 "Failed to create API Authorization client in Keycloak (HTTP $http_code)."
  fi

  API_ADMIN_CLIENT_UUID="$(
    curl -sS -G "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-urlencode "clientId=${KEYCLOAK_CLIENT_ID_API_ADMIN}" \
      | jq -r '.[0].id // empty'
  )"
  if [[ -z "$API_ADMIN_CLIENT_UUID" ]]; then
    finish_error 16 "Failed to retrieve API Authorization client UUID after creation."
  fi
fi
echo "Finish: 3-1. API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' already exists in Keycloak realm '$KEYCLOAK_REALM' with UUID: $API_ADMIN_CLIENT_UUID"

echo "Start: 3-2. Checking if protocol mapper for 'open_system_id' claim exists in API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN'..."
MAPPER_COUNT="$(
  curl -sS -X GET "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${API_ADMIN_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    | jq -r --arg claim_name "open_system_id" --arg claim_value "${KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN}" '
        [ .[]
          | select(.config["claim.name"] == $claim_name)
          | select(.config["claim.value"] == $claim_value)
        ] | length
      '
)"
echo "Checked for protocol mapper for 'open_system_id' claim in API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' in Keycloak realm '$KEYCLOAK_REALM'."

if [[ "$MAPPER_COUNT" == "0" ]]; then
  echo "Create: 3-2. Protocol mapper for 'open_system_id' claim does not exist. Creating protocol mapper..."
  http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${API_ADMIN_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"open_system_id_mapper\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-hardcoded-claim-mapper\",
      \"config\": {
        \"claim.name\": \"open_system_id\",
        \"claim.value\": \"${KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN}\",
        \"jsonType.label\": \"String\",
        \"id.token.claim\": \"false\",
        \"access.token.claim\": \"true\",
        \"userinfo.token.claim\": \"false\",
        \"introspection.token.claim\": \"true\"
      }
    }")"
  if [[ "$http_code" != "201" ]]; then
    finish_error 17 "Failed to create protocol mapper in Keycloak (HTTP $http_code)."
  fi
fi
echo "Finish: 3-2. Protocol mapper for 'open_system_id' claim created in API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN'."

echo "Start: 3-3. Retrieving client secret for API Authorization client '$KEYCLOAK_CLIENT_ID_API_ADMIN' from Keycloak..."
KEYCLOAK_CLIENT_SECRET_API_ADMIN="$(
  curl -sS -X GET "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${API_ADMIN_CLIENT_UUID}/client-secret" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    | jq -r '.value // empty'
)"
if [[ -z "$KEYCLOAK_CLIENT_SECRET_API_ADMIN" ]]; then
  finish_error 18 "Failed to retrieve client secret for API Authorization client from Keycloak."
fi
echo "Finish: 3-3. Retrieved client secret for API Authorization client from Keycloak: $(printf '%.20s' "$KEYCLOAK_CLIENT_SECRET_API_ADMIN")..."

# 4. Set up API authorization store in OpenFGA
echo "Start: 4-1. Creating API authorization store in OpenFGA..."
API_AUTHZ_STORE_ID="$(
  curl -sS -f -X POST \
    "${OPENFGA_BASE_URL}/stores" \
    -H "Content-Type: application/json" \
    -d @"${OPENFGA_JSON_DIR}/01-create-store-api-authz.json" \
    | jq -r '.id // empty'
)"
if [[ -z "$API_AUTHZ_STORE_ID" ]]; then
  finish_error 19 "Failed to create API authorization store in OpenFGA."
fi
echo "Finish: 4-1. API authorization store created in OpenFGA with ID: $API_AUTHZ_STORE_ID"

echo "Start: 4-2. Creating authorization model in API authorization store in OpenFGA..."
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "${OPENFGA_BASE_URL}/stores/${API_AUTHZ_STORE_ID}/authorization-models" \
  -H "Content-Type: application/json" \
  -d @"${OPENFGA_JSON_DIR}/02-create-model-api-authz.json")"
if [[ "$http_code" != "201" ]]; then
  finish_error 20 "Failed to create authorization model in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 4-2. Authorization model created in API authorization store in OpenFGA."

echo "Start: 4-3. Creating role tuples in API authorization store in OpenFGA..."
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "${OPENFGA_BASE_URL}/stores/${API_AUTHZ_STORE_ID}/write" \
  -H "Content-Type: application/json" \
  -d @"${OPENFGA_JSON_DIR}/03-create-tuples-api-authz-role.json")"
if [[ "$http_code" != "200" ]]; then
  finish_error 21 "Failed to create role tuples in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 4-3. Role tuples created in API authorization store in OpenFGA."

# 5. Set up realm store binding in OpenFGA
echo "Start: 5-1. Creating realm store binding in OpenFGA..."
REALM_AUTHZ_STORE_ID="$(
  curl -sS -f -X POST \
    "${OPENFGA_BASE_URL}/stores" \
    -H "Content-Type: application/json" \
    -d @"${OPENFGA_JSON_DIR}/11-create-store-realm-store-binding.json" \
    | jq -r '.id // empty'
)"
if [[ -z "$REALM_AUTHZ_STORE_ID" ]]; then
  finish_error 22 "Failed to create realm store binding in OpenFGA."
fi
echo "Finish: 5-1. Realm store binding created in OpenFGA with ID: $REALM_AUTHZ_STORE_ID"

echo "Start: 5-2. Creating authorization model in realm store binding in OpenFGA..."
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "${OPENFGA_BASE_URL}/stores/${REALM_AUTHZ_STORE_ID}/authorization-models" \
  -H "Content-Type: application/json" \
  -d @"${OPENFGA_JSON_DIR}/12-create-model-realm-store-binding.json")"
if [[ "$http_code" != "201" ]]; then
  finish_error 23 "Failed to create authorization model in realm store binding in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 5-2. Authorization model created in realm store binding in OpenFGA."

# 6. Set up operator-plant authorization in OpenFGA
echo "Start: 6-1. Creating operator-plant authorization store in OpenFGA..."
OPERATOR_PLANT_AUTHZ_STORE_ID="$(
  curl -sS -f -X POST \
    "${OPENFGA_BASE_URL}/stores" \
    -H "Content-Type: application/json" \
    -d @"${OPENFGA_JSON_DIR}/21-create-store-operator-plant.json" \
    | jq -r '.id // empty'
)"
if [[ -z "$OPERATOR_PLANT_AUTHZ_STORE_ID" ]]; then
  finish_error 24 "Failed to create operator-plant authorization store in OpenFGA."
fi
echo "Finish: 6-1. Operator-plant authorization store created in OpenFGA with ID: $OPERATOR_PLANT_AUTHZ_STORE_ID"

echo "Start: 6-2. Creating authorization model in operator-plant authorization store in OpenFGA..."
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "${OPENFGA_BASE_URL}/stores/${OPERATOR_PLANT_AUTHZ_STORE_ID}/authorization-models" \
  -H "Content-Type: application/json" \
  -d @"${OPENFGA_JSON_DIR}/22-create-model-operator-plant.json")"
if [[ "$http_code" != "201" ]]; then
  finish_error 25 "Failed to create authorization model in operator-plant authorization store in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 6-2. Authorization model created in operator-plant authorization store in OpenFGA."

echo "Start: 6-3. Creating role tuples in operator-plant authorization store in OpenFGA..."
http_code="$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
  "${OPENFGA_BASE_URL}/stores/${OPERATOR_PLANT_AUTHZ_STORE_ID}/write" \
  -H "Content-Type: application/json" \
  -d @"${OPENFGA_JSON_DIR}/23-create-tuples-operator-plant.json")"
if [[ "$http_code" != "200" ]]; then
  finish_error 26 "Failed to create role tuples in operator-plant authorization store in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 6-3. Role tuples created in operator-plant authorization store in OpenFGA."

# 7. Create user tuples in the API authorization store, substituting the user ID for the API admin client
echo "Start: 7-1. Creating user tuples in API authorization store in OpenFGA..."
http_code="$(
  AUTHZ_USER_ID="${KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN}" envsubst < "${OPENFGA_JSON_DIR}/04-create-tuples-api-authz-userid.json" \
    | curl -sS -o /dev/null -w "%{http_code}" -X POST \
      "${OPENFGA_BASE_URL}/stores/${API_AUTHZ_STORE_ID}/write" \
      -H "Content-Type: application/json" \
      -d @-
)"
if [[ "$http_code" != "200" ]]; then
  finish_error 27 "Failed to create user tuples in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 7-1. User tuples created in API authorization store in OpenFGA."

echo "Start: 7-2. Creating user tuples in operator-plant authorization store in OpenFGA..."
http_code="$(
  AUTHZ_USER_ID="${KEYCLOAK_CLAIM_OPEN_SYSTEM_ID_API_ADMIN}" envsubst < "${OPENFGA_JSON_DIR}/24-create-tuples-operator-plant-admin.json" \
    | curl -sS -o /dev/null -w "%{http_code}" -X POST \
      "${OPENFGA_BASE_URL}/stores/${OPERATOR_PLANT_AUTHZ_STORE_ID}/write" \
      -H "Content-Type: application/json" \
      -d @-
)"
if [[ "$http_code" != "200" ]]; then
  finish_error 28 "Failed to create user tuples in OpenFGA (HTTP $http_code)."
fi
echo "Finish: 7-2. User tuples created in operator-plant authorization store in OpenFGA."

# 8. Set up OPEN-DATASPACES database in PostgreSQL
echo "Start: 8-1. Setting up OPEN-DATASPACES database in PostgreSQL..."
kubectl -n "${NAMESPACE}" cp "$SQL_DIR/4_setup_app_table.sql" "${POSTGRES_POD}:/tmp/4_setup_app_table.sql"

kubectl -n "${NAMESPACE}" exec "${POSTGRES_POD}" -- \
  env PGPASSWORD="${POSTGRES_PASSWORD}" \
  psql -X -P pager=off \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -v ON_ERROR_STOP=1 \
    -f /tmp/4_setup_app_table.sql \
    -v "idp_realm=${KEYCLOAK_REALM}" \
    -v "pdp_store_id_api_authz=${API_AUTHZ_STORE_ID}" \
    -v "pdp_store_id_realm_store_binding=${REALM_AUTHZ_STORE_ID}" \
    -v "pdp_store_id_operator_plant_authz=${OPERATOR_PLANT_AUTHZ_STORE_ID}" \
    -v "api_key=${L3TBL_API_KEY}" \
    -v "api_key_id=${L3TBL_API_KEYS_ID}" \
    -v "api_key_name=${L3TBL_API_KEYS_NAME}" \
    -v "usecase=${L3TBL_API_KEYS_USECASE}" \
    -v "environment_name=${L3TBL_AUTHZ_STORES_ENVIRONMENT_NAME}" \
    -v "cidr=${L3TBL_CIDRS_CIDR}"
if [[ $? -ne 0 ]]; then
  finish_error 29 "Failed to set up database in PostgreSQL."
fi
echo "Finish: 8-1. Database setup in PostgreSQL completed."

# 9. Update charts/l3/values.yaml
echo "Start: 9-1. Updating charts/l3/values.yaml..."
update_values_key "${L3_VALUES_FILE}" "keycloakIntrospectClientId" "${KEYCLOAK_CLIENT_ID_API_ADMIN}"
update_values_key "${L3_VALUES_FILE}" "l3KeycloakIntrospectClientSecret" "${KEYCLOAK_CLIENT_SECRET_API_ADMIN}"
echo "Finish: 9-1. charts/l3/values.yaml updated."

echo "-------------------------------------------------------------------------"
echo "Setup completed successfully!"
echo "Summary of created resources and configuration:"
echo "Keycloak realm: $KEYCLOAK_REALM"
echo "API Authorization client ID in Keycloak: $KEYCLOAK_CLIENT_ID_API_ADMIN"
echo "API Authorization client secret in Keycloak: $KEYCLOAK_CLIENT_SECRET_API_ADMIN"
echo "API Authorization store ID in OpenFGA: $API_AUTHZ_STORE_ID"
echo "Realm-store binding store ID in OpenFGA: $REALM_AUTHZ_STORE_ID"
echo "Operator-plant authorization store ID in OpenFGA: $OPERATOR_PLANT_AUTHZ_STORE_ID"
echo "System API key in PostgreSQL (use this in API-Key header): $L3TBL_API_KEY"
echo "System API key ID in PostgreSQL: $L3TBL_API_KEYS_ID"
echo "Updated Helm values file: $L3_VALUES_FILE"
echo "Log file: $LOG_FILE"
echo ""
echo "Apply updated values:"
echo "  helm upgrade --install ${RELEASE_NAME} ${PROJECT_ROOT} -n ${NAMESPACE}"
