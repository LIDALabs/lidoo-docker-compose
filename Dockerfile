FROM odoo:18

USER root

# Extra Python deps for modules under ./addons (installed at image build only).
# Official odoo:18 is Debian-managed (PEP 668); --break-system-packages is required
# to install into the image's system Python used by Odoo.
COPY config/requirements.txt /tmp/requirements.txt
RUN pip3 install --break-system-packages --ignore-installed --no-cache-dir \
        -r /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

# Error log directory (bind/volume mounted at runtime; ownership for user odoo)
RUN mkdir -p /var/log/odoo \
    && chown odoo:odoo /var/log/odoo

USER odoo
