# Design: Odoo 18 Docker stack redesign

**Date:** 2026-07-15  
**Status:** Draft for review  
**Branch context:** `18.0`  
**Related:** [`audits.md`](../../../audits.md) (canonical audit log at repo root)

---

# Part 1 — Project audit

**Scope:** Docker Compose Odoo stack (compose files, Dockerfile, entrypoint, config, scripts, docs, git layout).  
**Note at audit time:** Branch is named `18.0` but the stack still targets **Odoo 17** end-to-end.

## 1.1 Summary

| Severity | Count |
|----------|------:|
| Critical | 5 |
| High | 8 |
| Medium | 10 |
| Low / docs | 6 |

**Top risks for production:** wrong `data_dir` (session permission failures), no durable Odoo filestore volume, secrets committed to git, empty/broken addon mounts via submodule, and version drift (17 vs 18).

## 1.2 Critical

### C1 — `data_dir` points at the config bind mount

| | |
|---|---|
| **Where** | `config/odoo.conf` (`data_dir = /etc/odoo`) |
| **What** | Odoo stores sessions, filestore, and other runtime data under `data_dir`. Compose mounts `./config:/etc/odoo`, so the container user often cannot write sessions. |
| **Impact** | Runtime failure: `PermissionError: [Errno 13] Permission denied: '/etc/odoo/sessions'`. |
| **Expected** | `data_dir = /var/lib/odoo`, with a persistent volume on that path. |
| **Design** | Fixed in Part 2 (`data_dir` + named volume `odoo-data`). |

### C2 — No persistent volume for Odoo data (`/var/lib/odoo`)

| | |
|---|---|
| **Where** | `docker-compose.yaml` (odoo service volumes) |
| **What** | Only config, addons, fonts, and entrypoint are mounted. No volume for `/var/lib/odoo`. |
| **Impact** | Filestore/sessions not reliably persisted across container recreate. |
| **Expected** | Named volume for `/var/lib/odoo`. |
| **Design** | Named volume `odoo-data`. |

### C3 — Master password committed in plain text

| | |
|---|---|
| **Where** | `config/odoo.conf` (`admin_passwd`) |
| **What** | Database manager master password stored in the repo. |
| **Impact** | Anyone with repo access can manage databases via `/web/database`. |
| **Expected** | Placeholder in git; real secret only in untracked local config or operator-set value. |
| **Design** | Replace with placeholder; document setting a real password locally. |

### C4 — Version mismatch: branch `18.0` still deploys Odoo 17

| | |
|---|---|
| **Where** | Compose (`odoo:17`, service `odoo17`), Dockerfile, Makefile, Coolify, submodule `17.0-lida`, OCA `17.0.*` |
| **What** | Naming claims 18; runtime and modules are 17. |
| **Impact** | Misleading branch, broken upgrade planning. |
| **Expected** | Align stack to Odoo 18. |
| **Design** | `FROM odoo:18`, service rename, drop 17-only paths. |

### C5 — Addon mounts empty or not checked out

| | |
|---|---|
| **Where** | `l10n_ve` submodule (not initialized), empty `enterprise/` |
| **What** | Submodule/empty dirs mounted as addon roots. |
| **Impact** | Missing modules at runtime. |
| **Expected** | Stack does not depend on submodules; operator supplies modules under `addons/`. |
| **Design** | Remove submodule; single flat `addons/` mount. |

## 1.3 High

### H1 — Git submodule couples stack to addon repos

| | |
|---|---|
| **Where** | `.gitmodules` → `l10n_ve` |
| **Design** | Remove submodule; place modules flat under `addons/` when needed. |

### H2 — `entrypoint.sh` reinstalls Python packages on every start

| | |
|---|---|
| **Where** | `entrypoint.sh` (`pip3 install` every boot) |
| **Design** | Delete custom entrypoint; install deps only in Dockerfile; use official image entrypoint. |

### H3 — Dockerfile and Compose disagree

| | |
|---|---|
| **Where** | Main compose used `image: odoo:17` (ignored Dockerfile); Coolify built incomplete image; ENTRYPOINT without COPY of entrypoint |
| **Design** | Compose always `build: .` thin Dockerfile; no custom ENTRYPOINT; Coolify file removed. |

### H4 — `dev_mode = reload` enabled

| | |
|---|---|
| **Design** | Off by default in `odoo.conf`. |

### H5 — Weak default database credentials

| | |
|---|---|
| **Where** | Defaults like `supersecret` |
| **Design** | Credentials from `.env`; `.env.example` uses placeholders only. |

### H6 — `.gitignore` does not match real data paths

| | |
|---|---|
| **Where** | Ignores `postgresql/`; data used `./database` |
| **Design** | Fix ignores (`.env`, legacy `database/`, etc.). |

### H7 — World-writable permissions in setup scripts and docs

| | |
|---|---|
| **Where** | `pre.sh`, README `chmod 777` |
| **Design** | Delete `pre.sh` / `run.sh`; README without 777. |

### H8 — Logfile under config mount

| | |
|---|---|
| **Where** | `logfile = /etc/odoo/odoo-server.log` |
| **Design** | Unset logfile; log to stdout (Docker logs). |

## 1.4 Medium

| ID | Issue | Design response |
|----|--------|-----------------|
| M1 | Traefik network half-wired | Base + Traefik overlay; Odoo on `traefik-public` when overlay used |
| M2 | Only `/longpolling`, missing `/websocket` | Route both to port 8072 |
| M3 | `depends_on` without health | `condition: service_healthy` on db |
| M4 | Awkward Postgres host bind / root ownership | Named volume `db-data` |
| M5 | `addons_path` multi-mount + nested packs | Single `/mnt/extra_addons`, flat modules only |
| M6 | Traefik dashboard middleware label overwrite | Single middleware chain |
| M7 | `run.sh` obsolete | Delete |
| M8 | OCA modules still 17.0 | Not mounted from repo root; operator places 18-compatible modules under `addons/` |
| M9 | Incomplete Python deps for tools | `requirements.txt` installed at **image build**; align pins with modules used |
| M10 | Brittle healthcheck on `/` | Prefer a more stable path (e.g. `/web/login`) |

## 1.5 Low / documentation

| ID | Issue | Design response |
|----|--------|-----------------|
| L1 | README incomplete / unsafe | Rewrite for stack-only ops |
| L2 | `.env.example` incomplete | Full placeholders |
| L3 | Coolify compose partial | Remove Coolify from scope |
| L4 | Hardcoded Traefik basic-auth | Prefer env-driven where practical |
| L5 | `pre.sh` unsafe | Delete |
| L6 | Logrotate disconnected | Prefer stdout; logrotate optional/low priority |

## 1.6 File inventory (audit-time)

| Path | Role | Notes |
|------|------|--------|
| `docker-compose.yaml` | Main stack | 17 image, no filestore volume, Traefik half-wired |
| `docker-compose.traefik.yaml` | Traefik | Middleware overwrite; external network |
| `docker-compose.coolify.yaml` | Coolify | Out of scope → remove |
| `Dockerfile` | Custom image | Needed for pip deps; must be used via `build` |
| `entrypoint.sh` | Custom start | pip every boot → remove |
| `config/odoo.conf` | Options | data_dir, secrets, dev_mode issues |
| `pre.sh` / `run.sh` | Host/install | Remove |
| `.gitmodules` / `l10n_ve` | Submodule | Remove |

---

# Part 2 — Design

## 2.1 Goals

1. Run **Odoo 18** via Docker Compose as a **stack-only** deploy (no git submodules for app code).
2. **Flat** custom modules under a single host mount: `./addons` → `/mnt/extra_addons`.
3. **Local + Traefik** first-class; **Coolify out**.
4. **pgAdmin** on **localhost only** (no Traefik for DB UI).
5. **Extra Python packages** required by modules: install via **thin Dockerfile** at build time (not at container start).
6. Fix audit findings that affect correctness, security, and operability of the stack.
7. **Scope A:** stack only — no backup/restore scripts, no 17→18 migration guide or upgrade engine in this work.

## 2.2 Non-goals

- Automatic database upgrade 17 → 18 (official / OpenUpgrade / DIY left to operators later).
- Backup/restore automation or `backups/` tooling.
- Coolify deployment file.
- Nested addon groups (`addons/l10n_ve/module`) or auto-scan of group paths.
- pgAdmin exposed on the public internet or via Traefik.
- Reimplementing `pre.sh`, `run.sh`, or a custom `entrypoint.sh`.

## 2.3 Decisions (locked)

| Topic | Decision |
|--------|----------|
| Approach | Single base compose + Traefik overlay (Approach 1) |
| Addons layout | **Flat only** under `addons/<module>/` |
| Addons mounts | **Only** `./addons` → `/mnt/extra_addons` |
| Image | **Build** thin image from `odoo:18` + `requirements.txt` |
| Entrypoint | **Official** image entrypoint only |
| Scripts | **Remove** `entrypoint.sh`, `pre.sh`, `run.sh` |
| Environments | Local + Traefik; no Coolify |
| pgAdmin | `127.0.0.1:5050` (configurable port); no Traefik |
| Migration tooling | Out of scope |
| Backup tooling | Out of scope |

## 2.4 Architecture

### Local (default)

```text
Browser ──► host:8069 (etc.) ──► odoo
Browser ──► 127.0.0.1:5050 ──► pgadmin ──► db:5432
                 odoo ───────────────────► db:5432
```

### With Traefik overlay

```text
Internet ──► :80/:443 ──► traefik ──► odoo:8069
                              └── websocket/longpolling ──► odoo:8072
pgadmin remains on 127.0.0.1 only
```

### Services

| Service | How built/run | Role |
|---------|----------------|------|
| `odoo` | `build: .` from Dockerfile (`FROM odoo:18`) | Application |
| `db` | `postgres:17` | Database |
| `pgadmin` | `dpage/pgadmin4` | Local DB UI |
| `traefik` | `traefik:v3` in overlay only | Reverse proxy + TLS |

### Networks

| Network | Purpose |
|---------|---------|
| `intranet` | odoo, db, pgadmin |
| `traefik-public` | traefik + odoo when overlay is used |

### Volumes / mounts

| Name / path | Target | Purpose |
|-------------|--------|---------|
| `./addons` | `/mnt/extra_addons` | Flat custom Odoo modules |
| `./config/odoo.conf` | `/etc/odoo/odoo.conf` (ro preferred) | Odoo config |
| `./fonts` (optional) | custom fonts path | Keep only if still required |
| `odoo-data` (named) | `/var/lib/odoo` | `data_dir`: sessions, filestore |
| `db-data` (named) | Postgres data directory | DB persistence |

No separate mounts for `enterprise/`, `l10n_ve/`, or `oca-tools/`.

### Operator commands

```bash
# Local
cp .env.example .env   # set secrets
# place modules under addons/<module_name>/
docker compose up -d --build

# Production-style with Traefik
docker compose -f docker-compose.yaml -f docker-compose.traefik.yaml up -d --build
```

## 2.5 Components

### Dockerfile (thin)

```text
FROM odoo:18
USER root
COPY config/requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt
USER odoo
# Do NOT set custom ENTRYPOINT — inherit official image entrypoint
```

- **Do not** bake host `addons/` as the source of truth (bind mount supplies modules).
- **Do not** reintroduce pip-on-start.

### `docker-compose.yaml`

**odoo**

- `build: .`
- `depends_on: db` with `condition: service_healthy`
- Environment: `HOST=db`, `USER`/`PASSWORD` from Postgres env (official entrypoint)
- Ports: HTTP and gevent (e.g. `8069`, `8072`) — overridable via `.env`
- Volumes: addons, odoo.conf, `odoo-data`, optional fonts
- Traefik labels: app on 8069; `/websocket` and `/longpolling` on 8072; optional `traefik.enable` gated by env for quiet local use
- No entrypoint override

**db**

- Image `postgres:17`
- Named volume `db-data`
- Healthcheck: `pg_isready`
- User/password/db from `.env` (no insecure hardcoded production default in example)

**pgadmin**

- Ports: `127.0.0.1:${PGADMIN_PORT:-5050}:80`
- Default login from `.env`
- Network: `intranet` only
- No Traefik labels
- Operator adds server in UI: host `db`, port `5432`, same credentials as Postgres

### `docker-compose.traefik.yaml`

- Traefik service, entrypoints web/websecure, Let's Encrypt HTTP challenge
- Network `traefik-public` (document external vs created — wiring must make Odoo reachable)
- Fix dashboard middleware (single chain; no overwriting labels)
- Credentials for dashboard from env when practical
- No pgAdmin routes

### `config/odoo.conf`

| Setting | Value |
|---------|--------|
| `addons_path` | Core Odoo 18 addons path + `/mnt/extra_addons` |
| `data_dir` | `/var/lib/odoo` |
| `proxy_mode` | `True` |
| `dev_mode` | unset / off |
| `logfile` | unset (stdout) |
| `admin_passwd` | placeholder only in git |

Confirm core addons filesystem path against the official `odoo:18` image at implementation time (commonly under `/usr/lib/python3/dist-packages/odoo/addons`).

DB host/user/password: supplied by official entrypoint from environment, not stored as real secrets in git.

### `config/requirements.txt`

- Retain packages modules need (e.g. pandas, beautifulsoup4).
- Add pins required by modules actually used under `addons/` (e.g. xlsxwriter if report_xlsx is deployed).
- Installed only at image build.

### Environment (`.env.example`)

- `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `ODOO_HOSTNAME`
- `LETS_ENCRYPT_CONTACT_EMAIL`
- `PGADMIN_DEFAULT_EMAIL`, `PGADMIN_DEFAULT_PASSWORD`
- Optional: `ODOO_HTTP_PORT`, `ODOO_GEVENT_PORT`, `PGADMIN_PORT`, Traefik dashboard auth, `TRAEFIK_ENABLE`

### README

Minimal ops only:

1. Copy `.env.example` → `.env` and set secrets  
2. Place Odoo modules flat in `addons/`  
3. `docker compose up -d --build`  
4. Traefik two-file command  
5. pgAdmin at `http://127.0.0.1:5050`  
6. Note that the custom image is required for Python dependencies  

No migration chapter, no backup chapter, no `chmod 777`.

## 2.6 Repository file plan

### Rework

| Path | Action |
|------|--------|
| `docker-compose.yaml` | Rewrite per §2.5 |
| `docker-compose.traefik.yaml` | Fix proxy, networks, middleware, websocket |
| `Dockerfile` | Thin odoo:18 + requirements |
| `config/odoo.conf` | Fix data_dir, paths, secrets, dev_mode, logging |
| `config/requirements.txt` | Keep/align with real module deps |
| `.env.example` | Complete placeholders |
| `.gitignore` | `.env`, legacy `database/`, etc. |
| `README.md` | Stack-only rewrite |
| `addons/` | Flat layout; short readme / gitkeep |
| `fonts/` | Keep mount only if still required |
| `Makefile` | Remove or point at `docker compose build` |

### Remove

| Path | Reason |
|------|--------|
| `entrypoint.sh` | Official entrypoint |
| `pre.sh` | Unused / unsafe |
| `run.sh` | Obsolete installer |
| `docker-compose.coolify.yaml` | Out of scope |
| `.gitmodules` | No submodules |
| `l10n_ve/` (submodule checkout) | Modules under `addons/` if needed |
| Root `enterprise/` special role | Same |
| Root `oca-tools/` as mounted path | If modules are kept in-repo, move to `addons/<module>/` as flat 18-compatible copies; otherwise remove from stack |

### Low priority / optional

| Path | Note |
|------|------|
| `logrotate/` | Prefer stdout; leave or drop later |
| Existing host `./database` | Prefer named `db-data`; operators with live data migrate once outside this design |

## 2.7 Security defaults

- No real `admin_passwd` or DB passwords in git.  
- pgAdmin bound to loopback only.  
- No world-writable chmod scripts.  
- Named volumes for DB and Odoo data instead of root-owned loose host DB trees where possible.  
- Rotate any previously committed master password when deploying.

## 2.8 Verification checklist

1. `docker compose config` succeeds.  
2. `docker compose up -d --build` serves Odoo 18; no `/etc/odoo/sessions` PermissionError.  
3. A dummy module under `addons/my_module` is visible after updating the apps list.  
4. pgAdmin reachable only via `127.0.0.1:5050` and can connect to host `db`.  
5. Traefik overlay: HTTPS host reaches Odoo; `/websocket` (and longpolling) hit gevent port 8072.  
6. Container restart does **not** run `pip install`.  
7. Repo has no `.gitmodules`, Coolify compose, or pre/run/entrypoint scripts.  
8. `.env` gitignored; conf placeholders only for secrets.

## 2.9 Implementation notes (for later plan)

- Order of work: fix config + volumes (correctness) → Dockerfile/compose build path → pgAdmin → Traefik fixes → delete dead files → README/env/gitignore.  
- Confirm `odoo:18` core `addons_path` inside the image before writing final conf.  
- If existing deployments use `./database` bind data, document a one-line operator note in the PR/README only if needed for cutover — not a full migration guide.  
- OCA modules currently at repo root (`oca-tools/`) are 17.0: do not mount as-is for 18; relocate under `addons/` only when 18-compatible.

## 2.10 Open items deferred (explicitly not blocking this design)

- Choice of official vs OpenUpgrade vs DIY for 17→18 database upgrade.  
- Backup/restore scripts.  
- Coolify.  
- Nested addons auto-discovery.

---

# Part 3 — Approval

Design captured from brainstorming on 2026-07-15.  
Canonical audit detail also lives in [`audits.md`](../../../audits.md).

**Next step after user approval of this file:** implementation plan via writing-plans skill (no implementation until then).
