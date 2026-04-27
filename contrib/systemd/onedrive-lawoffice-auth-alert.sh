#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-onedrive-lawoffice.service}"
CONF_DIR="${CONF_DIR:-/root/.config/onedrive}"
RECOVERY_SCRIPT="${RECOVERY_SCRIPT:-/usr/local/bin/onedrive-lawoffice-recover.sh}"
LOG_LINES="${LOG_LINES:-80}"

RUN_RECOVER=0
SIGNAL_FORMAT=0
QUIET_OK=0

usage() {
  cat <<'EOF'
Usage:
  onedrive-lawoffice-auth-alert.sh [--recover] [--signal-format] [--quiet-ok]

What it does:
  1. Checks the OneDrive service state
  2. Inspects recent journal lines for MFA/auth-expiry and lock signatures
  3. Prints a concise status with recovery guidance
  4. Optionally launches the recovery helper when --recover is supplied

Environment overrides:
  SERVICE_NAME, CONF_DIR, RECOVERY_SCRIPT, LOG_LINES
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recover)
        RUN_RECOVER=1
        shift
        ;;
      --signal-format)
        SIGNAL_FORMAT=1
        shift
        ;;
      --quiet-ok)
        QUIET_OK=1
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

print_signal_down() {
  local detail_lines=("$@")
  printf 'OneDrive sync is DOWN on VPS:\n'
  local line
  for line in "${detail_lines[@]}"; do
    printf 'o %s\n' "${line}"
  done
  printf 'Fix: %s\n' "${RECOVERY_SCRIPT}"
}

print_signal_ok() {
  printf 'OneDrive sync is OK on VPS:\n'
  printf 'o service is active running\n'
}

service_field() {
  local key="$1"
  systemctl show "${SERVICE_NAME}" -p "${key}" --value 2>/dev/null || true
}

main() {
  parse_args "$@"

  local active_state sub_state result
  active_state="$(service_field ActiveState)"
  sub_state="$(service_field SubState)"
  result="$(service_field Result)"

  local recent_logs
  recent_logs="$(journalctl -u "${SERVICE_NAME}" --no-pager -n "${LOG_LINES}" 2>/dev/null || true)"

  local auth_issue=0
  local lock_issue=0
  local segv_issue=0

  if grep -Eqi 'AADSTS50078|AADSTS70008|AADSTS50173|need to issue a --reauth|Authentication scope needs to be updated|refresh_token may be empty or invalid' <<<"${recent_logs}"; then
    auth_issue=1
  fi
  if grep -Eqi 'database is currently locked|database is locked|Unable to perform a database checkpoint: database is locked' <<<"${recent_logs}"; then
    lock_issue=1
  fi
  if grep -Eqi 'Segmentation fault|SIGSEGV' <<<"${recent_logs}"; then
    segv_issue=1
  fi

  if [[ "${auth_issue}" -eq 1 ]]; then
    if [[ "${SIGNAL_FORMAT}" -eq 1 ]]; then
      print_signal_down \
        "service is ${active_state:-unknown} ${sub_state:-unknown} (${result:-unknown})" \
        "auth token expired - needs --reauth" \
        "confdir ${CONF_DIR}"
    else
      printf 'OneDrive auth issue detected for %s\n' "${SERVICE_NAME}"
      printf '  ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
      printf '  CONF_DIR=%s\n' "${CONF_DIR}"
      printf '  Suggested fix: %s\n' "${RECOVERY_SCRIPT}"
    fi
    if [[ "${RUN_RECOVER}" -eq 1 ]]; then
      exec "${RECOVERY_SCRIPT}"
    fi
    exit 10
  fi

  if [[ "${active_state}" != "active" || "${sub_state}" != "running" ]]; then
    if [[ "${SIGNAL_FORMAT}" -eq 1 ]]; then
      local details=("service is ${active_state:-unknown} ${sub_state:-unknown} (${result:-unknown})")
      if [[ "${lock_issue}" -eq 1 ]]; then
        details+=("database lock detected")
      fi
      if [[ "${segv_issue}" -eq 1 ]]; then
        details+=("segmentation fault detected")
      fi
      print_signal_down "${details[@]}"
    else
      printf 'OneDrive service is not healthy: ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
      if [[ "${lock_issue}" -eq 1 ]]; then
        printf '  Recent logs include a database-lock condition.\n'
      fi
      if [[ "${segv_issue}" -eq 1 ]]; then
        printf '  Recent logs include a segmentation fault.\n'
      fi
      printf '  Suggested fix: %s --skip-reauth\n' "${RECOVERY_SCRIPT}"
    fi
    if [[ "${RUN_RECOVER}" -eq 1 ]]; then
      exec "${RECOVERY_SCRIPT}" --skip-reauth
    fi
    exit 11
  fi

  if [[ "${QUIET_OK}" -eq 0 ]]; then
    if [[ "${SIGNAL_FORMAT}" -eq 1 ]]; then
      print_signal_ok
      if [[ "${lock_issue}" -eq 1 ]]; then
        printf 'o recent logs mention a database lock, but service recovered\n'
      fi
    else
      printf 'OneDrive service is healthy: ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
      if [[ "${lock_issue}" -eq 1 ]]; then
        printf 'Recent logs mention a database lock, but the service is currently running.\n'
      fi
    fi
  fi
  exit 0
}

main "$@"