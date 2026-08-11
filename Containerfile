FROM docker.io/vbatts/slackware:15.0@sha256:93515a709cf6f12ca093f728b3716afad40b9ed92198feb439e939e6859e0df7

ARG SOURCE_REPOSITORY="https://github.com/mintonogueira/slackware15-sbo-builder"
ARG BUILD_REVISION="desconhecida"

LABEL org.opencontainers.image.title="Slackware 15 SBo Builder" \
      org.opencontainers.image.description="Slackware 15.0 com ambiente de compilacao, sbopkg, sqg e slapt-src prontos" \
      org.opencontainers.image.source="${SOURCE_REPOSITORY}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# O certificado vem do runner somente para inicializar o HTTPS da imagem
# antiga. O provisionamento regenera a cadeia usando o pacote do Slackware.
COPY build/bootstrap-ca.crt /etc/ssl/certs/ca-certificates.crt
COPY scripts/provisionar-imagem.sh /usr/local/sbin/provisionar-imagem
COPY scripts/executar-compilacao.sh /usr/local/bin/executar-compilacao

RUN chmod 0755 /usr/local/sbin/provisionar-imagem \
        /usr/local/bin/executar-compilacao \
    && /usr/local/sbin/provisionar-imagem \
    && rm -f /usr/local/sbin/provisionar-imagem

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/executar-compilacao"]
