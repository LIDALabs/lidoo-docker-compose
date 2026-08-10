# Diagnóstico de actualización Odoo 18 en iutepal

## Resumen

La actualización de la base iutepal no falló por ser un VPS ni por PostgreSQL. Se combinaron dos problemas:

1. El esquema de la base estaba atrasado respecto al código actual de la localización venezolana.
2. El entrypoint personalizado del contenedor ignoraba los argumentos enviados mediante docker compose run.

Como consecuencia, -u all, --stop-after-init y --no-http no llegaban a Odoo. El contenedor iniciaba el servidor HTTP normal y luego fallaba al procesar /web/login.

## Evidencia del esquema atrasado

En la base se consultó:

~~~sql
SELECT name, state, latest_version
FROM ir_module_module
WHERE name IN ('l10n_ve_lidoo_base', 'l10n_ve_lidoo_setup');
~~~

Resultado:

~~~text
l10n_ve_lidoo_base  | installed | 18.0.1.14.0
l10n_ve_lidoo_setup | installed | 18.0.1.5.1
~~~

El código actual de l10n_ve_lidoo_base espera estas columnas:

~~~text
l10n_ve_lidoo_default_customer_payment_term_id
l10n_ve_lidoo_default_vendor_payment_term_id
~~~

La consulta sobre res_company devolvió cero columnas para el patrón l10n_ve_lidoo_default%. Por eso PostgreSQL devolvió:

~~~text
psycopg2.errors.UndefinedColumn:
column res_company.l10n_ve_lidoo_default_customer_payment_term_id does not exist
~~~

El registro ir_module_module indicaba instalado, pero eso no garantizaba que la actualización del esquema hubiera terminado.

## Causa del entrypoint

En docker-compose.yaml el servicio declara:

~~~yaml
entrypoint: ["/usr/local/bin/odoo-start.sh"]
~~~

El Dockerfile copia ese script dentro de la imagen:

~~~dockerfile
COPY docker/odoo-start.sh docker/odoo-logsplit /usr/local/bin/
~~~

La versión original de docker/odoo-start.sh iniciaba siempre Odoo así:

~~~bash
"${DROP[@]}" /entrypoint.sh odoo > "$FIFO" 2>&1 &
~~~

No usaba "$@", que contiene los argumentos recibidos por el entrypoint. Por tanto, un comando como:

~~~bash
docker compose run --rm odoo odoo -d iutepal -u all --stop-after-init --no-http
~~~

terminaba iniciando solamente el servidor normal odoo.

La evidencia fue:

~~~text
HTTP service (werkzeug) running
GET /web/login
~~~

En una actualización one-shot correcta no debe aparecer el servidor HTTP.

## Corrección aplicada en el clone

Se clonó la rama 18.0 del repositorio Docker. El cambio se hizo únicamente en docker/odoo-start.sh:

~~~bash
# Official Odoo entrypoint. Forward compose/run arguments; default to the
# normal odoo command when the service starts without an explicit command.
ODOO_ARGS=("$@")
if [ "${#ODOO_ARGS[@]}" -eq 0 ]; then
  ODOO_ARGS=(odoo)
fi
"${DROP[@]}" /entrypoint.sh "${ODOO_ARGS[@]}" > "$FIFO" 2>&1 &
ODOO_PID=$!
~~~

El comportamiento queda así:

- docker compose up usa odoo por defecto.
- docker compose run odoo odoo ... reenvía todos los argumentos.
- --no-http evita levantar el servidor del proceso de actualización.
- --stop-after-init permite que el proceso termine.
- -u l10n_ve_lidoo_base o -u all llega al proceso real de Odoo.

## Validación realizada

Se ejecutó:

~~~bash
bash -n docker/odoo-start.sh
git diff --check
~~~

Ambas validaciones terminaron sin errores. También se comprobó el bloque de argumentos con el resultado:

~~~text
odoo
odoo -d iutepal -u all --stop-after-init --no-http
~~~

El cambio está aplicado en el clone local. Todavía no implica que la imagen del VPS haya sido reconstruida ni que el cambio haya sido publicado en GitHub.

## Procedimiento recomendado en el VPS

### 1. Respaldar la base

~~~bash
sudo docker compose exec -T db pg_dump -U odoo -Fc iutepal > iutepal-before-upgrade.dump
~~~

### 2. Llevar el script corregido

Copiar la versión corregida de docker/odoo-start.sh al repositorio del VPS. Validar antes de reconstruir:

~~~bash
bash -n docker/odoo-start.sh
~~~

No se recomienda seguir aplicando parches improvisados sobre bloques ya modificados, porque los intentos anteriores dejaron líneas duplicadas y bloques pegados en una sola línea.

### 3. Reconstruir la imagen

El script se copia durante el build:

~~~bash
sudo docker compose build odoo
~~~

### 4. Actualizar la base

Detener primero el servidor normal:

~~~bash
sudo docker compose stop odoo
~~~

Actualizar primero el módulo base:

~~~bash
sudo docker compose run --rm odoo odoo -c /var/lib/odoo/odoo.runtime.conf -d iutepal -u l10n_ve_lidoo_base --stop-after-init --no-http --logfile stderr
~~~

Después de validar el módulo base se puede actualizar todo:

~~~bash
sudo docker compose run --rm odoo odoo -c /var/lib/odoo/odoo.runtime.conf -d iutepal -u all --stop-after-init --no-http --logfile stderr
~~~

La ruta debe ser exactamente /var/lib/odoo/odoo.runtime.conf, sin espacios.

### 5. Comprobar el resultado

La salida correcta no debe mostrar HTTP service (werkzeug) running ni GET /web/login y debe finalizar con código cero.

Verificar columnas:

~~~bash
sudo docker compose exec db psql -U odoo -d iutepal -c "SELECT column_name FROM information_schema.columns WHERE table_name = 'res_company' AND column_name LIKE 'l10n_ve_lidoo_default%';"
~~~

Deben aparecer las columnas de términos de pago. Revisar también la versión del módulo:

~~~bash
sudo docker compose exec db psql -U odoo -d iutepal -c "SELECT name, state, latest_version FROM ir_module_module WHERE name = 'l10n_ve_lidoo_base';"
~~~

Finalmente iniciar Odoo:

~~~bash
sudo docker compose start odoo
~~~

## Mensajes que no fueron la causa

- Can't find .pfb for face Courier: advertencia de fuente.
- inconsistent compute_sudo e inconsistent store: advertencias de campos computados.
- Found orphan containers: advertencia de Docker por ejecuciones anteriores.
- Mensajes de wkhtmltopdf: los binarios fueron encontrados.

No se debe usar --remove-orphans como solución del problema de esquema.

## Conclusión

Era necesario resolver ambos puntos. Corregir solo la base no bastaba si el entrypoint seguía ignorando -u; corregir solo el entrypoint no bastaba si faltaban columnas en res_company.

Orden recomendado: llevar el entrypoint corregido, reconstruir la imagen, actualizar l10n_ve_lidoo_base, verificar columnas y versión, actualizar el resto de módulos e iniciar Odoo.
