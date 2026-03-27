#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_NS="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
NAMESPACE="${NAMESPACE:-${DEFAULT_NS:-default}}"
RELEASE_NAME="${RELEASE_NAME:-}"
OPENFGA_SERVICE="${OPENFGA_SERVICE:-}"
L2_VALUES_FILE="${L2_VALUES_FILE:-$PROJECT_ROOT/charts/l2/values.yaml}"
L3_VALUES_FILE="${L3_VALUES_FILE:-$PROJECT_ROOT/charts/l3/values.yaml}"

OPENFGA_API_PORT="${OPENFGA_API_PORT:-}"
API_ENDPOINT="${API_ENDPOINT:-}"
ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD:-true}"

OPENFGA_PF_PID=""

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

check_path() {
  local path="$1"
  local description="$2"

  if [[ -z "$path" ]]; then
    echo "Error: $description not provided." >&2
    exit 1
  fi
  if [[ ! -e "$path" ]]; then
    echo "Error: $description '$path' does not exist." >&2
    exit 1
  fi
}

load_chart_defaults() {
  if [[ -z "${OPENFGA_API_PORT}" ]]; then
    OPENFGA_API_PORT="$(read_yaml_value "openfga.service.apiPort" "${L3_VALUES_FILE}" || true)"
  fi

  OPENFGA_API_PORT="${OPENFGA_API_PORT:-8083}"

  if [[ -z "${API_ENDPOINT}" ]]; then
    API_ENDPOINT="http://127.0.0.1:${OPENFGA_API_PORT}"
  fi
}

detect_release_name() {
  kubectl -n "$NAMESPACE" get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | sed -n 's/\(.*\)-l3-openfga$/\1/p' \
    | head -n1
}

resolve_targets() {
  if [[ -z "$RELEASE_NAME" ]]; then
    RELEASE_NAME="$(detect_release_name || true)"
  fi
  if [[ -z "$RELEASE_NAME" ]]; then
    echo "Error: RELEASE_NAME could not be auto-detected in namespace '$NAMESPACE'." >&2
    echo "       Please set RELEASE_NAME explicitly, e.g. RELEASE_NAME=ods" >&2
    exit 1
  fi

  if [[ -z "$OPENFGA_SERVICE" ]]; then
    OPENFGA_SERVICE="${RELEASE_NAME}-l3-openfga"
  fi

  kubectl -n "$NAMESPACE" get svc "$OPENFGA_SERVICE" >/dev/null
  kubectl -n "$NAMESPACE" wait --for=condition=Ready pod -l "app=${RELEASE_NAME}-l3-openfga" --timeout=180s >/dev/null
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

  echo "Error: timeout waiting for $url" >&2
  return 1
}

cleanup() {
  if [[ -n "${OPENFGA_PF_PID}" ]] && kill -0 "${OPENFGA_PF_PID}" >/dev/null 2>&1; then
    kill "${OPENFGA_PF_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

update_values_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped_value

  if ! grep -q "^[[:space:]]*${key}:" "$file"; then
    echo "Error: key '${key}' was not found in ${file}" >&2
    exit 1
  fi

  escaped_value="$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g' -e 's/"/\\"/g')"
  sed -i "s|^\([[:space:]]*${key}:[[:space:]]*\).*|\1\"${escaped_value}\"|" "$file"
}

require_cmd kubectl
require_cmd curl
require_cmd jq
require_cmd sed
require_cmd awk

check_path "${L2_VALUES_FILE}" "<path_to_l2_values_file>"
check_path "${L3_VALUES_FILE}" "<path_to_l3_values_file>"
check_path "${SCRIPT_DIR}/openfga/51-create-user-store.json" "<path_to_openfga_user_store_json>"
check_path "${SCRIPT_DIR}/openfga/52-create-user-store-model.json" "<path_to_openfga_user_store_model_json>"

load_chart_defaults
resolve_targets

echo "Namespace       : ${NAMESPACE}"
echo "Release         : ${RELEASE_NAME}"
echo "OpenFGA service : ${OPENFGA_SERVICE}"
echo "L2 values file  : ${L2_VALUES_FILE}"
echo "L3 values file  : ${L3_VALUES_FILE}"

if [[ "${ENABLE_PORT_FORWARD}" == "true" ]]; then
  echo "Starting port-forward for OpenFGA (${OPENFGA_SERVICE}:${OPENFGA_API_PORT})"
  kubectl -n "${NAMESPACE}" port-forward "svc/${OPENFGA_SERVICE}" "${OPENFGA_API_PORT}:${OPENFGA_API_PORT}" >/tmp/l2-setup-openfga-pf.log 2>&1 &
  OPENFGA_PF_PID=$!
  sleep 1
  if ! kill -0 "${OPENFGA_PF_PID}" >/dev/null 2>&1; then
    echo "Error: failed to start port-forward for ${OPENFGA_SERVICE}" >&2
    cat /tmp/l2-setup-openfga-pf.log >&2 || true
    exit 1
  fi
fi

echo "Creating User Store..."
USER_STORE_ID="$(
  curl -sS -X POST \
    "${API_ENDPOINT}/stores" \
    -H "Content-Type: application/json" \
    -d @"${SCRIPT_DIR}/openfga/51-create-user-store.json" \
    | jq -r '.id // empty'
)"
if [[ -z "${USER_STORE_ID}" ]]; then
  echo "Error: failed to create user store in OpenFGA." >&2
  exit 1
fi
echo "Create Store completed."

echo "Creating User Store Model..."
USER_MODEL_ID="$(
  curl -sS -X POST \
    "${API_ENDPOINT}/stores/${USER_STORE_ID}/authorization-models" \
    -H "Content-Type: application/json" \
    -d @"${SCRIPT_DIR}/openfga/52-create-user-store-model.json" \
    | jq -r '.authorization_model_id // empty'
)"
if [[ -z "${USER_MODEL_ID}" ]]; then
  echo "Error: failed to create user store model in OpenFGA." >&2
  exit 1
fi
echo "Create Model completed."

echo ""
echo "Updating charts/l2/values.yaml"
update_values_key "${L2_VALUES_FILE}" "fgaStoreId" "${USER_STORE_ID}"
update_values_key "${L2_VALUES_FILE}" "fgaModelId" "${USER_MODEL_ID}"
echo "charts/l2/values.yaml updated"
echo ""

ENV_FILE="${SCRIPT_DIR}/.env.userstore"
cat > "${ENV_FILE}" <<EOF
# OpenFGA Settings (generated by setup_l2.sh)
USER_STORE_ID=${USER_STORE_ID}
USER_MODEL_ID=${USER_MODEL_ID}
EOF

echo "User Store ID:  ${USER_STORE_ID}"
echo "User Model ID:  ${USER_MODEL_ID}"
echo "Saved: ${ENV_FILE}"
echo ""
echo "Apply updated values if needed:"
echo "  helm upgrade --install ${RELEASE_NAME} ${PROJECT_ROOT} -n ${NAMESPACE}"
