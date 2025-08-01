# Installing Odoo (Supports multiple Odoo instances on one server).

Based on [https://github.com/minhng92/odoo-17-docker-compose](https://github.com/minhng92/odoo-17-docker-compose)

## Quick Installation

Clone the repository

```bash
git clone --branch 17.0 --depth=1 https://GITPAP@github.com/LIDALabs/odoo-docker-compose.git
```

## Fixes
    ```bash
    chmod -R 777 addons
    chmod -R 777 config
    chmod -R 777 postgresql
    ```

## Comandos útiles

Copiar el archivo `.env`, reemplazar el dominio (debe reemplazar `<DOMINIO>`, por ejemplo por `empresa.lidalabs.com` antes de correr el comando) y ejecutar el script de configuración.
```shell
cp .env.example .env && sed -i 's#odoo.example.com#<DOMINIO>#' .env && bash pre.sh `pwd`
```

Copiar el archivo de configuración para la rotación de logs. Este comando **no** copia el archivo a 
```shell
cp logrotate/conf/odoo.conf.example odoo.logrotate.conf && sed -i 's#$ODOODIR#'`pwd`'#' .env odoo.logrotate.conf && sed -i 's#$ODOOUSER#<ODOOUSR>#g' odoo.logrotate.conf
```