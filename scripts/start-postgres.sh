#!/usr/bin/env bash
# Postgres + pgvector on the host (no Docker). Used by start-stack.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/_env.sh"

PGUSER="${POSTGRES_USER:-nexus}"
PGPASSWORD_VALUE="${POSTGRES_PASSWORD:-nexus}"
PGDB="${POSTGRES_DB:-nexus}"
SQL="$ROOT/sql/01-init.sql"

if [[ "${1:-}" == "stop" ]]; then
  sudo pg_ctlcluster --skip-systemctl-redirect 16 main stop || sudo service postgresql stop || true
  echo "postgres stopped"
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib postgresql-16-pgvector
fi

sudo pg_ctlcluster --skip-systemctl-redirect 16 main start 2>/dev/null || \
  sudo service postgresql start || true

# Cloud VMs often have no systemd; wait until the socket answers.
for i in $(seq 1 30); do
  if sudo -u postgres pg_isready -q; then
    break
  fi
  sleep 1
done
sudo -u postgres pg_isready

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PGUSER}') THEN
    CREATE ROLE ${PGUSER} LOGIN PASSWORD '${PGPASSWORD_VALUE}';
  ELSE
    ALTER ROLE ${PGUSER} WITH LOGIN PASSWORD '${PGPASSWORD_VALUE}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${PGDB} OWNER ${PGUSER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${PGDB}')
\gexec
GRANT ALL PRIVILEGES ON DATABASE ${PGDB} TO ${PGUSER};
SQL

# pgvector + chunks. Superuser is required for CREATE EXTENSION.
# Feed SQL on stdin: postgres cannot read files under a 0700/0750 home directory.
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 < "$SQL"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "ALTER TABLE IF EXISTS chunks OWNER TO ${PGUSER};"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO ${PGUSER};"
sudo -u postgres psql -d "$PGDB" -v ON_ERROR_STOP=1 -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO ${PGUSER};"

# Allow password auth from localhost for the app role.
HBA="/etc/postgresql/16/main/pg_hba.conf"
if [[ -f "$HBA" ]] && ! sudo grep -q "localnexus-md5" "$HBA"; then
  sudo tee -a "$HBA" >/dev/null <<'EOF'
# localnexus-md5
host    nexus           nexus           127.0.0.1/32            scram-sha-256
host    nexus           nexus           ::1/128                 scram-sha-256
EOF
  sudo pg_ctlcluster --skip-systemctl-redirect 16 main reload || sudo -u postgres psql -c "SELECT pg_reload_conf();"
fi

export PGPASSWORD="$PGPASSWORD_VALUE"
psql -h 127.0.0.1 -U "$PGUSER" -d "$PGDB" -c "SELECT extname FROM pg_extension WHERE extname = 'vector';"
echo "postgres ready on 127.0.0.1:5432 db=$PGDB"
