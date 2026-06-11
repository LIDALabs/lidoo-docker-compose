#!/bin/bash
set -euo pipefail

# update-modules.sh — Actualiza todos los módulos de una instancia Odoo en ejecución
#
# Sintaxis:
#   ./update-modules.sh <nombre_db> [prefijo_proyecto]
#
# Ejemplos:
#   ./update-modules.sh lida
#   ./update-modules.sh cliente1 dispeven
#
# Proceso:
#   1. Toma un backup de la base de datos (pg_dump -Fc comprimido)
#   2. Opcionalmente respalda el filestore de la base de datos
#   3. Ejecuta la actualización de todos los addons (odoo -u all)
#
# Requisitos:
#   - El contenedor de Odoo debe estar en ejecución (docker compose ps)
#   - Ejecutar desde la raíz del proyecto (donde está docker-compose.yaml)

DB_NAME="${1:?"Error: Especifica el nombre de la base de datos
Uso: $0 <nombre_db> [prefijo_proyecto]"}"
PROJECT_PREFIX="${2:-}"
BACKUP_DIR="./backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}═══ $* ═══${NC}"; }

# ─── Cargar variables de entorno ─────────────────────────────────────────────
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

PG_USER="${POSTGRES_USER:-odoo}"
PG_PASSWORD="${POSTGRES_PASSWORD:-supersecret}"

# ─── Argumentos para docker compose ──────────────────────────────────────────
DOCKER_ARGS=()
COMPOSE_FILE=""
if [ -n "$PROJECT_PREFIX" ]; then
    DOCKER_ARGS+=("-p" "$PROJECT_PREFIX")
fi

DC="docker compose ${DOCKER_ARGS[*]:-}"

# ─── Validaciones ────────────────────────────────────────────────────────────
step "Validando entorno"

# Verificar que docker compose es accesible
if ! docker compose version &>/dev/null; then
    error "Docker Compose no está disponible. Verifica la instalación."
    exit 1
fi

# Verificar que los servicios están levantados
SVC_ODOO="odoo17"
if ! docker compose "${DOCKER_ARGS[@]}" ps --services --filter "status=running" 2>/dev/null | grep -q "$SVC_ODOO"; then
    error "El servicio '$SVC_ODOO' no está en ejecución."
    info  "Levanta la instancia primero con: $DC up -d"
    exit 1
fi
info "Servicio '$SVC_ODOO' detectado en ejecución."

# ─── 1. Backup de la base de datos ──────────────────────────────────────────
step "1. Backup de la base de datos"

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.dump"
BACKUP_INFO="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.info"

info "Creando backup de la base de datos '$DB_NAME'..."
info "Destino: $BACKUP_FILE"

PGPASSWORD="$PG_PASSWORD" \
    docker compose "${DOCKER_ARGS[@]}" exec -T db \
    pg_dump -U "$PG_USER" -Fc --no-owner --no-privileges \
    -d "$DB_NAME" > "$BACKUP_FILE"

# Verificar integridad básica del backup
if [ ! -s "$BACKUP_FILE" ]; then
    error "El backup está vacío. Abortando."
    exit 1
fi

# Guardar metadata del backup para referencia
{
    echo "Database:    $DB_NAME"
    echo "Timestamp:   $(date)"
    echo "File:        $BACKUP_FILE"
    echo "Size:        $(du -h "$BACKUP_FILE" | cut -f1)"
    echo "Format:      pg_dump -Fc (custom)"
    echo "Project:     $PROJECT_PREFIX"
} > "$BACKUP_INFO"

info "Backup completado: $(du -h "$BACKUP_FILE" | cut -f1)"

# ─── 2. Backup del filestore (opcional) ──────────────────────────────────────
FILESTORE_PATH="config/filestore/$DB_NAME"
if [ -d "$FILESTORE_PATH" ]; then
    step "2. Backup del filestore"

    FILESTORE_BACKUP="${BACKUP_DIR}/${DB_NAME}_filestore_${TIMESTAMP}.tar.gz"
    info "Respaldando filestore desde $FILESTORE_PATH ..."

    tar czf "$FILESTORE_BACKUP" -C "$(dirname "$FILESTORE_PATH")" "$DB_NAME"

    info "Filestore respaldado: $(du -h "$FILESTORE_BACKUP" | cut -f1)"
else
    warn "No se encontró filestore en $FILESTORE_PATH. Se omite."
fi

# ─── 3. Actualización de módulos ────────────────────────────────────────────
step "3. Actualizando todos los módulos en '$DB_NAME'"

info "Ejecutando: odoo -d $DB_NAME -u all --stop-after-init"
info "Esto puede tomar varios minutos dependiendo de la cantidad de módulos..."
echo ""

info "Pasando credenciales de DB: host=db port=5432 user=$PG_USER"
if ! docker compose "${DOCKER_ARGS[@]}" exec -T "$SVC_ODOO" \
    odoo -d "$DB_NAME" \
    --db_host db --db_port 5432 --db_user "$PG_USER" --db_password "$PG_PASSWORD" \
    --logfile stderr --no-http \
    -u all --stop-after-init; then
    error "La actualización falló. Revisa los logs con: $DC logs $SVC_ODOO"
    info  "El backup de la base de datos está disponible en: $BACKUP_FILE"
    exit 1
fi

# ─── Finalización ────────────────────────────────────────────────────────────
step "Actualización completada"

echo ""
info "Resumen:"
echo "  Base de datos:  $DB_NAME"
echo "  Backup DB:      $BACKUP_FILE  ($(du -h "$BACKUP_FILE" | cut -f1))"
echo "  Proyecto:       ${PROJECT_PREFIX:-"(sin prefijo)"}"
echo ""
info "La instancia sigue en ejecución. Para reiniciar el contenedor si es necesario:"
echo "    $DC restart $SVC_ODOO"
echo ""
info "Para restaurar el backup en caso de necesidad:"
echo "    docker compose ${DOCKER_ARGS[*]:-} exec -T db pg_restore -U $PG_USER -d $DB_NAME --clean $BACKUP_FILE"
echo ""
info "O via pg_restore en el host (si tenés psql client local):"
echo "    PGPASSWORD=$PG_PASSWORD pg_restore -h localhost -U $PG_USER -d $DB_NAME --clean $BACKUP_FILE"
