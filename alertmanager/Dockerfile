# Alertmanager does not expand environment variables in its configuration file
# and the upstream image is busybox only, so envsubst is not available there.
# This image keeps the upstream binaries and adds envsubst (gettext) so that
# entrypoint.sh can render alertmanager.yml.tmpl at start-up.

FROM prom/alertmanager:v0.34.1 AS upstream

FROM alpine:3.24.2

RUN apk add --no-cache ca-certificates gettext-envsubst tzdata \
    && mkdir -p /etc/alertmanager/templates /alertmanager \
    && chown -R nobody:nobody /etc/alertmanager /alertmanager

COPY --from=upstream /bin/alertmanager /bin/amtool /bin/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER nobody
WORKDIR /alertmanager
EXPOSE 9093

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--storage.path=/alertmanager"]
