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
 # Copy localization
COPY ./l10n_ve /mnt/l10n_ve_fiscal

# Set permissions and Mount /var/lib/odoo to allow restoring filestore and /mnt/extra_addons for users addons
RUN chown odoo /etc/odoo/odoo.conf \
    && chown -R odoo /mnt/extra_addons \
    && chown -R odoo /mnt/l10n_ve_fiscal
VOLUME ["/var/lib/odoo", "/mnt/extra_addons", "/mnt/l10n_ve_fiscal"]

USER odoo

# Use the official image entrypoint (do not override)
CMD ["odoo"]
