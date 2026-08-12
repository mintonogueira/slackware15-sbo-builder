#!/bin/sh

# Executado somente pelo GitHub Actions ao produzir a imagem do GHCR.
# Nunca e executado pelo script de compilacao no computador hospedeiro.

set -eu

SLACKWARE_MIRROR='https://download.salixos.org/x86_64/slackware-15.0/'
SALIX_REPOSITORY='https://download.salixos.org/x86_64/15.0/'
SALIX_SBO='https://download.salixos.org/sbo/15.0/'
SLACKWARE_KEY_FINGERPRINT='EC5649DA401E22ABFA6736EF6A4463C040102233'
CA_BUNDLE='/etc/ssl/certs/ca-certificates.crt'
SBOPKG_VERSION='0.38.3'
SBOPKG_SHA256='b8de23f069ee48800e198007ba25df25bfa8f92ff5705e852b1b1cab58523355'
SBOPKG_URL="https://github.com/sbopkg/sbopkg/releases/download/${SBOPKG_VERSION}/sbopkg-${SBOPKG_VERSION}-noarch-1_wsr.tgz"

log()
{
    printf '%s\n' "[imagem] $*"
}

retry()
{
    attempt=1
    while :; do
        if "$@"; then
            return 0
        else
            status=$?
        fi
        log "Tentativa ${attempt}/3 falhou (codigo ${status})."
        if [ "$attempt" -ge 3 ]; then
            log 'As tres tentativas falharam; interrompendo a criacao da imagem.'
            return "$status"
        fi
        rm -rf /var/cache/packages/* 2>/dev/null || :
        attempt=$((attempt + 1))
        log "Nova tentativa em 5 segundos."
        sleep 5
    done
}

download()
{
    destination=$1
    url=$2

    log "Baixando ${url}"
    retry wget \
        --ca-certificate="$CA_BUNDLE" \
        --timeout=60 \
        --tries=1 \
        --no-verbose \
        -O "$destination" \
        "$url"
}

configure_https()
{
    log 'Validando as ferramentas e o certificado HTTPS de inicializacao.'
    for required_command in wget gpg slackpkg awk sed md5sum sha256sum; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            log "Ferramenta ausente na imagem-base: ${required_command}"
            exit 1
        fi
    done

    if [ ! -s "$CA_BUNDLE" ]; then
        log "Certificado HTTPS ausente ou vazio: ${CA_BUNDLE}"
        exit 1
    fi

    mkdir -p /etc
    if [ -f /etc/wgetrc ]; then
        sed -i \
            -e '/^[[:space:]]*ca_certificate[[:space:]]*=/d' \
            -e '/^[[:space:]]*check_certificate[[:space:]]*=/d' \
            /etc/wgetrc
    else
        : > /etc/wgetrc
    fi
    {
        printf '\n'
        printf '%s\n' "ca_certificate = ${CA_BUNDLE}"
        printf '%s\n' 'check_certificate = on'
    } >> /etc/wgetrc

    SSL_CERT_FILE=$CA_BUNDLE
    export SSL_CERT_FILE
}

configure_slackpkg()
{
    log 'Configurando o espelho fixo do Slackware 15.0.'
    mkdir -p /etc/slackpkg /var/cache/packages
    printf '%s\n' "$SLACKWARE_MIRROR" > /etc/slackpkg/mirrors

    if [ -f /etc/slackpkg/slackpkg.conf ]; then
        sed -i \
            -e 's/^[[:space:]]*BATCH=.*/BATCH=on/' \
            -e 's/^[[:space:]]*DEFAULT_ANSWER=.*/DEFAULT_ANSWER=y/' \
            /etc/slackpkg/slackpkg.conf
    fi

    gpg_key='/tmp/slackware-GPG-KEY'
    verify_home='/tmp/slackware-gpg-verify'
    slackpkg_gpg_home='/etc/slackpkg/gpg'

    rm -rf "$verify_home"
    mkdir -p "$verify_home"
    chmod 0700 "$verify_home"
    download "$gpg_key" "${SLACKWARE_MIRROR}GPG-KEY"
    gpg --homedir "$verify_home" --batch --import "$gpg_key"

    fingerprint=$(gpg --homedir "$verify_home" \
        --with-colons --fingerprint 2>/dev/null |
        awk -F: '$1 == "fpr" { print $10; exit }')
    if [ "$fingerprint" != "$SLACKWARE_KEY_FINGERPRINT" ]; then
        log "Impressao digital inesperada da chave Slackware: ${fingerprint:-vazia}"
        exit 1
    fi

    rm -rf "$slackpkg_gpg_home"
    mkdir -p "$slackpkg_gpg_home"
    chmod 0700 "$slackpkg_gpg_home"
    gpg --homedir "$slackpkg_gpg_home" --batch --import "$gpg_key"
    rm -rf "$verify_home"
    rm -f "$gpg_key"

    retry slackpkg -batch=on -default_answer=y update
}

install_full_slackware()
{
    log 'Instalando o ambiente completo do Slackware 15.0.'
    for series in a ap d e f k kde l n t tcl x xap xfce y; do
        log "Instalando a serie ${series}."
        retry slackpkg -batch=on -default_answer=y install "$series"
    done

    retry slackpkg -batch=on -default_answer=y install-new
    retry slackpkg -batch=on -default_answer=y upgrade-all
    update-ca-certificates --fresh >/dev/null 2>&1 || :
}

salix_package_path()
{
    package_name=$1
    awk -v wanted="$package_name" '
        $1 == "PACKAGE" && $2 == "NAME:" {
            package = $3
            selected = index(package, wanted "-") == 1
            next
        }
        selected && $1 == "PACKAGE" && $2 == "LOCATION:" {
            location = $3
            sub(/^\.\//, "", location)
            print location "/" package
            exit
        }
    ' /tmp/salix-PACKAGES.TXT
}

install_salix_package()
{
    package_name=$1
    relative_path=$(salix_package_path "$package_name")
    if [ -z "$relative_path" ]; then
        log "Pacote Salix nao encontrado: $package_name"
        exit 1
    fi

    package_file=/tmp/$(basename "$relative_path")
    checksum_file="${package_file}.md5"
    base_url="${SALIX_REPOSITORY}${relative_path}"

    log "Instalando ${package_name} a partir do repositorio Salix."
    download "$package_file" "$base_url"
    download "$checksum_file" \
        "${base_url%/*}/$(basename "$relative_path" | sed 's/\.[^.]*$/.md5/')"

    expected=$(awk '{ print $1; exit }' "$checksum_file")
    actual=$(md5sum "$package_file" | awk '{ print $1 }')
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        log "Checksum invalido para $(basename "$package_file")."
        exit 1
    fi

    upgradepkg --install-new "$package_file"
    rm -f "$package_file" "$checksum_file"
}

install_salix_tools()
{
    log 'Instalando slapt-get, fakeroot, spkg e as ferramentas Salix.'
    download /tmp/salix-PACKAGES.TXT "${SALIX_REPOSITORY}PACKAGES.TXT"
    install_salix_package fakeroot
    install_salix_package spkg
    install_salix_package slapt-get
    install_salix_package slapt-src

    mkdir -p /etc/slapt-get /usr/src/slapt-src
    rm -f /tmp/salix-PACKAGES.TXT
}

install_sbopkg()
{
    log "Instalando sbopkg ${SBOPKG_VERSION} e sqg."
    download /tmp/sbopkg.tgz "$SBOPKG_URL"
    actual=$(sha256sum /tmp/sbopkg.tgz | awk '{ print $1 }')
    if [ "$actual" != "$SBOPKG_SHA256" ]; then
        log 'Checksum SHA-256 invalido para o sbopkg.'
        exit 1
    fi
    upgradepkg --install-new /tmp/sbopkg.tgz
    rm -f /tmp/sbopkg.tgz

    mkdir -p /var/lib/sbopkg/queues /var/cache/sbopkg /var/log/sbopkg /tmp/SBo
    log 'Sincronizando a colecao SBo 15.0 completa usada pelo sbopkg.'
    sbopkg -r
}

require_executable()
{
    command_name=$1
    command_path=$2

    if [ ! -x "$command_path" ]; then
        log "Validacao falhou: ${command_name} nao foi encontrado em ${command_path}."
        exit 1
    fi
    log "Validacao OK: ${command_name} esta em ${command_path}."
}

require_nonempty_file()
{
    file_name=$1
    file_path=$2

    if [ ! -s "$file_path" ]; then
        log "Validacao falhou: ${file_name} esta ausente ou vazio em ${file_path}."
        exit 1
    fi
    log "Validacao OK: ${file_name} esta em ${file_path}."
}

finalize_image()
{
    log 'Removendo caches de instalacao da camada final.'
    rm -rf /var/cache/packages/* /var/cache/slackpkg/* /tmp/*
    mkdir -p /tmp/SBo /work /usr/src/slapt-src /opt/sbopkg-seed
    chmod 1777 /tmp

    cp -a /var/lib/sbopkg/. /opt/sbopkg-seed/

    require_executable sbopkg /usr/sbin/sbopkg
    require_executable sqg /usr/sbin/sqg
    require_executable slapt-src /usr/bin/slapt-src
    require_executable httpd /usr/sbin/httpd
    require_executable rsync /usr/bin/rsync
    require_executable inicializar-rotinas \
        /usr/local/sbin/inicializar-rotinas
    printf '%s\n' 'Slackware 15.0 Repository Builder' > /etc/slackbuild-builder-release
}

if [ "$(uname -m)" != 'x86_64' ]; then
    log 'Esta imagem deve ser produzida para x86_64.'
    exit 1
fi

configure_https
configure_slackpkg
install_full_slackware
install_salix_tools
install_sbopkg
finalize_image
log 'Imagem pronta.'
