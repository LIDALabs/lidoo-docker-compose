all: image

image:
	docker build -t odoo-lida:17 .