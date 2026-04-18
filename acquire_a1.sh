#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ENV_FILE="${SCRIPT_DIR}/acquire_a1.env"

ENV_FILE=""
COMMAND_MODE="run"
TERMINAL_ALERT_SENT=0

usage() {
  cat <<'EOF'
Usage:
  acquire_a1.sh [--env-file PATH] [--test-telegram]

Options:
  --env-file PATH    Load configuration from PATH. Defaults to ./acquire_a1.env
  --test-telegram    Send a Telegram test message and exit
  -h, --help         Show this help text
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      shift
      [ "$#" -gt 0 ] || { echo "--env-file requires a path" >&2; exit 2; }
      ENV_FILE="$1"
      ;;
    --test-telegram)
      COMMAND_MODE="test_telegram"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$ENV_FILE" ]; then
  ENV_FILE="$DEFAULT_ENV_FILE"
fi

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a && . "$ENV_FILE" && set +a
fi

if [ -n "${OCI_BIN:-}" ]; then
  OCI_BIN="${OCI_BIN}"
elif [ -x "/root/bin/oci" ]; then
  OCI_BIN="/root/bin/oci"
else
  OCI_BIN="oci"
fi
JQ_BIN="${JQ_BIN:-jq}"
CURL_BIN="${CURL_BIN:-curl}"
HOSTNAME_BIN="${HOSTNAME_BIN:-hostname}"
BASE64_BIN="${BASE64_BIN:-base64}"

OCI_CLI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-}"
OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-}"
OCI_REGION="${OCI_REGION:-}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:-}"
CAPACITY_REPORT_COMPARTMENT_OCID="${CAPACITY_REPORT_COMPARTMENT_OCID:-${COMPARTMENT_OCID}}"
SUBNET_OCID="${SUBNET_OCID:-}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-}"
INSTANCE_DISPLAY_NAME="${INSTANCE_DISPLAY_NAME:-}"
TARGET_SHAPE="${TARGET_SHAPE:-VM.Standard.A1.Flex}"
TARGET_OCPUS="${TARGET_OCPUS:-4}"
TARGET_MEMORY_GB="${TARGET_MEMORY_GB:-24}"
IMAGE_OS="${IMAGE_OS:-Canonical Ubuntu}"
IMAGE_OS_VERSION="${IMAGE_OS_VERSION:-24.04}"
IMAGE_OCID="${IMAGE_OCID:-}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
MAX_JITTER_SECONDS="${MAX_JITTER_SECONDS:-20}"
USER_DATA_FILE="${USER_DATA_FILE:-}"
METADATA_JSON_FILE="${METADATA_JSON_FILE:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_NOTIFY_TERMINAL_ERRORS="${TELEGRAM_NOTIFY_TERMINAL_ERRORS:-true}"
INSTANCE_LAUNCH_TIMEOUT_SECONDS="${INSTANCE_LAUNCH_TIMEOUT_SECONDS:-900}"

WATCHER_HOST="$("$HOSTNAME_BIN" -f 2>/dev/null || "$HOSTNAME_BIN" 2>/dev/null || printf 'unknown-host')"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Required command not found: $1"
    exit 1
  }
}

require_var() {
  local var_name="$1"
  if [ -z "${!var_name:-}" ]; then
    log "Required configuration is missing: ${var_name}"
    return 1
  fi
}

cleanup_files() {
  for path in "$@"; do
    [ -n "$path" ] && [ -e "$path" ] && rm -f "$path"
  done
}

send_telegram_message() {
  local message="$1"

  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "Telegram credentials are not configured; skipping notification."
    return 0
  fi

  "$CURL_BIN" --fail --silent --show-error \
    --max-time 30 \
    --request POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    >/dev/null
}

send_terminal_alert_once() {
  local message="$1"

  if [ "$TELEGRAM_NOTIFY_TERMINAL_ERRORS" != "true" ] || [ "$TERMINAL_ALERT_SENT" -eq 1 ]; then
    return 0
  fi

  if send_telegram_message "$message"; then
    TERMINAL_ALERT_SENT=1
  else
    log "Failed to send Telegram terminal alert."
  fi
}

oci_args=()
if [ -n "$OCI_REGION" ]; then
  oci_args+=(--region "$OCI_REGION")
fi
if [ -n "$OCI_CLI_PROFILE" ]; then
  oci_args+=(--profile "$OCI_CLI_PROFILE")
fi
if [ -n "$OCI_CLI_CONFIG_FILE" ]; then
  oci_args+=(--config-file "$OCI_CLI_CONFIG_FILE")
fi

run_oci() {
  "$OCI_BIN" "${oci_args[@]}" "$@"
}

bool_to_json() {
  case "$1" in
    true|TRUE|True|1|yes|YES|on|ON) printf 'true' ;;
    false|FALSE|False|0|no|NO|off|OFF) printf 'false' ;;
    *)
      log "Expected a boolean-style value, got: $1"
      exit 1
      ;;
  esac
}

sleep_with_jitter() {
  local jitter=0
  if [ "$MAX_JITTER_SECONDS" -gt 0 ]; then
    jitter=$(( RANDOM % (MAX_JITTER_SECONDS + 1) ))
  fi
  local total_sleep=$(( SLEEP_SECONDS + jitter ))
  log "Sleeping ${total_sleep}s before the next capacity check."
  sleep "$total_sleep"
}

classify_oci_error() {
  local file_path="$1"
  local content
  content="$(tr '[:upper:]' '[:lower:]' < "$file_path")"

  case "$content" in
    *"out of host capacity"*|*"out of capacity for shape"*|*"insufficient capacity"*|*"try again later"*|*"too many requests"*|*"rate limit"*|*"service unavailable"*|*"timed out"*|*"timeout"*|*"temporarily unavailable"*|*"connection reset"*|*"internalerror"*|*"internal error"*|*"bad gateway"*|*"gateway timeout"*)
      printf 'retryable'
      return 0
      ;;
    *"notauthenticated"*|*"not authorized"*|*"notauthorizedornotfound"*|*"authorization failed"*|*"could not find config file"*|*"config file"*|*"config profile"*|*"invalidparameter"*|*"invalid parameter"*|*"invalid shape"*|*"shape is not valid for image"*|*"not a valid ocid"*|*"does not exist"*|*"cannot be parsed"*|*"unknown enum value"*|*"ssh_public_key_path"*|*"permission denied"*)
      printf 'terminal'
      return 0
      ;;
    *)
      printf 'terminal'
      return 0
      ;;
  esac
}

lookup_image_id() {
  if [ -n "$IMAGE_OCID" ]; then
    printf '%s\n' "$IMAGE_OCID"
    return 0
  fi

  local image_json
  image_json="$(mktemp)"
  local error_log
  error_log="$(mktemp)"

  if ! run_oci compute image list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all \
    --shape "$TARGET_SHAPE" \
    --operating-system "$IMAGE_OS" \
    --operating-system-version "$IMAGE_OS_VERSION" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --output json \
    >"$image_json" 2>"$error_log"; then
    local classification
    classification="$(classify_oci_error "$error_log")"
    cat "$error_log" >&2
    cleanup_files "$image_json" "$error_log"
    if [ "$classification" = "retryable" ]; then
      return 75
    fi
    return 1
  fi

  local image_id
  image_id="$("$JQ_BIN" -r '
    .data
    | map(select((."display-name" // "" | ascii_downcase | contains("aarch64"))))
    | sort_by(."time-created")
    | reverse
    | .[0].id // empty
  ' "$image_json")"

  cleanup_files "$image_json" "$error_log"

  if [ -z "$image_id" ]; then
    log "No matching Arm image was found for ${IMAGE_OS} ${IMAGE_OS_VERSION} on ${TARGET_SHAPE}."
    return 1
  fi

  printf '%s\n' "$image_id"
}

discover_ads() {
  local output_json
  output_json="$(mktemp)"
  local error_log
  error_log="$(mktemp)"

  if ! run_oci iam availability-domain list \
    --compartment-id "$COMPARTMENT_OCID" \
    --all \
    --output json \
    >"$output_json" 2>"$error_log"; then
    local classification
    classification="$(classify_oci_error "$error_log")"
    cat "$error_log" >&2
    cleanup_files "$output_json" "$error_log"
    if [ "$classification" = "retryable" ]; then
      return 75
    fi
    return 1
  fi

  "$JQ_BIN" -r '.data[]?.name // empty' "$output_json"
  cleanup_files "$output_json" "$error_log"
}

capacity_report_allows_launch() {
  local availability_domain="$1"
  local shape_payload
  shape_payload="$(mktemp)"
  local response_json
  response_json="$(mktemp)"
  local error_log
  error_log="$(mktemp)"

  cat >"$shape_payload" <<EOF
[
  {
    "instanceShape": "${TARGET_SHAPE}",
    "instanceShapeConfig": {
      "ocpus": ${TARGET_OCPUS},
      "memoryInGBs": ${TARGET_MEMORY_GB}
    }
  }
]
EOF

  if ! run_oci compute compute-capacity-report create \
    --availability-domain "$availability_domain" \
    --compartment-id "$CAPACITY_REPORT_COMPARTMENT_OCID" \
    --shape-availabilities "file://${shape_payload}" \
    --output json \
    >"$response_json" 2>"$error_log"; then
    log "Capacity report failed for ${availability_domain}; falling back to a direct launch attempt."
    cat "$error_log" >&2
    cleanup_files "$shape_payload" "$response_json" "$error_log"
    return 0
  fi

  local status_blob
  status_blob="$("$JQ_BIN" -r '
    [
      .. | .["availability-status"]? // empty,
      .. | .availabilityStatus? // empty,
      .. | .status? // empty,
      .. | .message? // empty
    ] | join(" ")
  ' "$response_json" | tr '[:upper:]' '[:lower:]')"

  cleanup_files "$shape_payload" "$response_json" "$error_log"

  case "$status_blob" in
    *"no_capacity"*|*"no capacity"*|*"out_of_host_capacity"*|*"out of host capacity"*|*"insufficient capacity"*)
      log "Capacity report indicates no capacity in ${availability_domain}."
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

build_metadata_file() {
  local metadata_json
  metadata_json="$(mktemp)"
  local source_json="{}"

  if [ -n "$METADATA_JSON_FILE" ]; then
    source_json="$(cat "$METADATA_JSON_FILE")"
  fi

  local ssh_key
  ssh_key="$(cat "$SSH_PUBLIC_KEY_PATH")"

  if [ -n "$USER_DATA_FILE" ]; then
    "$JQ_BIN" -n \
      --argjson base "${source_json}" \
      --arg ssh_key "$ssh_key" \
      --arg user_data "$("$BASE64_BIN" -w0 "$USER_DATA_FILE")" \
      '$base + {ssh_authorized_keys: $ssh_key, user_data: $user_data}' \
      >"$metadata_json"
  else
    "$JQ_BIN" -n \
      --argjson base "${source_json}" \
      --arg ssh_key "$ssh_key" \
      '$base + {ssh_authorized_keys: $ssh_key}' \
      >"$metadata_json"
  fi

  printf '%s\n' "$metadata_json"
}

fetch_instance_ips() {
  local instance_id="$1"
  local attachments_json
  attachments_json="$(mktemp)"
  local attachment_errors
  attachment_errors="$(mktemp)"

  if ! run_oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_OCID" \
    --instance-id "$instance_id" \
    --all \
    --output json \
    >"$attachments_json" 2>"$attachment_errors"; then
    cleanup_files "$attachments_json" "$attachment_errors"
    return 0
  fi

  local vnic_id
  vnic_id="$("$JQ_BIN" -r '.data[0]."vnic-id" // empty' "$attachments_json")"
  cleanup_files "$attachments_json" "$attachment_errors"

  if [ -z "$vnic_id" ]; then
    return 0
  fi

  local vnic_json
  vnic_json="$(mktemp)"
  local vnic_errors
  vnic_errors="$(mktemp)"

  if ! run_oci network vnic get \
    --vnic-id "$vnic_id" \
    --output json \
    >"$vnic_json" 2>"$vnic_errors"; then
    cleanup_files "$vnic_json" "$vnic_errors"
    return 0
  fi

  local private_ip public_ip
  private_ip="$("$JQ_BIN" -r '.data."private-ip" // empty' "$vnic_json")"
  public_ip="$("$JQ_BIN" -r '.data."public-ip" // empty' "$vnic_json")"
  cleanup_files "$vnic_json" "$vnic_errors"

  printf '%s|%s\n' "$private_ip" "$public_ip"
}

launch_instance() {
  local availability_domain="$1"
  local image_id="$2"
  local metadata_file="$3"

  local shape_config_json
  shape_config_json="$(mktemp)"
  local source_details_json
  source_details_json="$(mktemp)"
  local response_json
  response_json="$(mktemp)"
  local error_log
  error_log="$(mktemp)"

  cat >"$shape_config_json" <<EOF
{
  "ocpus": ${TARGET_OCPUS},
  "memoryInGBs": ${TARGET_MEMORY_GB}
}
EOF

  cat >"$source_details_json" <<EOF
{
  "sourceType": "image",
  "imageId": "${image_id}"
}
EOF

  if ! run_oci compute instance launch \
    --availability-domain "$availability_domain" \
    --compartment-id "$COMPARTMENT_OCID" \
    --shape "$TARGET_SHAPE" \
    --shape-config "file://${shape_config_json}" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip "$(bool_to_json "$ASSIGN_PUBLIC_IP")" \
    --display-name "$INSTANCE_DISPLAY_NAME" \
    --metadata "file://${metadata_file}" \
    --source-details "file://${source_details_json}" \
    --wait-for-state RUNNING \
    --max-wait-seconds "$INSTANCE_LAUNCH_TIMEOUT_SECONDS" \
    --output json \
    >"$response_json" 2>"$error_log"; then
    local classification
    classification="$(classify_oci_error "$error_log")"
    cat "$error_log" >&2
    cleanup_files "$shape_config_json" "$source_details_json" "$response_json" "$error_log"
    printf '%s\n' "$classification"
    return 1
  fi

  cat "$response_json"
  cleanup_files "$shape_config_json" "$source_details_json" "$response_json" "$error_log"
}

send_success_notification() {
  local instance_id="$1"
  local availability_domain="$2"
  local private_ip="$3"
  local public_ip="$4"
  local message

  message=$(
    cat <<EOF
OCI A1 capacity watcher succeeded
watcher: ${WATCHER_HOST}
time: $(timestamp)
region: ${OCI_REGION}
availability domain: ${availability_domain}
shape: ${TARGET_SHAPE} (${TARGET_OCPUS} OCPU / ${TARGET_MEMORY_GB} GB)
display name: ${INSTANCE_DISPLAY_NAME}
instance OCID: ${instance_id}
private IP: ${private_ip:-n/a}
public IP: ${public_ip:-n/a}
EOF
  )

  send_telegram_message "$message"
}

send_terminal_failure_notification() {
  local reason="$1"
  local message

  message=$(
    cat <<EOF
OCI A1 capacity watcher stopped
watcher: ${WATCHER_HOST}
time: $(timestamp)
region: ${OCI_REGION:-unknown}
display name: ${INSTANCE_DISPLAY_NAME:-unknown}
reason: ${reason}
EOF
  )

  send_terminal_alert_once "$message"
}

validate_common_requirements() {
  require_command "$OCI_BIN"
  require_command "$JQ_BIN"
  require_command "$CURL_BIN"
}

validate_run_requirements() {
  local missing=0

  require_var OCI_REGION || missing=1
  require_var COMPARTMENT_OCID || missing=1
  require_var SUBNET_OCID || missing=1
  require_var SSH_PUBLIC_KEY_PATH || missing=1
  require_var INSTANCE_DISPLAY_NAME || missing=1
  require_var TELEGRAM_BOT_TOKEN || missing=1
  require_var TELEGRAM_CHAT_ID || missing=1

  if [ "$missing" -ne 0 ]; then
    send_terminal_failure_notification "required configuration is missing"
    exit 1
  fi

  if [ ! -r "$SSH_PUBLIC_KEY_PATH" ]; then
    log "SSH public key file is not readable: $SSH_PUBLIC_KEY_PATH"
    send_terminal_failure_notification "SSH public key file is not readable"
    exit 1
  fi

  if [ -n "$METADATA_JSON_FILE" ] && [ ! -r "$METADATA_JSON_FILE" ]; then
    log "Metadata JSON file is not readable: $METADATA_JSON_FILE"
    send_terminal_failure_notification "metadata JSON file is not readable"
    exit 1
  fi

  if [ -n "$USER_DATA_FILE" ] && [ ! -r "$USER_DATA_FILE" ]; then
    log "User data file is not readable: $USER_DATA_FILE"
    send_terminal_failure_notification "user data file is not readable"
    exit 1
  fi
}

test_telegram() {
  require_var TELEGRAM_BOT_TOKEN || exit 1
  require_var TELEGRAM_CHAT_ID || exit 1
  local message
  message=$(
    cat <<EOF
OCI A1 capacity watcher Telegram test
watcher: ${WATCHER_HOST}
time: $(timestamp)
region: ${OCI_REGION:-unknown}
EOF
  )
  send_telegram_message "$message"
  log "Telegram test message sent."
}

main() {
  validate_common_requirements

  if [ "$COMMAND_MODE" = "test_telegram" ]; then
    test_telegram
    return 0
  fi

  validate_run_requirements

  local metadata_file
  if ! metadata_file="$(build_metadata_file)"; then
    send_terminal_failure_notification "failed to build launch metadata"
    exit 1
  fi
  trap 'cleanup_files "$metadata_file"' EXIT

  local attempt=1
  while true; do
    log "Starting acquisition attempt ${attempt}."

    local image_id lookup_rc
    if image_id="$(lookup_image_id)"; then
      log "Using image ${image_id} for ${TARGET_SHAPE}."
    else
      lookup_rc=$?
      if [ "$lookup_rc" -eq 75 ]; then
        log "Image lookup hit a retryable OCI condition."
        attempt=$((attempt + 1))
        sleep_with_jitter
        continue
      fi
      send_terminal_failure_notification "image lookup failed"
      exit 1
    fi

    local ads_output ads_rc
    if ads_output="$(discover_ads)"; then
      :
    else
      ads_rc=$?
      if [ "$ads_rc" -eq 75 ]; then
        log "Availability domain discovery hit a retryable OCI condition."
        attempt=$((attempt + 1))
        sleep_with_jitter
        continue
      fi
      send_terminal_failure_notification "availability domain discovery failed"
      exit 1
    fi

    if [ -z "$ads_output" ]; then
      log "No availability domains were returned by OCI."
      send_terminal_failure_notification "no availability domains were returned"
      exit 1
    fi

    while IFS= read -r availability_domain; do
      [ -n "$availability_domain" ] || continue

      log "Checking ${availability_domain} for ${TARGET_SHAPE} capacity."
      if ! capacity_report_allows_launch "$availability_domain"; then
        continue
      fi

      local launch_output
      if launch_output="$(launch_instance "$availability_domain" "$image_id" "$metadata_file")"; then
        local instance_id
        instance_id="$(printf '%s\n' "$launch_output" | "$JQ_BIN" -r '.data.id // empty')"
        local ip_summary private_ip public_ip
        ip_summary="$(fetch_instance_ips "$instance_id")"
        private_ip="${ip_summary%%|*}"
        public_ip="${ip_summary#*|}"

        log "Successfully launched instance ${instance_id} in ${availability_domain}."
        send_success_notification "$instance_id" "$availability_domain" "$private_ip" "$public_ip"
        return 0
      fi

      case "$launch_output" in
        retryable)
          log "Launch failed with a retryable capacity/transient condition in ${availability_domain}."
          ;;
        terminal)
          log "Launch failed with a terminal configuration/auth condition in ${availability_domain}."
          send_terminal_failure_notification "terminal OCI launch error in ${availability_domain}"
          exit 1
          ;;
        *)
          log "Launch returned an unexpected status: ${launch_output}"
          send_terminal_failure_notification "unexpected launch result in ${availability_domain}"
          exit 1
          ;;
      esac
    done <<< "$ads_output"

    attempt=$((attempt + 1))
    sleep_with_jitter
  done
}

main "$@"
