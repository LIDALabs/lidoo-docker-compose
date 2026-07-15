FROM odoo:18

USER root

# Extra Python deps for modules under ./addons (installed at image build only).
# Official odoo:18 is Debian-managed (PEP 668); --break-system-packages is required
# to install into the image's system Python used by Odoo.
COPY config/requirements.txt /tmp/requirements.txt
RUN pip3 install --break-system-packages --ignore-installed --no-cache-dir \
        -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

USER odoo

# Official image entrypoint — do not override
# Modules: bind-mount ./addons → /mnt/extra_addons (not baked into the image)
# Config: bind-mount ./config/odoo.conf → /etc/odoo/odoo.conf
# Data: named volume odoo-data → /var/lib/odoo
