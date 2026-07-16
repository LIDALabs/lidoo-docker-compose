# Project audit — lidoo-docker-compose

**Date:** 2026-07-16 (re-audit)
**Branch audited:** `18.0`
**Scope:** Docker Compose Odoo stack (compose files, Dockerfile, entrypoint/command, config, `.env`, docs).
**Previous audit:** 2026-07-15 (see [git history] and the "Previously reported — now resolved" section below).

> **Big change since 2026-07-15:** the stack was substantially rewritten. It now targets **Odoo 18** end‑to‑end, uses **named volumes**, injects **all secrets from `.env`** (no secrets in git), drops the git submodule and the `enterprise/`/`l10n_ve` mounts, adds **pgAdmin**, and runs the container as **root → `setpriv` to `odoo`** so volume ownership is fixed on boot. Most of the earlier Critical/High findings are resolved. This re-audit records the **remaining** and **newly introduced** issues found in the current tree.

---

## Summary (current state)

| Severity | Count | Status |
|----------|------:|--------|
| Critical | 0 | — |
| High | 1 | ✅ fixed |
| Medium | 3 | ✅ fixed |
| Low / info | 6 | 4 fixed · 3 documented/accepted |

**Top risks now:** websocket/longpolling routed to a port nothing listens on (Traefik path), a broken `HOME` for the Odoo process after the privilege drop, `proxy_mode` trusted even on direct/local access, and file-only logging that makes `docker logs` blind.

All findings below were reproduced against the actual images (`odoo:18` = uid `100(odoo)` / gid `101(odoo)`; `curl` and `setpriv` present in the image; Odoo `server.py` inspected).

### Remediation (2026-07-16) — all confirmed against a real `docker compose` boot

| Finding | Status | Fix |
|---------|--------|-----|
| **H1** websocket on dead `:8072` | ✅ Fixed | `workers = 2` in `config/odoo.conf` → prefork mode; verified `Evented Service (longpolling) running on 0.0.0.0:8072` and a live `odoo gevent` worker process |
| **M1** `HOME=/root` after `setpriv` | ✅ Fixed | `docker/odoo-start.sh` drops privileges with `env HOME=/var/lib/odoo`; verified `HOME=/var/lib/odoo` on the odoo process |
| **M2** unconditional `proxy_mode` | ✅ Fixed | injected from `ODOO_PROXY_MODE` (`False` base / `True` in the Traefik overlay); verified in the runtime conf of both compose configs |
| **M3** file-only logging | ✅ Fixed | full stream → stdout (`docker logs`), `docker/odoo-logsplit` writes only ERROR/CRITICAL (with tracebacks) to the logfile; verified real-time stdout + error-only file + graceful shutdown with no lost lines |
| **L1** unpinned pgAdmin | ✅ Fixed | pinned `dpage/pgadmin4:9.15` |
| **L2** fragile startup `grep` | ✅ Fixed | `grep … || true` under `set -e` in `docker/odoo-start.sh` |
| **L4** build-context bloat | ✅ Fixed | `.dockerignore` excludes `addons/`, `fonts/`, `config/odoo.old.conf` |
| **L3** secret in `odoo_data` volume | ⚪ Accepted | inherent to injecting the master password at boot; file is `600`/odoo-owned |
| **L5** Postgres major-upgrade footgun | 📄 Documented | dump/restore procedure added to `README.md` §9 |
| **L6** Traefik dashboard exposure | 📄 Documented | hardening note added to `README.md` §7 |

---

## High

### H1 — `/websocket` + `/longpolling` routed to `:8072`, but no gevent worker runs (`workers` unset)

| | |
|---|---|
| **Where** | `config/odoo.conf` (no `workers` setting), `docker-compose.traefik.yaml` (`odoo-im-service` → port `8072`), `docker-compose.yaml` (publishes `20018:8072`) |
| **What** | Odoo only starts the gevent server on `gevent_port` (`8072`) in **prefork/multiprocess** mode (`workers > 0`). Confirmed in `odoo/service/server.py: start()` — `config['workers']` truthy → `PreforkServer` (which spawns the gevent process); otherwise → `ThreadedServer`, which serves **everything including `/websocket` on the main port `8069`**. No `workers` is set anywhere, so the stack runs threaded and **nothing listens on `8072`**. |
| **Impact** | Behind Traefik, `/websocket` and `/longpolling` are routed to `odoo-im-service:8072` → connection refused / 502. Discuss, live chat, bus notifications, and long-poll fall back or break. In the base (no-Traefik) compose, the published `20018→8072` mapping points at a dead port. |
| **Fix** | Set `workers = N` (N ≥ 1, e.g. `2`) in `config/odoo.conf` so prefork mode starts the gevent worker on `8072`; also set sane `limit_time_real`, `limit_memory_*`, `max_cron_threads`. (Routing `/websocket` to `8069` instead is *not* recommended — it defeats the purpose of the async port and can starve HTTP workers.) |

---

## Medium

### M1 — Odoo process runs with `HOME=/root` after `setpriv` (not writable by uid 100)

| | |
|---|---|
| **Where** | `docker-compose.yaml` odoo `command` (`exec setpriv --reuid=odoo --regid=odoo --init-groups -- /entrypoint.sh odoo`) |
| **What** | `setpriv` changes uid/gid but does **not** reset `HOME`. The parent shell runs as root, so the dropped-privilege Odoo process inherits `HOME=/root`. Reproduced: normal `odoo:18` (via `USER odoo`) gets `HOME=/var/lib/odoo`; this stack's root→`setpriv` flow yields `HOME=/root`, and uid `100` **cannot write** `/root` (`mkdir /root/.cache` → Permission denied). |
| **Impact** | Any library using `$HOME` fails or degrades: fontconfig cache (`~/.cache/fontconfig`), matplotlib (`~/.config`/`~/.cache`), `~/.local`. This stack **mounts custom fonts** (`fonts/ → /usr/share/fonts/truetype/custom_fonts`), so fontconfig cannot cache and rescans on every render — noisy warnings and slower PDF/report generation; some libs error outright. |
| **Fix** | Point `HOME` at the odoo home / data_dir (already chowned to odoo): `exec setpriv … -- env HOME=/var/lib/odoo /entrypoint.sh odoo` (optionally `USER=odoo` too). |

### M2 — `proxy_mode = True` is unconditional (trusted on direct/local access)

| | |
|---|---|
| **Where** | `config/odoo.conf` (`proxy_mode = True`) |
| **What** | `proxy_mode` is on in the base config, which is used for the documented **local / no-Traefik** path (`docker compose up` → `localhost:10018`) and for any direct hit on `8069`. With `proxy_mode` on and no trusted proxy in front, Odoo trusts client-supplied `X-Forwarded-For` / `-Host` / `-Proto`. |
| **Impact** | A direct client can spoof its source IP (falsified `remote_addr` in login/audit logging and any IP-based logic) and forge `Host` (affects generated absolute URLs / redirects). Security hardening regression whenever Odoo is reachable without Traefik. |
| **Fix** | Keep `proxy_mode` **off** in the base `odoo.conf`; enable it only on the Traefik path (a small `config/odoo.conf.local` override, an env-driven conf line, or a Traefik-only conf fragment). It is correct only when Traefik terminates TLS and sets the forwarded headers. |

### M3 — Odoo logs only to a file on a volume; `docker logs` is blind

| | |
|---|---|
| **Where** | `config/odoo.conf` (`logfile = /var/log/odoo/odoo-server.log`, `log_level = error`) |
| **What** | Odoo writes to a file on the `odoo_logs` named volume instead of stdout, and `log_level = error` suppresses everything below ERROR. |
| **Impact** | `docker compose logs -f odoo` shows almost nothing (only pre-config bootstrap). Warnings, tracebacks below ERROR, failed cron, deprecation and slow-query notices are invisible. Standard Docker log drivers and platform log aggregation (Coolify, journald, Loki, etc.) can't see Odoo output; operators must `exec … tail` a file inside a volume. |
| **Fix** | Prefer stdout logging (unset `logfile`, the image default) so Docker captures it; if a file is required, still emit to stdout as well. Consider raising `log_level` to `warn`/`info` at least during bring-up. |

---

## Low / info

### L1 — `dpage/pgadmin4:latest` is unpinned

`docker-compose.yaml`. Every other image is pinned to a major (`odoo:18`, `postgres:17`, `traefik:v3`), but pgAdmin floats to `latest`, so a re-pull can change behavior/UI and breaks reproducibility. Pin a version (e.g. `dpage/pgadmin4:8.x`).

### L2 — Entrypoint is fragile under `set -euo pipefail` if `odoo.conf` ever has no non-`admin_passwd` lines

`docker-compose.yaml` odoo `command`. The runtime-conf build does `grep -v -E '^\s*admin_passwd\s*=' /etc/odoo/odoo.conf`. If `odoo.conf` were ever empty or contained only `admin_passwd` lines, `grep -v` returns non-zero and `set -e` aborts the boot. Safe today (the current conf has many other lines) but a latent trap. Guard with `|| true` or `grep -v … ; true`.

### L3 — Master password is written into the persistent `odoo_data` volume on every boot

`docker-compose.yaml` odoo `command` writes `admin_passwd` into `/var/lib/odoo/odoo.runtime.conf` (mode `600`, owned `odoo`). Acceptable — the volume is already as sensitive as the DB — but note that the secret now lives in a persistent volume in addition to `.env`. Anyone with volume/host access can read it.

### L4 — Build-context bloat in `.dockerignore`

`.dockerignore` doesn't exclude `fonts/`, `addons/`, or `config/odoo.old.conf` (~11 KB). The Dockerfile only `COPY`s `config/requirements.txt`; everything else is bind-mounted at runtime, so these just inflate the build context. Minor. Add `fonts/`, `addons/`, `config/odoo.old.conf` (or `config/*.old.conf`) to `.dockerignore`.

### L5 — Postgres major-version upgrade footgun

`docker-compose.yaml` (`postgres:17` + `db_data`). If the tag is later bumped to `postgres:18`, PostgreSQL refuses to start on a data dir initialized by 17 (no automatic `pg_upgrade`). Not a current bug — document the dump/restore (or `pg_upgrade`) procedure in the README so a future tag bump doesn't wedge the DB.

### L6 — Traefik exposure notes (informational)

`docker-compose.traefik.yaml`. The dashboard (`api@internal`) is routed on a public host behind **HTTP basic auth only**, and `/var/run/docker.sock` is mounted read-only into Traefik (standard for the docker provider, but a well-known privilege surface). Both are acceptable defaults; for hardening, consider an IP allowlist / internal-only entrypoint for the dashboard, or not routing `api@internal` publicly at all.

---

## Previously reported — now resolved

Mapping of the 2026-07-15 findings to their current fixes (verified in this tree):

| Old ID | Old finding | Status in current tree |
|--------|-------------|------------------------|
| C1 | `data_dir = /etc/odoo` (perm failures) | **Fixed** — `data_dir = /var/lib/odoo`; boot `chown odoo:odoo /var/lib/odoo`. |
| C2 | No persistent Odoo data volume | **Fixed** — named volume `odoo_data:/var/lib/odoo` (+ `odoo_logs`). |
| C3 | Master password committed in git | **Fixed** — `admin_passwd` comes from `ODOO_ADMIN_PASSWD` (`.env`), injected at boot; not stored in `odoo.conf`/`odoo.old.conf`. |
| C4 | Branch `18.0` still deploying Odoo 17 | **Fixed** — `odoo:18`, `postgres:17`, ports `10018/20018`, image `lidoo-odoo:18`. |
| C5 / H1 | Empty submodule / enterprise mounts | **Fixed** — submodule + `enterprise/`/`l10n_ve` mounts removed; only `./addons` and `./fonts` mounted. |
| H2 | pip install on every start | **Fixed** — deps installed at image build (`Dockerfile` + `config/requirements.txt`); entrypoint no longer runs pip. |
| H3 | Dockerfile vs Compose disagree | **Fixed** — main compose `build: .`; Dockerfile is the single image source. |
| H4 | `dev_mode = reload` on | **Fixed** — not set in current `odoo.conf`. |
| H5 | Weak default DB password | **Fixed** — `POSTGRES_PASSWORD` is required (`:?` fail-fast), no insecure default. |
| H6 | `.gitignore` mismatched data paths | **Fixed** — ignores `.env`, `database/`, `postgresql/`, logs, etc. |
| H7 | `chmod 777` guidance | **Fixed** — root→`setpriv` model + boot `chown` replaces 777; scripts removed. |
| H8 | Logfile under config mount | **Partly** — moved to `odoo_logs` volume (no longer in the config mount), but still file-only, not stdout → see **M3**. |
| M1/M2/M6 | Traefik network / `/websocket` / middleware overwrite | **Mostly fixed** — network profile clean, single middleware chains, `/websocket` route added — but the target port has no listener → see **H1**. |
| M3 | `depends_on` without health | **Fixed** — `condition: service_healthy` on `db`. |
| M4 | Postgres bind mount + nested `pgdata` | **Fixed** — named volume `db_data`, `PGDATA=/var/lib/postgresql/data`. |
| M7 | `run.sh` obsolete | **Fixed** — removed. |
| M8/M9 | OCA on 17 / incomplete pip deps | **N/A now** — vendored OCA modules removed; `requirements.txt` reduced to `pandas`/`beautifulsoup4` (add pins per module you drop into `addons/`). |
| M10 | Brittle healthcheck on `/` | **Fixed** — hits `/web/login`. |
| L1/L2 | README / `.env.example` incomplete | **Fixed** — both rewritten and coherent. |
| L3 | Coolify partial subset | **N/A** — `docker-compose.coolify.yaml` removed. |
| L4 | Hardcoded Traefik basic-auth hash | **Fixed** — `TRAEFIK_BASIC_AUTH` from `.env`. |
| L5/L6 | `pre.sh` / logrotate | **Fixed/removed**. |

---

## File inventory (current)

| Path | Role | Notes |
|------|------|-------|
| `docker-compose.yaml` | Main stack | Odoo 18 (`build: .`) + Postgres 17 + pgAdmin (127.0.0.1). See **H1, M1, M2, M3, L1, L2, L3, L5**. |
| `docker-compose.traefik.yaml` | Traefik v3 overlay | TLS + hostname + dashboard. See **H1** (websocket port), **L6**. |
| `Dockerfile` | Custom image | `FROM odoo:18`; installs `requirements.txt` at build; `USER odoo` (compose overrides to root + setpriv). |
| `config/odoo.conf` | Odoo options | `data_dir`, `proxy_mode`, `logfile`, `addons_path`. See **H1, M2, M3**. |
| `config/odoo.old.conf` | Archived full conf | Reference only; confirms no secret stored. Consider excluding from build context (**L4**). |
| `config/requirements.txt` | Extra pip deps | `pandas`, `beautifulsoup4`. |
| `.env` / `.env.example` | Secrets/config | Required vars fail-fast via `:?`; template is complete. |
| `addons/`, `fonts/` | Runtime mounts | Custom modules (flat) and custom fonts. Fonts interact with **M1**. |
| `database/` | Legacy host DB dir | Root-owned, gitignored, unused (named `db_data` volume now). README documents safe removal. |

---

## Suggested fix priority

1. **H1** — set `workers ≥ 1` in `odoo.conf` so `:8072` actually serves websocket/longpolling (fixes Discuss/bus behind Traefik).
2. **M1** — pass `HOME=/var/lib/odoo` through the `setpriv` exec (fixes fontconfig/report rendering with the mounted custom fonts).
3. **M2** — make `proxy_mode` Traefik-only.
4. **M3** — log to stdout (or also to stdout) for real observability.
5. **L1–L6** — pin pgAdmin, harden the entrypoint grep, trim the build context, document the Postgres upgrade path and Traefik dashboard exposure.
