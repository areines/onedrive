#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-onedrive-lawoffice.service}"
CONF_DIR="${CONF_DIR:-/root/.config/onedrive}"
SYNC_DIR="${SYNC_DIR:-/srv/onedrive-lawoffice}"
LOG_LINES="${LOG_LINES:-40}"

AUTH_RESPONSE=""
SKIP_REAUTH=0

usage() {
  cat <<'EOF'
Usage:
  onedrive-lawoffice-recover.sh [--auth-response URI] [--skip-reauth]

What it does:
  1. Stops onedrive-lawoffice.service
  2. Terminates stray onedrive/reauth processes using the same confdir
  3. Runs onedrive --reauth (interactive by default, or non-interactive with --auth-response)
  4. Restarts the service
  5. Prints status and recent journal lines

Examples:
  ./onedrive-lawoffice-recover.sh
  ./onedrive-lawoffice-recover.sh --auth-response 'https://login.microsoftonline.com/common/oauth2/nativeclient?code=...'
  ./onedrive-lawoffice-recover.sh --skip-reauth

Environment overrides:
  SERVICE_NAME, CONF_DIR, SYNC_DIR, LOG_LINES
EOF
}

log() {
  printf '[onedrive-recover] %s\n' "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    printf 'This script must be run as root.\n' >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth-response)
        [[ $# -ge 2 ]] || { printf 'Missing value for --auth-response\n' >&2; exit 2; }
        AUTH_RESPONSE="$2"
        shift 2
        ;;
      --skip-reauth)
        SKIP_REAUTH=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

stop_service() {
  log "Stopping ${SERVICE_NAME}"
  systemctl stop "${SERVICE_NAME}" || true
}

kill_stray_processes() {
  log "Terminating stray OneDrive processes for ${CONF_DIR}"
  local pids=()
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && pids+=("${pid}")
  done < <(
    ps -eo pid=,cmd= | awk -v confdir="${CONF_DIR}" '
      index($0, "onedrive --reauth") > 0 { print $1; next }
      index($0, "/usr/local/bin/onedrive") > 0 && index($0, confdir) > 0 { print $1; next }
      index($0, " onedrive --monitor") > 0 && index($0, confdir) > 0 { print $1; next }
    '
  )

  if [[ ${#pids[@]} -eq 0 ]]; then
    log "No stray processes found"
    return
  fi

  local pid
  for pid in "${pids[@]}"; do
    log "TERM ${pid}"
    kill -TERM "${pid}" 2>/dev/null || true
  done
  sleep 1
  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      log "KILL ${pid}"
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  done
}

run_reauth() {
  if [[ "${SKIP_REAUTH}" -eq 1 ]]; then
    log "Skipping reauth by request"
    return
  fi

  log "Running OneDrive reauth using ${CONF_DIR}"
  local output
  if [[ -n "${AUTH_RESPONSE}" ]]; then
    output="$({ printf '%s\n' "${AUTH_RESPONSE}"; } | onedrive --confdir="${CONF_DIR}" --reauth 2>&1)"
  else
    onedrive --confdir="${CONF_DIR}" --reauth
    return
  fi

  printf '%s\n' "${output}"

  if grep -qi 'provided authorization code or refresh token has expired' <<<"${output}"; then
    printf 'Authorization code expired before redemption. Start a fresh reauth and retry.\n' >&2
    exit 3
  fi

  if grep -qi 'successfully authorised' <<<"${output}"; then
    log "Reauth completed successfully"
    return
  fi

  if grep -qi 'database is currently locked' <<<"${output}"; then
    log "Reauth succeeded but the database was locked during cleanup"
    return
  fi

  if grep -qi 'need to issue a --reauth' <<<"${output}"; then
    printf 'OneDrive still requires reauth. See output above.\n' >&2
    exit 4
  fi
}

start_service() {
  log "Starting ${SERVICE_NAME}"
  systemctl start "${SERVICE_NAME}"
}

show_status() {
  log "Service state"
  systemctl is-active "${SERVICE_NAME}" || true
  systemctl show "${SERVICE_NAME}" -p ActiveState -p SubState -p Result -p MainPID -p NRestarts || true
  journalctl -u "${SERVICE_NAME}" --no-pager -n "${LOG_LINES}" | tail -n "${LOG_LINES}" || true
}

main() {
  require_root
  parse_args "$@"
  stop_service
  kill_stray_processes
  run_reauth
  kill_stray_processes
  start_service
  show_status
}

main "$@"