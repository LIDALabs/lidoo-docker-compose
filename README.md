# Odoo 18 Docker Compose

Stack: Odoo 18 (built image), PostgreSQL 17, pgAdmin (localhost). Traefik is optional.

## Requirements

- Docker Engine
- Docker Compose v2
- Git

## 1. Clone

```bash
git clone --branch 18.0 git@github.com:LIDALabs/lidoo-docker-compose.git
cd lidoo-docker-compose
```

## 2. Create `.env`

```bash
cp .env.example .env
```

Edit `.env` and set at least:

| Variable | Purpose |
|----------|---------|
| `POSTGRES_USER` | Postgres + Odoo DB user |
| `POSTGRES_PASSWORD` | Postgres + Odoo DB password |
| `ODOO_ADMIN_PASSWD` | Odoo database manager master password (`/web/database`) |
| `PGADMIN_DEFAULT_EMAIL` | pgAdmin login email |
| `PGADMIN_DEFAULT_PASSWORD` | pgAdmin login password |
| `PGADMIN_PORT` | pgAdmin host port (default `5050`) |
| `ODOO_HTTP_PORT` | Host port for Odoo HTTP (default `10018`) |
| `ODOO_GEVENT_PORT` | Host port for gevent / websocket (default `20018`) |

Do not commit `.env`.

## 3. Add custom modules (optional)

Place modules **flat** under `addons/`:

```text
addons/
  my_module/
    __manifest__.py
    ...
```

Not nested as `addons/group/my_module/`.

## 4. Start (local, no Traefik)

```bash
docker compose up -d --build
```

| Service | URL / port |
|---------|------------|
| Odoo | http://localhost:${ODOO_HTTP_PORT:-10018} |
| Odoo gevent | host `${ODOO_GEVENT_PORT:-20018}` → container `8072` |
| pgAdmin | http://127.0.0.1:${PGADMIN_PORT:-5050} |

The image `lidoo-odoo:18` is built from `Dockerfile` (Odoo 18 + `config/requirements.txt`). Rebuild after changing requirements:

```bash
docker compose build --no-cache odoo
docker compose up -d
```

## 5. First Odoo use

1. Open http://localhost:10018 (or `ODOO_HTTP_PORT` from `.env`)
2. Create a database (master password = `ODOO_ADMIN_PASSWD` from `.env`)
3. Apps → Update Apps List if you added modules under `addons/`

## 6. pgAdmin

1. Open http://127.0.0.1:5050 (or `PGADMIN_PORT` from `.env`)
2. Log in with `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD`
3. Register a server:

| Field | Value |
|-------|--------|
| Host | `db` |
| Port | `5432` |
| Username | `POSTGRES_USER` |
| Password | `POSTGRES_PASSWORD` |

pgAdmin is bound to `127.0.0.1` only (not public, not Traefik).

## 7. Traefik (optional)

Use only when you need HTTPS and a public hostname.

### 7.1 Extra `.env` values

| Variable | Purpose |
|----------|---------|
| `ODOO_HOSTNAME` | Public host for Odoo |
| `LETS_ENCRYPT_CONTACT_EMAIL` | Let's Encrypt account email |
| `TRAEFIK_HOSTNAME` | Traefik dashboard host |
| `TRAEFIK_BASIC_AUTH` | Dashboard basic auth (`user:hash` from htpasswd) |

Generate basic auth:

```bash
htpasswd -nbB admin 'your-dashboard-password'
```

Put the result in `TRAEFIK_BASIC_AUTH`. If `$` is eaten by Compose, escape each `$` as `$$` in `.env`.

Optional:

| Variable | Default |
|----------|---------|
| `TRAEFIK_HTTP_PORT` | `80` |
| `TRAEFIK_HTTPS_PORT` | `443` |
| `TRAEFIK_NETWORK_NAME` | `traefik-public` |
| `TRAEFIK_NETWORK_EXTERNAL` | `false` (Compose creates the network) |

Set `TRAEFIK_NETWORK_EXTERNAL=true` only if `traefik-public` already exists on the host.

### 7.2 DNS and ports

- Point `ODOO_HOSTNAME` (and `TRAEFIK_HOSTNAME` if used) to this server
- Open host ports `80` and `443` (or the ports you set)

### 7.3 Start with Traefik

```bash
docker compose -f docker-compose.yaml -f docker-compose.traefik.yaml up -d --build
```

| Endpoint | Target |
|----------|--------|
| `https://$ODOO_HOSTNAME` | Odoo `:8069` |
| `/websocket`, `/longpolling` | Odoo gevent `:8072` |
| `https://$TRAEFIK_HOSTNAME` | Traefik dashboard (basic auth) |

## 8. Day-to-day commands

```bash
# Status
docker compose ps

# Logs
docker compose logs -f odoo
docker compose logs -f db

# Stop
docker compose down

# Stop and remove named volumes (destroys DB + filestore + pgAdmin data)
docker compose down -v
```

With Traefik, pass the same `-f` files:

```bash
docker compose -f docker-compose.yaml -f docker-compose.traefik.yaml ps
docker compose -f docker-compose.yaml -f docker-compose.traefik.yaml down
```

## 9. Data volumes

| Volume | Content |
|--------|---------|
| `odoo_data` | Odoo `data_dir` (sessions, filestore) |
| `odoo_logs` | Odoo error log at `/var/log/odoo/odoo-server.log` |
| `db_data` | PostgreSQL data |
| `pgadmin_data` | pgAdmin settings |
| `traefik_letsencrypt` | ACME certs (Traefik only) |

Tail the Odoo error log:

```bash
docker compose exec odoo tail -f /var/log/odoo/odoo-server.log
```

`log_level = error` in `config/odoo.conf` → only ERROR and CRITICAL in that file.

Config and addons stay on the host:

| Path | Role |
|------|------|
| `config/odoo.conf` | Odoo options (no secrets; master password from `.env`) |
| `config/requirements.txt` | Extra Python packages (installed at image build) |
| `addons/` | Custom modules |
| `fonts/` | Optional custom fonts |

### Legacy host `./database`

Older stacks bind-mounted `./database` for Postgres. This stack uses named volume `db_data` only. The folder is gitignored and unused. Safe to delete after you have migrated or no longer need that data:

```bash
# only if you do not need the old host DB files
sudo rm -rf database
```

## 10. Config notes

- Secrets: only in `.env` (`POSTGRES_*`, `ODOO_ADMIN_PASSWD`, `PGADMIN_*`, Traefik auth)
- `config/odoo.conf`: `data_dir = /var/lib/odoo`, addons path includes `/mnt/extra_addons`
- Do not put a real `admin_passwd` in git; it is injected at container start from `ODOO_ADMIN_PASSWD`

## 11. Multi-DB by subdomain (rare, optional)

Default is **one database**. Only some servers use several DBs on **one** Odoo, selected by subdomain (`dbfilter`).

Example: `sub1.domain.com` → DB `sub1`, `sub2.domain.com` → DB `sub2`.

### Odoo

1. Create DBs named like the subdomain: `sub1`, `sub2`
2. In `config/odoo.conf` uncomment/set:
   ```ini
   dbfilter = ^%d$
   ```
3. Optional prod: `list_db = False`
4. Keep `proxy_mode = True` (already set)
5. Restart:
   ```bash
   docker compose up -d
   ```

### DNS

6. `sub1.domain.com` → server IP  
7. `sub2.domain.com` → server IP  

### Traefik (if public)

8. Change Host rules in `docker-compose.traefik.yaml` to cover **all** hosts, e.g.:
   ```text
   Host(`sub1.domain.com`) || Host(`sub2.domain.com`)
   ```
9. Use that same Host rule on:
   - app → `8069`
   - `/websocket` + `/longpolling` → `8072`
10. TLS for both hosts (or `*.domain.com`)
11. Redeploy:
    ```bash
    docker compose -f docker-compose.yaml -f docker-compose.traefik.yaml up -d
    ```

### Check

12. `https://sub1.domain.com` → DB `sub1`  
13. `https://sub2.domain.com` → DB `sub2`  

### Rules

- DB name = first subdomain label (`%d`)
- One Odoo service, one Postgres service — no second containers
- pgAdmin unchanged: host `db`, port `5432`
