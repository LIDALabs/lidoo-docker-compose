FROM odoo:17

USER root

COPY ./config/requirements.txt /etc/odoo/requirements.txt
# install python packages
RUN pip3 install pip --upgrade \
    && pip3 install -r /etc/odoo/requirements.txt

COPY ./addons/ /mnt/extra-addons
COPY ./l10_ve/ /mnt/l10n_ve_addons

# Set permissions and Mount /var/lib/odoo to allow restoring filestore and /mnt/extra-addons for users addons
RUN chown odoo /etc/odoo/odoo.conf \
    && chown -R odoo /mnt/extra-addons \
    && chown -R odoo /mnt/l10n_ve_addons
VOLUME ["/var/lib/odoo", "/mnt/l10n_ve_addons", "/mnt/extra-addons"]

# Set default user when running the container
USER odoo

ENTRYPOINT ["/entrypoint.sh"]
CMD ["odoo"]