#!/usr/bin/env bash
# Run Carnap on this computer from the prebuilt image, with its own Postgres.
# Usage: ./carnap.sh setup | up | down | status | logs [N] | admin EMAIL | update | autostart on|off
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ENV_FILE="$HERE/.env"
NAME=${CARNAP_NAME:-carnap}
DB=$NAME-db
APP=$NAME-app
IMAGE=ghcr.io/carnap/carnap/carnap:latest
# Pinned: an existing database cannot move to a new Postgres major version
# without a dump and restore.
PG_IMAGE=docker.io/library/postgres:13

if [ -n "${CARNAP_ENGINE:-}" ]; then ENGINE=$CARNAP_ENGINE
elif command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "Install podman or docker first." >&2; exit 1
fi

e()       { "$ENGINE" "$@"; }
exists()  { e container inspect "$1" >/dev/null 2>&1; }
running() { [ "$(e inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
usage()   { sed -n '2,3p' "$0" >&2; exit 1; }
retry()   { local n; for n in 1 2 3 4 5; do "$@" && return; sleep 2; done; return 1; }

load_env() {
  [ -f "$ENV_FILE" ] || { echo "No settings yet. Run: $0 setup" >&2; exit 1; }
  set -a; . "$ENV_FILE"; set +a
  PORT=${PORT:-3000}
  AUTOSTART=${AUTOSTART:-no}
  # Passed to the containers by name (-e VAR), so secrets stay off the command line.
  export APPROOT="http://localhost:$PORT" GOOGLEKEY="${GOOGLEKEY:-}" GOOGLESECRET="${GOOGLESECRET:-}" \
    SQLITE=false PGHOST=localhost PGUSER=carnap PGDATABASE=carnap PGPASS="$DB_PASSWORD" \
    POSTGRES_USER=carnap POSTGRES_DB=carnap POSTGRES_PASSWORD="$DB_PASSWORD"
}

google_steps() {
  cat <<EOF
Google sign-in, one-off (the same client works on every computer):
  1. Open https://console.cloud.google.com/apis/credentials in any Google Cloud project.
  2. If Google asks you to set up the consent screen first: audience External,
     app name Carnap, your email, and add your own Google address as a test user.
  3. Create credentials, OAuth client ID, type Web application.
  4. Authorised redirect URI: http://localhost:${1:-3000}/auth/page/google/callback
  5. Copy the client ID and client secret.
EOF
}

setup() {
  if [ -f "$ENV_FILE" ]; then
    echo "Settings already exist in $ENV_FILE; starting Carnap with them."
  else
    local key="" secret="" pw
    google_steps 3000
    if [ -t 0 ]; then
      echo
      read -rp "Client ID (Enter to skip for now): " key
      if [ -n "$key" ]; then read -rsp "Client secret: " secret; echo; fi
    fi
    pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
    (umask 077; cat >"$ENV_FILE" <<EOF
# Settings for carnap.sh. Private: holds secrets and is not committed.

# Carnap answers on http://localhost:PORT, from this computer only.
# Changing it means changing the Google redirect URI too.
PORT=3000

# Google OAuth client (Web application). Authorised redirect URI:
#   http://localhost:3000/auth/page/google/callback
GOOGLEKEY=$key
GOOGLESECRET=$secret

# Start Carnap when you log in. Change with: ./carnap.sh autostart on|off
AUTOSTART=no

# Generated. Changing it after the first start breaks the database login.
DB_PASSWORD=$pw
EOF
    )
    echo "Wrote $ENV_FILE"
  fi
  up
}

up() {
  load_env
  local policy=no
  [ "$AUTOSTART" = yes ] && policy=always

  # Carnap joins the database container's network, like a pod, so it reaches
  # Postgres on localhost and needs no container DNS. The port is therefore
  # published on the database container, which is recreated only when the port
  # or autostart setting changes. Data lives in the volumes either way.
  local want="$PORT/$policy"
  e rm -f "$APP" >/dev/null 2>&1 || true
  if ! exists "$DB" || [ "$(e inspect -f '{{index .Config.Labels "carnap.config"}}' "$DB")" != "$want" ]; then
    if exists "$DB"; then e stop -t 30 "$DB" >/dev/null; e rm "$DB" >/dev/null; fi
    e create --name "$DB" --label "carnap.config=$want" --restart "$policy" -p "127.0.0.1:$PORT:3000" \
      -e POSTGRES_USER -e POSTGRES_DB -e POSTGRES_PASSWORD \
      -v "${NAME}_pgdata:/var/lib/postgresql/data" "$PG_IMAGE" >/dev/null
  fi
  # A container stopped a moment ago can still hold the port, so retry briefly.
  retry e start "$DB" >/dev/null 2>&1 || { e start "$DB" >/dev/null; exit 1; }

  echo "Waiting for the database..."
  local ok=""
  for _ in $(seq 1 60); do
    e exec "$DB" pg_isready -q -U carnap 2>/dev/null && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { echo "Database did not start. Try: $ENGINE logs $DB" >&2; exit 1; }

  e run -d --name "$APP" --network "container:$DB" --restart "$policy" \
    -e APPROOT -e GOOGLEKEY -e GOOGLESECRET -e SQLITE \
    -e PGHOST -e PGUSER -e PGPASS -e PGDATABASE \
    -v "${NAME}_data:/data" "$IMAGE" >/dev/null

  if command -v curl >/dev/null; then
    echo "Waiting for Carnap..."
    for _ in $(seq 1 60); do
      if curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then ok=2; break; fi
      running "$APP" || break
      sleep 2
    done
    if [ "$ok" != 2 ]; then
      echo "Carnap did not come up. Last log lines:" >&2
      e logs --tail 20 "$APP" >&2
      exit 1
    fi
  fi

  echo "Carnap is running: http://localhost:$PORT  (book: http://localhost:$PORT/book)"
  if [ -z "$GOOGLEKEY" ]; then
    echo
    echo "Sign-in is not set up yet; the book works without it."
    google_steps "$PORT"
    echo "  6. Put them in GOOGLEKEY and GOOGLESECRET in $ENV_FILE, then run: $0 up"
  fi
}

down()   { e stop -t 2 "$APP" >/dev/null 2>&1 || true; e stop "$DB" >/dev/null 2>&1 || true; echo "Carnap stopped."; }
status() { e ps -a --filter "name=$DB" --filter "name=$APP" --format 'table {{.Names}}\t{{.Status}}'; }
logs()   { e logs --tail "${1:-50}" "$APP"; }
update() { e pull "$IMAGE"; up; }

admin() {
  [ -n "${1:-}" ] || usage
  running "$DB" || { echo "Carnap is not running. Run: $0 up" >&2; exit 1; }
  e exec -i "$DB" psql -q -o /dev/null -v ON_ERROR_STOP=1 -v VERBOSITY=terse -v email="$1" -U carnap -d carnap <<'SQL'
SELECT set_config('carnap.email', :'email', false);
DO $$
DECLARE d user_data%ROWTYPE;
BEGIN
  SELECT ud.* INTO d FROM user_data ud JOIN "user" u ON u.id = ud.user_id
   WHERE u.ident = current_setting('carnap.email');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No account for %. Sign in once and finish the registration form, then run this again.',
      current_setting('carnap.email');
  END IF;
  IF d.instructor_id IS NULL THEN
    INSERT INTO instructor_metadata DEFAULT VALUES RETURNING id INTO d.instructor_id;
  END IF;
  UPDATE user_data SET is_admin = true, instructor_id = d.instructor_id WHERE id = d.id;
END $$;
SQL
  echo "$1 is now admin and instructor."
}

autostart() {
  local v
  case "${1:-}" in on) v=yes ;; off) v=no ;; *) usage ;; esac
  load_env
  if grep -q '^AUTOSTART=' "$ENV_FILE"; then
    sed "s/^AUTOSTART=.*/AUTOSTART=$v/" "$ENV_FILE" >"$ENV_FILE.tmp"
  else
    { cat "$ENV_FILE"; echo "AUTOSTART=$v"; } >"$ENV_FILE.tmp"
  fi
  chmod 600 "$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"
  # Rootless podman has no daemon; this user service starts restart=always containers at login.
  if [ "$v" = yes ] && [ "$ENGINE" = podman ] && command -v systemctl >/dev/null; then
    systemctl --user enable podman-restart.service >/dev/null 2>&1 || true
  fi
  up
  echo "Autostart: $v"
}

cmd=${1:-}; shift || true
case "$cmd" in
  setup|up|down|status|logs|admin|update|autostart) "$cmd" "$@" ;;
  *) usage ;;
esac
