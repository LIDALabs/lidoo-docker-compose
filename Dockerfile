FROM odoo:17

USER root

# Copy requirements
COPY ./config/requirements.txt /etc/odoo/
# Install extra python packages
RUN pip3 install pip --upgrade \
    && pip3 install -r /etc/odoo/requirements.txt

# Copy Odoo configuration file
COPY ./config/odoo.conf /etc/odoo/
# Copy extra addons
COPY ./addons /mnt/extra_addons

# Set permissions and Mount /var/lib/odoo to allow restoring filestore and /mnt/extra_addons for users addons
RUN chown odoo /etc/odoo/odoo.conf \
    && chown -R odoo /mnt/extra_addons
VOLUME ["/var/lib/odoo", "/mnt/extra_addons"]

USER odoo

# Use the official image entrypoint (do not override)
CMD ["odoo"]
