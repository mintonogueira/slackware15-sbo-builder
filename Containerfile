FROM docker.io/vbatts/slackware:15.0@sha256:93515a709cf6f12ca093f728b3716afad40b9ed92198feb439e939e6859e0df7

ARG SOURCE_REPOSITORY="https://github.com/mintonogueira/slackware15-sbo-builder"
ARG BUILD_REVISION="desconhecida"

LABEL org.opencontainers.image.title="Slackware 15 Repository Builder" \
      org.opencontainers.image.description="Espelho Slackware/Salix, compilador SBo completo e repositorio HTTP/HTTPS" \
      org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Certificado temporario usado somente para inicializar HTTPS na imagem-base.
COPY build/bootstrap-ca.crt /etc/ssl/certs/ca-certificates.crt
COPY scripts/provisionar-imagem.sh /usr/local/sbin/provisionar-imagem
COPY scripts/inicializar-rotinas.sh /usr/local/sbin/inicializar-rotinas
COPY config/repositorio-ssl.conf /etc/httpd/extra/repositorio-ssl.conf

RUN chmod 0755 \
        /usr/local/sbin/provisionar-imagem \
        /usr/local/sbin/inicializar-rotinas \
    && /usr/local/sbin/provisionar-imagem \
    && rm -f /usr/local/sbin/provisionar-imagem

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ROTINAS_ROOT=/work/rotinas \
    SLACKBUILDS_PERSONALIZADOS_ROOT=/work/slackbuilds-personalizados \
    ROTINAS_ATIVAS_ROOT=/run/slackrepo-rotinas \
    BROWSER_SLACKBUILDS_ROOT=/run/slackrepo-rotinas/slackbuilds \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPOSE 80 443
VOLUME ["/work"]
WORKDIR /work
ENTRYPOINT ["/usr/local/sbin/inicializar-rotinas"]
