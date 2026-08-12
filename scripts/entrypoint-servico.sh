#!/bin/bash

set -Eeuo pipefail

WORKROOT='/work'
REPOROOT='/work/repositorios'
STATE_DIR='/work/.estado'
SBOPKG_LIB='/work/cache/sbopkg-lib'
SBOPKG_CACHE='/work/cache/sbopkg-fontes'
TLS_DIR='/work/.estado/tls'
BROWSER_SLACKBUILDS=${BROWSER_SLACKBUILDS_ROOT:-/run/slackrepo-rotinas/slackbuilds}

log()
{
    printf '%s\n' "[servico] $*"
}

prepare_persistent_directories()
{
    mkdir -p "$REPOROOT" "$WORKROOT/resultados" "$WORKROOT/falhas" \
        "$WORKROOT/ignorados" "$WORKROOT/cache" "$WORKROOT/logs" \
        "$STATE_DIR" "$SBOPKG_LIB" "$SBOPKG_CACHE" "$TLS_DIR" \
        "/work/repositorios/navegadores/15.0/packages" \
        "/work/repositorios/navegadores/15.0/metadata" /run/httpd

    if [ ! -e "$SBOPKG_LIB/.inicializado" ]; then
        log 'Inicializando a arvore SBo persistente a partir da imagem.'
        cp -a /opt/sbopkg-seed/. "$SBOPKG_LIB/"
        : > "$SBOPKG_LIB/.inicializado"
    fi

    rm -rf /var/lib/sbopkg /var/cache/sbopkg
    ln -s "$SBOPKG_LIB" /var/lib/sbopkg
    ln -s "$SBOPKG_CACHE" /var/cache/sbopkg
    mkdir -p /var/lib/sbopkg/queues /tmp/SBo
    chmod 1777 /tmp

    /usr/local/sbin/gerar-indice-repositorio \
        /work/repositorios/navegadores/15.0 >/dev/null
}

prepare_tls()
{
    if [ ! -s "$TLS_DIR/repositorio.crt" ] || [ ! -s "$TLS_DIR/repositorio.key" ]; then
        local subject_alt_name='DNS:slackware-repositorio-local,IP:127.0.0.1'
        local address
        IFS=',' read -r -a addresses <<< "${REPO_TLS_IPS:-}"
        for address in "${addresses[@]}"; do
            [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            subject_alt_name+=",IP:$address"
        done
        log 'Gerando certificado HTTPS local. Clientes precisarao confiar neste certificado.'
        openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
            -subj '/CN=slackware-repositorio-local' \
            -addext "subjectAltName=$subject_alt_name" \
            -keyout "$TLS_DIR/repositorio.key" \
            -out "$TLS_DIR/repositorio.crt" >/dev/null 2>&1
        chmod 0600 "$TLS_DIR/repositorio.key"
        chmod 0644 "$TLS_DIR/repositorio.crt"
    fi

    ln -sf "$TLS_DIR/repositorio.crt" /etc/httpd/repositorio.crt
    ln -sf "$TLS_DIR/repositorio.key" /etc/httpd/repositorio.key
}

prepare_httpd()
{
    prepare_tls
    if ! grep -Fq 'ServerName slackware-repositorio-local' /etc/httpd/httpd.conf; then
        printf '\nServerName slackware-repositorio-local\n' >> /etc/httpd/httpd.conf
    fi

    sed -i \
        -e 's@^#LoadModule ssl_module@LoadModule ssl_module@' \
        -e 's@^#LoadModule socache_shmcb_module@LoadModule socache_shmcb_module@' \
        -e 's#^DocumentRoot ".*"#DocumentRoot "/work/repositorios"#' \
        -e 's#^<Directory "/srv/httpd/htdocs">#<Directory "/work/repositorios">#' \
        /etc/httpd/httpd.conf

    if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/httpd/extra/repositorio-ssl.conf' \
        /etc/httpd/httpd.conf; then
        cat >> /etc/httpd/httpd.conf <<'EOF'

<Directory "/work/repositorios">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
Include /etc/httpd/extra/repositorio-ssl.conf
EOF
    fi

    httpd -t
    httpd -M 2>/dev/null | grep -q 'ssl_module' || {
        log 'Modulo SSL do Apache nao foi carregado.'
        return 1
    }
}

self_test()
{
    test -r /etc/slackware-version
    grep -q '^Slackware 15\.0' /etc/slackware-version
    command -v httpd >/dev/null
    command -v rsync >/dev/null
    command -v sbopkg >/dev/null
    command -v gpg >/dev/null
    command -v gerenciar-repositorios >/dev/null
    command -v atualizar-navegadores >/dev/null
    test -d /opt/sbopkg-seed
    test -x "$BROWSER_SLACKBUILDS/brave-browser/brave-browser.SlackBuild"
    test -x "$BROWSER_SLACKBUILDS/google-chrome/google-chrome.SlackBuild"
    /usr/local/bin/atualizar-navegadores --self-test
    /usr/local/bin/gerenciar-repositorios --self-test
    printf '%s\n' 'SELF-TESTE DO SERVICO OK'
}

case "${1:-}" in
    --self-test)
        self_test
        exit 0
        ;;
    --gerenciar)
        shift
        prepare_persistent_directories
        exec /usr/local/bin/gerenciar-repositorios "$@"
        ;;
    '') ;;
    *)
        exec "$@"
        ;;
esac

prepare_persistent_directories
prepare_httpd
log 'Iniciando o verificador diario de Brave Stable e Google Chrome Stable.'
/usr/local/sbin/verificar-navegadores-diariamente &
log 'Apache iniciado: HTTP/80 e HTTPS/443.'
exec /usr/sbin/httpd -DFOREGROUND
