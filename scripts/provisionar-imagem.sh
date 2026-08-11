#!/bin/sh

# Executado somente pelo GitHub Actions ao produzir a imagem do GHCR.
# Nunca e executado pelo script de compilacao no computador hospedeiro.

set -eu

SLACKWARE_MIRROR='https://download.salixos.org/x86_64/slackware-15.0/'
SALIX_REPOSITORY='https://download.salixos.org/x86_64/15.0/'
SALIX_SBO='https://download.salixos.org/sbo/15.0/'
SLACKWARE_KEY_FINGERPRINT='EC5649DA401E22ABFA6736EF6A4463C040102233'
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
        fi
        if [ "$attempt" -ge 3 ]; then
            return 1
        fi
        log "Tentativa ${attempt} falhou; limpando cache e repetindo."
        rm -rf /var/cache/packages/* 2>/dev/null || :
        attempt=$((attempt + 1))
        sleep 5
    done
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
    retry wget -q -O "$gpg_key" "${SLACKWARE_MIRROR}GPG-KEY"
    gpg --homedir "$verify_home" --batch --import "$gpg_key" >/dev/null 2>&1

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
    gpg --homedir "$slackpkg_gpg_home" --batch --import "$gpg_key" >/dev/null 2>&1
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
    wget -q -O "$package_file" "$base_url"
    wget -q -O "$checksum_file" "${base_url%/*}/$(basename "$relative_path" | sed 's/\.[^.]*$/.md5/')"

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
    log 'Instalando slapt-get, slapt-src, fakeroot e spkg.'
    wget -q -O /tmp/salix-PACKAGES.TXT "${SALIX_REPOSITORY}PACKAGES.TXT"
    install_salix_package fakeroot
    install_salix_package spkg
    install_salix_package slapt-get
    install_salix_package slapt-src

    mkdir -p /etc/slapt-get /usr/src/slapt-src /var/lib/slackbuild-builder
    cat > /etc/slapt-get/slapt-srcrc <<EOF
BUILDDIR=/usr/src/slapt-src
PKGEXT=txz
SOURCE=${SALIX_SBO}
EOF

    slapt-src --yes --update
    wget -q -O /var/lib/slackbuild-builder/SLACKBUILDS.TXT \
        "${SALIX_SBO}SLACKBUILDS.TXT"
    rm -f /tmp/salix-PACKAGES.TXT
}

install_sbopkg()
{
    log "Instalando sbopkg ${SBOPKG_VERSION} e sqg."
    wget -q -O /tmp/sbopkg.tgz "$SBOPKG_URL"
    actual=$(sha256sum /tmp/sbopkg.tgz | awk '{ print $1 }')
    if [ "$actual" != "$SBOPKG_SHA256" ]; then
        log 'Checksum SHA-256 invalido para o sbopkg.'
        exit 1
    fi
    upgradepkg --install-new /tmp/sbopkg.tgz
    rm -f /tmp/sbopkg.tgz

    mkdir -p /var/lib/sbopkg/queues /var/cache/sbopkg /var/log/sbopkg /tmp/SBo
    log 'Sincronizando a colecao 15.0 usada pelo sbopkg e pelo sqg.'
    sbopkg -r
}

finalize_image()
{
    log 'Removendo caches de instalacao da camada final.'
    rm -rf /var/cache/packages/* /var/cache/slackpkg/* /tmp/*
    mkdir -p /tmp/SBo /work /usr/src/slapt-src /var/lib/slackbuild-builder
    chmod 1777 /tmp

    test -x /usr/sbin/sbopkg
    test -x /usr/sbin/sqg
    test -x /usr/sbin/slapt-src
    test -s /var/lib/slackbuild-builder/SLACKBUILDS.TXT
    printf '%s\n' 'Slackware 15.0 SBo Builder' > /etc/slackbuild-builder-release
}

if [ "$(uname -m)" != 'x86_64' ]; then
    log 'Esta imagem deve ser produzida para x86_64.'
    exit 1
fi

configure_slackpkg
install_full_slackware
install_salix_tools
install_sbopkg
finalize_image
log 'Imagem pronta.'
