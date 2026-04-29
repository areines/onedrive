#!/usr/bin/env bash
set -euo pipefail

ALERT_SCRIPT="${ALERT_SCRIPT:-/usr/local/bin/onedrive-lawoffice-auth-alert.sh}"
SIGNAL_API_BASE="${SIGNAL_API_BASE:-http://127.0.0.1:9080}"
SIGNAL_SOURCE_NUMBER="${SIGNAL_SOURCE_NUMBER:-}"
SIGNAL_RECIPIENTS="${SIGNAL_RECIPIENTS:-}"
STATE_DIR="${STATE_DIR:-/var/lib/onedrive-lawoffice-alert}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/last-status}"
RENOTIFY_SECONDS="${RENOTIFY_SECONDS:-21600}"
NOTIFY_ON_RECOVERY="${NOTIFY_ON_RECOVERY:-true}"

log() {
  printf '[onedrive-signal-notify] %s\n' "$*"
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

csv_to_json_array() {
  local raw="$1"
  local first=1
  printf '['
  IFS=',' read -r -a items <<< "$raw"
  local item cleaned
  for item in "${items[@]}"; do
    cleaned="$(trim "$item")"
    [[ -z "$cleaned" ]] && continue
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    python3 - <<'PY' "$cleaned"
import json, sys
print(json.dumps(sys.argv[1]), end="")
PY
    first=0
  done
  printf ']'
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

load_state() {
  LAST_STATUS=""
  LAST_HASH=""
  LAST_SENT_EPOCH=0
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  cat > "$STATE_FILE" <<EOF
LAST_STATUS='${CURRENT_STATUS}'
LAST_HASH='${CURRENT_HASH}'
LAST_SENT_EPOCH='${CURRENT_EPOCH}'
EOF
}

send_signal_message() {
  local message="$1"
  if [[ -z "$SIGNAL_SOURCE_NUMBER" || -z "$SIGNAL_RECIPIENTS" ]]; then
    log "Signal delivery not configured; set SIGNAL_SOURCE_NUMBER and SIGNAL_RECIPIENTS"
    printf '%s\n' "$message"
    return 0
  fi

  local recipients_json
  recipients_json="$(csv_to_json_array "$SIGNAL_RECIPIENTS")"
  python3 - <<'PY' "$message" "$SIGNAL_SOURCE_NUMBER" "$recipients_json" > /tmp/onedrive-lawoffice-signal-payload.json
import json, sys
message = sys.argv[1]
source = sys.argv[2]
recipients = json.loads(sys.argv[3])
print(json.dumps({"message": message, "number": source, "recipients": recipients}))
PY
  curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    --data @/tmp/onedrive-lawoffice-signal-payload.json \
    "${SIGNAL_API_BASE}/v2/send" >/dev/null
  rm -f /tmp/onedrive-lawoffice-signal-payload.json
  log "Sent Signal alert"
}

main() {
  ensure_state_dir
  load_state

  local output status
  if output="$($ALERT_SCRIPT --signal-format --quiet-ok 2>&1)"; then
    status="ok"
  else
    status="alert"
  fi

  local message
  message="$(trim "$output")"
  local now
  now="$(date +%s)"
  local hash_input
  hash_input="${status}::${message}"
  local hash_value
  hash_value="$(printf '%s' "$hash_input" | sha256sum | awk '{print $1}')"

  CURRENT_STATUS="$status"
  CURRENT_HASH="$hash_value"
  CURRENT_EPOCH="$now"

  if [[ "$status" == "ok" ]]; then
    if [[ "${NOTIFY_ON_RECOVERY}" == "true" && "${LAST_STATUS:-}" == "alert" ]]; then
      send_signal_message "OneDrive sync is OK on VPS:\no service recovered and is active running"
    fi
    save_state
    exit 0
  fi

  local should_send=0
  if [[ "${LAST_STATUS:-}" != "alert" || "${LAST_HASH:-}" != "$hash_value" ]]; then
    should_send=1
  elif (( now - ${LAST_SENT_EPOCH:-0} >= RENOTIFY_SECONDS )); then
    should_send=1
  fi

  if [[ "$should_send" -eq 1 ]]; then
    send_signal_message "$message"
    save_state
  else
    log "Alert unchanged; skipping duplicate Signal notification"
  fi

  exit 0
}

main "$@"