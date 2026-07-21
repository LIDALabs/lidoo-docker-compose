#!/bin/bash
# Container command for the `odoo` service.
# Runs as root (compose `user: root`) to fix volume ownership and inject the
# master password, then drops to the unprivileged `odoo` user (uid 100) for the
# server process itself.
set -euo pipefail

: "${ODOO_ADMIN_PASSWD:?ODOO_ADMIN_PASSWD must be set}"
: "${PASSWORD:?POSTGRES_PASSWORD must be set}"

DATA_DIR=/var/lib/odoo
LOG_DIR=/var/log/odoo
ERR_LOG="$LOG_DIR/odoo-server.log"
FIFO="$LOG_DIR/.stream.fifo"

# Writable locations live on named volumes; fix ownership on every boot.
mkdir -p "$DATA_DIR" "$LOG_DIR"
chown odoo:odoo "$DATA_DIR" "$LOG_DIR"

# Pre-create the error log so `tail -f` works before the first error is written.
: > "$ERR_LOG"
chown odoo:odoo "$ERR_LOG"

# Runtime config: start from the read-only odoo.conf, then inject values that
# must not live in git (master password) or that depend on the deploy:
# - proxy_mode is only safe behind a trusted reverse proxy (Traefik)
# - workers > 0 starts prefork + gevent on :8072 (needed when a proxy routes
#   /websocket and /longpolling there). Local direct access (no proxy) must
#   use workers = 0 so the threaded server can handle websockets on :8069.
# `|| true` guards against `set -e` when grep matches nothing to strip.
export ODOO_RC="$DATA_DIR/odoo.runtime.conf"
umask 077
{
  grep -v -E '^[[:space:]]*(admin_passwd|proxy_mode|workers)[[:space:]]*=' /etc/odoo/odoo.conf || true
  printf 'admin_passwd = %s\n' "$ODOO_ADMIN_PASSWD"
  printf 'proxy_mode = %s\n'   "${ODOO_PROXY_MODE:-False}"
  printf 'workers = %s\n'      "${ODOO_WORKERS:-0}"
} > "$ODOO_RC"
chown odoo:odoo "$ODOO_RC"

# Log FIFO: Odoo writes both streams here; the splitter reads and fans them out
# (all lines -> container stdout / `docker logs`; ERROR/CRITICAL -> ERR_LOG).
rm -f "$FIFO"
mkfifo "$FIFO"
chown odoo:odoo "$FIFO"

# Drop privileges. HOME must point at the odoo-owned data dir: the process runs
# as uid 100 and cannot write /root, which fontconfig / report rendering need.
DROP=(setpriv --reuid=odoo --regid=odoo --init-groups -- env HOME="$DATA_DIR")

# Start the splitter first so it is reading before Odoo opens the FIFO to write.
"${DROP[@]}" /usr/local/bin/odoo-logsplit "$ERR_LOG" < "$FIFO" &
SPLIT_PID=$!

# Official Odoo entrypoint (it execs `odoo`, so $ODOO_PID is the Odoo process).
"${DROP[@]}" /entrypoint.sh odoo > "$FIFO" 2>&1 &
ODOO_PID=$!

# Forward termination to Odoo and drain the splitter so no log line is lost on
# shutdown or crash. Re-wait if a trapped signal interrupts the first wait.
set +e
trap 'kill -TERM "$ODOO_PID" 2>/dev/null' TERM INT
while :; do
  wait "$ODOO_PID"; rc=$?
  [ "$rc" -gt 128 ] && kill -0 "$ODOO_PID" 2>/dev/null && continue
  break
done
wait "$SPLIT_PID" 2>/dev/null
exit "$rc"
