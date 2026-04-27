#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-onedrive-lawoffice.service}"
CONF_DIR="${CONF_DIR:-/root/.config/onedrive}"
RECOVERY_SCRIPT="${RECOVERY_SCRIPT:-/usr/local/bin/onedrive-lawoffice-recover.sh}"
LOG_LINES="${LOG_LINES:-80}"

RUN_RECOVER=0

usage() {
  cat <<'EOF'
Usage:
  onedrive-lawoffice-auth-alert.sh [--recover]

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
    printf 'OneDrive auth issue detected for %s\n' "${SERVICE_NAME}"
    printf '  ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
    printf '  CONF_DIR=%s\n' "${CONF_DIR}"
    printf '  Suggested fix: %s\n' "${RECOVERY_SCRIPT}"
    if [[ "${RUN_RECOVER}" -eq 1 ]]; then
      exec "${RECOVERY_SCRIPT}"
    fi
    exit 10
  fi

  if [[ "${active_state}" != "active" || "${sub_state}" != "running" ]]; then
    printf 'OneDrive service is not healthy: ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
    if [[ "${lock_issue}" -eq 1 ]]; then
      printf '  Recent logs include a database-lock condition.\n'
    fi
    if [[ "${segv_issue}" -eq 1 ]]; then
      printf '  Recent logs include a segmentation fault.\n'
    fi
    printf '  Suggested fix: %s --skip-reauth\n' "${RECOVERY_SCRIPT}"
    if [[ "${RUN_RECOVER}" -eq 1 ]]; then
      exec "${RECOVERY_SCRIPT}" --skip-reauth
    fi
    exit 11
  fi

  printf 'OneDrive service is healthy: ActiveState=%s SubState=%s Result=%s\n' "${active_state:-unknown}" "${sub_state:-unknown}" "${result:-unknown}"
  if [[ "${lock_issue}" -eq 1 ]]; then
    printf 'Recent logs mention a database lock, but the service is currently running.\n'
  fi
  exit 0
}

main "$@"