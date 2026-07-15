# Project audit — lidoo-docker-compose

**Date:** 2026-07-15  
**Branch audited:** `18.0`  
**Scope:** Docker Compose Odoo stack (compose files, Dockerfile, entrypoint, config, scripts, docs, git layout).  
**Note:** Branch is named `18.0` but the stack still targets **Odoo 17** end-to-end.

**Design (audit + redesign):** [`docs/superpowers/specs/2026-07-15-odoo18-stack-design.md`](docs/superpowers/specs/2026-07-15-odoo18-stack-design.md) — Part 1 repeats this audit; Part 2 is the approved stack redesign.

---

## Summary

| Severity | Count |
|----------|------:|
| Critical | 5 |
| High | 8 |
| Medium | 10 |
| Low / docs | 6 |

**Top risks for production:** wrong `data_dir` (session permission failures), no durable Odoo filestore volume, secrets committed to git, empty/broken addon mounts via submodule, and version drift (17 vs 18).

---

## Critical

### C1 — `data_dir` points at the config bind mount

| | |
|---|---|
| **Where** | `config/odoo.conf` (`data_dir = /etc/odoo`) |
| **What** | Odoo stores sessions, filestore, and other runtime data under `data_dir`. Compose mounts `./config:/etc/odoo`, so the container user often cannot write sessions. |
| **Impact** | Runtime failure: `PermissionError: [Errno 13] Permission denied: '/etc/odoo/sessions'` (observed in prior runs). |
| **Expected** | `data_dir = /var/lib/odoo` (official image convention), with a persistent volume on that path. |

### C2 — No persistent volume for Odoo data (`/var/lib/odoo`)

| | |
|---|---|
| **Where** | `docker-compose.yaml` (odoo service volumes) |
| **What** | Only config, addons, fonts, and entrypoint are mounted. There is no named or bind volume for `/var/lib/odoo`. |
| **Impact** | Attachments, sessions, and other filestore data are not reliably persisted across recreate/recreate-from-image; if `data_dir` is fixed without a volume, data still lives in the container filesystem. |
| **Expected** | Named volume or host bind for `/var/lib/odoo` (and correct `data_dir`). |

### C3 — Master password committed in plain text

| | |
|---|---|
| **Where** | `config/odoo.conf` (`admin_passwd = …`) |
| **What** | Database manager master password is stored in the repo. |
| **Impact** | Anyone with repo access can manage/create/drop databases via `/web/database`. |
| **Expected** | Secret via env / Docker secret / untracked override; example placeholder only in git. |

### C4 — Version mismatch: branch `18.0` still deploys Odoo 17

| | |
|---|---|
| **Where** | `docker-compose.yaml` (`image: odoo:17`, service `odoo17`, ports `10017`/`20017`), `Dockerfile` (`FROM odoo:17`), `Makefile` (`odoo-lida:17`), `docker-compose.coolify.yaml` (`lidoo:17-coolify`), `.gitmodules` (`branch = 17.0-lida`), `oca-tools/*/ __manifest__.py` (`version: 17.0.*`) |
| **What** | Naming and tooling claim 18; runtime and modules are 17. |
| **Impact** | Misleading branch, broken upgrade planning, incompatible OCA modules if image is flipped without module ports. |
| **Expected** | Align image, service name, ports, Makefile, Coolify tag, and module series to 18 (or keep 17 and rename branch). |

### C5 — Addon mounts empty or not checked out

| | |
|---|---|
| **Where** | `l10n_ve` (git submodule, status not initialized), `enterprise/` (empty host dir) |
| **What** | Submodule present in `.gitmodules` but working tree empty; enterprise directory empty. |
| **Impact** | Deploys that assume fiscal or enterprise modules get empty `/mnt/l10n_ve_fiscal` / `/mnt/enterprise` → missing modules, failed installs, confusing “addons_path works but nothing appears”. |
| **Expected** | Either document required host content, or stop using empty submodule mounts (see also H1). |

---

## High

### H1 — Git submodule couples stack deploy to addon repos

| | |
|---|---|
| **Where** | `.gitmodules` → `l10n_ve` → `https://github.com/LIDALabs/odoo-venezuela.git` |
| **What** | Localization lives as a submodule. Clone without `--recurse-submodules` / `submodule update` leaves an empty directory. |
| **Impact** | Fragile installs; stack repo is not “compose-only”. |
| **Expected** | Stack only; custom modules under host `addons/` (e.g. `addons/l10n_ve/<modules…>`), no submodule required to start the stack. |

### H2 — `entrypoint.sh` reinstalls Python packages on every start

| | |
|---|---|
| **Where** | `entrypoint.sh` (`pip3 install pip --upgrade` + `pip3 install -r /etc/odoo/requirements.txt`) |
| **What** | Startup always hits the network and mutates the image environment. Official image runs as `odoo`; pip may fail without write access. |
| **Impact** | Slow boots, flaky offline deploys, partial installs, divergence from built image. |
| **Expected** | Install deps only in Dockerfile (or a one-shot init); entrypoint only waits for DB and launches Odoo. |

### H3 — Dockerfile and Compose disagree

| | |
|---|---|
| **Where** | `Dockerfile` vs `docker-compose.yaml` vs `docker-compose.coolify.yaml` |
| **What** | Main compose uses `image: odoo:17` and never builds the Dockerfile. Coolify builds Dockerfile but omits several mounts (oca-tools, l10n_ve, fonts, full config strategy). Dockerfile sets `ENTRYPOINT ["/entrypoint.sh"]` without `COPY` of `entrypoint.sh` (only main compose bind-mounts it). |
| **Impact** | “Works on my machine” vs Coolify/prod drift; custom requirements/entrypoint not applied consistently. |
| **Expected** | Single source of truth: either always `build:` from Dockerfile, or always stock image + documented mounts; entrypoint copied into image if used as ENTRYPOINT. |

### H4 — `dev_mode = reload` enabled

| | |
|---|---|
| **Where** | `config/odoo.conf` |
| **What** | Developer reload mode is on. |
| **Impact** | Inappropriate for production (performance, restarts, security surface). |
| **Expected** | Off by default; enable only in a local/dev override. |

### H5 — Weak default database credentials

| | |
|---|---|
| **Where** | `docker-compose.yaml`, `entrypoint.sh` (`POSTGRES_PASSWORD` default `supersecret`) |
| **What** | Defaults allow boot without a real secret. |
| **Impact** | Accidental production deploy with known password. |
| **Expected** | Require `.env` vars with no insecure default (or fail fast if unset in prod profile). |

### H6 — `.gitignore` does not match real data paths

| | |
|---|---|
| **Where** | `.gitignore` ignores `postgresql/`; compose uses `./database` |
| **What** | Wrong directory name; `database/` (and possibly large/root-owned files) not ignored. |
| **Impact** | Risk of committing DB files or leaving sensitive data untracked incorrectly; confusion with `run.sh` which still refers to `postgresql`. |
| **Expected** | Ignore `database/`, `.env`, logs, filestore binds, etc. |

### H7 — World-writable permissions in setup scripts and docs

| | |
|---|---|
| **Where** | `pre.sh`, `README.md` (`chmod -R 777` on addons/config/database/…) |
| **What** | Install path recommends 777 and `chown` to `odoousr` (may not exist). |
| **Impact** | Security risk; non-portable setup. |
| **Expected** | Document correct UID/GID for `odoo` (image user) and Postgres (999); minimal required permissions. |

### H8 — Logfile under config mount

| | |
|---|---|
| **Where** | `config/odoo.conf` (`logfile = /etc/odoo/odoo-server.log`) |
| **What** | Logs written into the bind-mounted config directory. |
| **Impact** | Permission errors if not writable; config dir polluted with logs; logrotate paths awkward. |
| **Expected** | Log to stdout (Docker-friendly) or a dedicated log volume/path with correct ownership. |

---

## Medium

### M1 — Traefik network half-wired in base compose

| | |
|---|---|
| **Where** | `docker-compose.yaml` (Traefik labels present; `traefik-public` commented), `docker-compose.traefik.yaml` (`traefik-public` external) |
| **What** | Labels assume Traefik routing, but service only joins `intranet` in current base file. |
| **Impact** | Traefik cannot route to Odoo unless network wiring is fixed/overlaid carefully. |
| **Expected** | Profiles or clear local vs prod compose: Traefik labels + `traefik-public` only when Traefik is used. |

### M2 — Missing `/websocket` Traefik routes

| | |
|---|---|
| **Where** | `docker-compose.yaml` labels (only `PathPrefix(/longpolling)` for bus) |
| **What** | Modern Odoo uses gevent websocket endpoints in addition to legacy longpolling. |
| **Impact** | Discuss, notifications, and some live features break behind reverse proxy. |
| **Expected** | Route `/websocket` (and keep `/longpolling` if needed) to gevent port `8072`. |

### M3 — `depends_on` without health condition

| | |
|---|---|
| **Where** | `docker-compose.yaml` (`depends_on: - db`) |
| **What** | No `condition: service_healthy`. |
| **Impact** | Race on cold start (partly mitigated by `wait-for-psql.py` in entrypoint). |
| **Expected** | `depends_on: db: condition: service_healthy` where Compose version supports it. |

### M4 — Awkward Postgres data directory layout and ownership

| | |
|---|---|
| **Where** | Compose: `./database:/var/lib/postgresql/data` + `PGDATA: .../pgdata`; host `database/` owned by root |
| **What** | Nested `pgdata` under bind mount; root-owned host tree. |
| **Impact** | Harder backups, permission pain, confusion for operators. |
| **Expected** | Prefer named volume `db-data:/var/lib/postgresql/data`, or a single clean host path with documented ownership. |

### M5 — `addons_path` formatting / structure issues

| | |
|---|---|
| **Where** | `config/odoo.conf` (`addons_path = /mnt/enterprise,/mnt/extra_addons,/mnt/l10n_ve_fiscal, /mnt/oca-tools`) |
| **What** | Space after comma; separate mounts for packs that are better modeled as groups under `addons/`; Odoo only loads **direct** children of each path entry (no recursion into `addons/l10n_ve/*`). |
| **Impact** | Nested layout `addons/l10n_ve/module` will **not** load if only `/mnt/extra_addons` is listed — must list `/mnt/extra_addons/l10n_ve` (or auto-scan). |
| **Expected** | Explicit, consistent paths matching the chosen host layout; no submodule-only mounts. |

### M6 — Traefik dashboard middleware labels overwrite each other

| | |
|---|---|
| **Where** | `docker-compose.traefik.yaml` (router `traefik-http`: two separate `middlewares=` labels) |
| **What** | In Docker labels, duplicate keys for the same router middleware setting overwrite; redirect and basic-auth do not both apply as intended. |
| **Impact** | Broken auth and/or redirect on Traefik UI. |
| **Expected** | Single middleware chain: `middlewares=redirect-to-https,traefik-auth` (or HTTPS-only dashboard). |

### M7 — `run.sh` obsolete and incorrect

| | |
|---|---|
| **Where** | `run.sh` |
| **What** | Clones old branch `17.0-lida`, uses `docker-compose.yml` (wrong filename), creates `postgresql` (not `database`), prints wrong master password (`minhng.info`). |
| **Impact** | Misleading automation; broken one-shot install. |
| **Expected** | Remove or rewrite against current compose + secrets. |

### M8 — OCA modules still on 17.0 series

| | |
|---|---|
| **Where** | `oca-tools/module_auto_update` (`17.0.1.0.0`), `oca-tools/report_xlsx` (`17.0.1.0.2`) |
| **What** | Vendored OCA code not ported/updated for 18. |
| **Impact** | Install/runtime errors on Odoo 18 until upgraded or removed. |
| **Expected** | Upgrade to 18.0 OCA releases, or document as optional 17-only. |

### M9 — Python deps incomplete for OCA tools

| | |
|---|---|
| **Where** | `config/requirements.txt` |
| **What** | `report_xlsx` needs `xlsxwriter` / `xlrd`; not listed. Comments refer to packages not installed. Historical pain with `pysftp` / pip on start. |
| **Impact** | Module import/runtime failures. |
| **Expected** | Pin all runtime deps required by enabled modules; install at image build. |

### M10 — Healthcheck brittle

| | |
|---|---|
| **Where** | Odoo service `curl -f http://127.0.0.1:8069` |
| **What** | Root URL may redirect or not return 2xx during init. |
| **Impact** | False unhealthy / unnecessary restarts. |
| **Expected** | Hit a known path (e.g. `/web/health` if available for version) or tolerate redirects carefully. |

---

## Low / documentation

### L1 — README incomplete and inaccurate

| | |
|---|---|
| **Where** | `README.md` |
| **What** | Broken markdown, `chmod 777` guidance, incomplete logrotate instructions, clone URL contains `GITOB@`, still describes 17.0-style install. |
| **Impact** | Onboarding friction and unsafe ops. |
| **Expected** | Single clear path: env vars, compose up, addon layout, Traefik/Coolify optional. |

### L2 — `.env.example` incomplete

| | |
|---|---|
| **Where** | `.env.example` |
| **What** | Has hostname / Traefik-ish vars; missing `POSTGRES_USER`, `POSTGRES_PASSWORD`, optional ports, pgAdmin secrets (once added). |
| **Impact** | Incomplete template for real deploys. |
| **Expected** | Document all required and optional variables with safe placeholders. |

### L3 — Coolify compose is a partial subset

| | |
|---|---|
| **Where** | `docker-compose.coolify.yaml` |
| **What** | Missing parity with main stack (fonts, oca-tools, l10n, entrypoint/config strategy). |
| **Impact** | Coolify deploys behave differently from local/prod Traefik path. |
| **Expected** | Shared base service definition or documented intentional differences. |

### L4 — Hardcoded Traefik basic-auth hash in compose

| | |
|---|---|
| **Where** | `docker-compose.traefik.yaml` |
| **What** | Basic auth user/password hash inlined. |
| **Impact** | Shared secret across deployments if file is reused as-is. |
| **Expected** | Env-driven `${TRAEFIK_HTTP_USER}` / password hash from `.env`. |

### L5 — `pre.sh` incomplete and unsafe

| | |
|---|---|
| **Where** | `pre.sh` |
| **What** | Mix of `DESTINATION` and relative paths; 777; optional `odoousr` chown. |
| **Impact** | Non-reproducible host prep. |
| **Expected** | Idempotent prep script with correct ownership only. |

### L6 — Logrotate template disconnected

| | |
|---|---|
| **Where** | `logrotate/conf/odoo.conf.example`, README |
| **What** | Example uses `$ODOODIR` / `$ODOOUSER` placeholders; README sed instructions incomplete (“Este comando **no** copia…”). |
| **Impact** | Logrotate rarely applied correctly. |
| **Expected** | Prefer container stdout logging; if host logrotate kept, finish docs and path alignment. |

---

## Structural / product intent (not bugs, but design drivers)

These came up in planning and should drive the fix work (not counted as defects above):

1. **Addon layout goal:** host tree like `addons/l10n_ve/(addon1, addon2, …)` should make those modules available to Odoo. That requires `addons_path` entries for **each group directory** (Odoo does not recurse).
2. **No git submodules** for deploy: stack repo only brings up Odoo + DB (+ Traefik/pgAdmin); operators place module trees under `addons/`.
3. **Hardcoded vs auto-scanned paths:** still open decision (hardcode group paths in `odoo.conf` vs generate `addons_path` from first-level dirs under `addons/`).
4. **pgAdmin:** requested database viewer; not present (Adminer only commented out).
5. **Odoo 18 upgrade:** full alignment of image, modules, docs, and ports.

---

## File inventory (quick map)

| Path | Role | Audit notes |
|------|------|-------------|
| `docker-compose.yaml` | Main stack | 17 image, no filestore volume, Traefik labels half-wired |
| `docker-compose.traefik.yaml` | Traefik reverse proxy | Middleware overwrite; external network |
| `docker-compose.coolify.yaml` | Coolify variant | Incomplete parity |
| `Dockerfile` | Custom image | 17 base; entrypoint not copied; unused by main compose |
| `entrypoint.sh` | Container start | pip every boot; based on 18.0 upstream comment |
| `config/odoo.conf` | Odoo options | data_dir, admin_passwd, dev_mode, logfile, addons_path |
| `config/requirements.txt` | Extra pip deps | Incomplete for OCA |
| `.gitmodules` | Submodule | `l10n_ve` → 17.0-lida |
| `l10n_ve/`, `enterprise/`, `addons/`, `oca-tools/` | Addon mounts | Empty / submodule / vendored 17 OCA |
| `pre.sh`, `run.sh`, `Makefile`, `README.md` | Ops UX | Outdated, insecure, incomplete |
| `database/` | Postgres host data | Root-owned; not gitignored correctly |

---

## Suggested fix priority (for later implementation)

1. Fix `data_dir` + add Odoo data volume; move secrets out of git.  
2. Decide addon layout + `addons_path` strategy; remove submodule.  
3. Align stack to Odoo 18 (image, OCA, docs).  
4. Unify Dockerfile vs compose; stop pip-on-start.  
5. Add pgAdmin; fix Traefik websocket + network profiles.  
6. Rewrite README / `.env.example` / scripts; fix `.gitignore`.

---

## Open questions (from brainstorming, still pending)

- [ ] How to register group paths under `addons/` (hardcoded list vs auto-scan on start).  
- [ ] Whether `enterprise/` stays a separate mount or moves under `addons/enterprise/`.  
- [ ] Whether `oca-tools` stays vendored in this repo or becomes another group under `addons/`.  
- [ ] pgAdmin exposure: localhost only vs Traefik-authenticated host.  
- [ ] Scope: greenfield Odoo 18 only vs migrate existing 17 databases.  
- [ ] Deployment targets to keep: local only, Traefik, Coolify — which are first-class.
