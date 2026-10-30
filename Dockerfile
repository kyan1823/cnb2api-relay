# Fixed-domain relay for cnb2api: nginx + the self-registration endpoint in one
# container. Configuration (vhost, TLS material, REG_TOKEN) is bind-mounted by
# docker-compose.yml; only the two scripts are baked in.
#
#   docker compose up -d --build
FROM alpine:latest

RUN apk add --no-cache nginx python3 tini curl openssl \
    && mkdir -p /run/nginx /etc/nginx/ssl /root/.cnb /var/www/certbot \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

COPY cnb-register.py /usr/local/bin/cnb-register.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh /usr/local/bin/cnb-register.py

EXPOSE 80 443
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
