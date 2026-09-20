# Sourced by other scripts. Strips CR so Windows .env files work on Linux.
# Later files override earlier ones: .env then host.auto.env (detect-hw wins).
_load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$f")
  set +a
}

_load_env_file "${ROOT}/.env"
_load_env_file "${ROOT}/host.auto.env"
