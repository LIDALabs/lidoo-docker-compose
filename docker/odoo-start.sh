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

# Writable locations live on named volumes; fix ownership on every boot.
mkdir -p "$DATA_DIR" "$LOG_DIR"
chown odoo:odoo "$DATA_DIR" "$LOG_DIR"

# Runtime config: start from the read-only odoo.conf and inject the master
# password, which must not live in git.
export ODOO_RC="$DATA_DIR/odoo.runtime.conf"
umask 077
{
  grep -v -E '^[[:space:]]*admin_passwd[[:space:]]*=' /etc/odoo/odoo.conf
  printf 'admin_passwd = %s\n' "$ODOO_ADMIN_PASSWD"
} > "$ODOO_RC"
chown odoo:odoo "$ODOO_RC"

# Drop privileges. HOME must point at the odoo-owned data dir: the process runs
# as uid 100 and cannot write /root, which fontconfig / report rendering need.
exec setpriv --reuid=odoo --regid=odoo --init-groups -- \
     env HOME="$DATA_DIR" /entrypoint.sh odoo
