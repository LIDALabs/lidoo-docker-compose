FROM odoo:17

USER root

# Copy requirements
COPY ./config/requirements.txt /etc/odoo/
# Install extra python packages
RUN pip3 install pip --upgrade \
    && pip3 install -r /etc/odoo/requirements.txt

# Copy enterprise addons
COPY ./enterprise /mnt/enterprise
# Set permissions
RUN chown -R odoo /mnt/enterprise

# Copy Odoo configuration file
COPY ./config/odoo.conf /etc/odoo/
 # Copy extra addons
 COPY ./addons /mnt/extra-addons
 # Copy localization
COPY ./l10n_ve /mnt/l10n_ve_addons

# Set permissions and Mount /var/lib/odoo to allow restoring filestore and /mnt/extra-addons for users addons
RUN chown odoo /etc/odoo/odoo.conf \
    && chown -R odoo /mnt/extra-addons \
    && chown -R odoo /mnt/l10n_ve_addons
VOLUME ["/var/lib/odoo", "/mnt/extra-addons", "/mnt/l10n_ve_addons"]

USER odoo

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo"]