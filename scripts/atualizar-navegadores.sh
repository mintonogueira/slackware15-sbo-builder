#!/bin/bash

# Consulta as versoes Stable oficiais, executa os dois SlackBuilds somente
# quando necessario, instala o pacote atual no conteiner e mantem tres versoes.

set -Eeuo pipefail

WORKROOT=${WORKROOT:-/work}
BROWSER_REPO=${BROWSER_REPO:-$WORKROOT/repositorios/navegadores/15.0}
PACKAGES_DIR="$BROWSER_REPO/packages"
METADATA_DIR="$BROWSER_REPO/metadata"
CACHE_DIR=${BROWSER_CACHE_DIR:-$WORKROOT/cache/navegadores}
SLACKBUILDS_ROOT=${BROWSER_SLACKBUILDS_ROOT:-$WORKROOT/slackbuilds/navegadores}
STATE_DIR=${BROWSER_STATE_DIR:-$WORKROOT/.estado/navegadores}
LOCK_FILE=${BROWSER_LOCK_FILE:-$WORKROOT/.estado/navegadores.lock}
PKGTOOLS_LOCK=${PKGTOOLS_LOCK_FILE:-$WORKROOT/.estado/pkgtools.lock}
ARCH=x86_64
BUILD=1
TAG=_browser

SLACK_PACKAGE=''
VENDOR_PACKAGE=''
INDEX_URL=''
REPOSITORY_BASE=''
SLACKBUILD=''
UPSTREAM_VERSION=''
SOURCE_FILENAME=''
SOURCE_SHA256=''
SOURCE_URL=''
VERSION=''
STATUS_TRACKING=0

log()
{
    printf '%s\n' "[navegadores] $*"
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

record_exit_status()
{
    local rc=$?
    if [ "$STATUS_TRACKING" -eq 1 ]; then
        if [ "$rc" -eq 0 ]; then
            printf '%s\n' 'SUCESSO' > "$STATE_DIR/status-ultima-tentativa"
        else
            printf 'FALHA (%s)\n' "$rc" > "$STATE_DIR/status-ultima-tentativa"
        fi
    fi
    return "$rc"
}

trap record_exit_status EXIT

usage()
{
    cat <<'EOF'
Uso interno:
  atualizar-navegadores --todos
  atualizar-navegadores --brave
  atualizar-navegadores --google-chrome
  atualizar-navegadores --self-test
EOF
}

configure_browser()
{
    case "$1" in
        brave)
            SLACK_PACKAGE=brave-browser
            VENDOR_PACKAGE=brave-browser
            INDEX_URL='https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages'
            REPOSITORY_BASE='https://brave-browser-apt-release.s3.brave.com'
            SLACKBUILD="$SLACKBUILDS_ROOT/brave-browser/brave-browser.SlackBuild"
            ;;
        google-chrome)
            SLACK_PACKAGE=google-chrome
            VENDOR_PACKAGE=google-chrome-stable
            INDEX_URL='https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages'
            REPOSITORY_BASE='https://dl.google.com/linux/chrome/deb'
            SLACKBUILD="$SLACKBUILDS_ROOT/google-chrome/google-chrome.SlackBuild"
            ;;
        *) die "navegador desconhecido: $1" ;;
    esac
}

download()
{
    local destination=$1
    local url=$2
    local partial="${destination}.parcial.$$"

    rm -f "$partial"
    wget --https-only --timeout=90 --tries=3 --no-verbose \
        -O "$partial" "$url"
    mv "$partial" "$destination"
}

read_package_record()
{
    local index_file=$1
    local wanted=$2

    awk -v wanted="$wanted" '
        BEGIN { RS=""; FS="\n" }
        {
            package=""; version=""; filename=""; checksum=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^Package:[[:space:]]*/) {
                    package=$i; sub(/^Package:[[:space:]]*/, "", package)
                } else if ($i ~ /^Version:[[:space:]]*/) {
                    version=$i; sub(/^Version:[[:space:]]*/, "", version)
                } else if ($i ~ /^Filename:[[:space:]]*/) {
                    filename=$i; sub(/^Filename:[[:space:]]*/, "", filename)
                } else if ($i ~ /^SHA256:[[:space:]]*/) {
                    checksum=$i; sub(/^SHA256:[[:space:]]*/, "", checksum)
                }
            }
            if (package == wanted) {
                printf "%s\t%s\t%s\n", version, filename, checksum
                exit
            }
        }
    ' "$index_file"
}

normalize_version()
{
    printf '%s\n' "$1" |
        sed -e 's/^[0-9][0-9]*://' -e 's/[-:~]/_/g'
}

fetch_official_metadata()
{
    local index_file="$CACHE_DIR/indices/${SLACK_PACKAGE}.Packages"
    mkdir -p "$(dirname "$index_file")"

    log "Consultando a versao Stable oficial de $SLACK_PACKAGE."
    download "$index_file" "$INDEX_URL"
    IFS=$'\t' read -r UPSTREAM_VERSION SOURCE_FILENAME SOURCE_SHA256 < <(
        read_package_record "$index_file" "$VENDOR_PACKAGE"
    )

    [ -n "$UPSTREAM_VERSION" ] || die "versao de $VENDOR_PACKAGE ausente no indice oficial"
    [ -n "$SOURCE_FILENAME" ] || die "arquivo de $VENDOR_PACKAGE ausente no indice oficial"
    [[ "$UPSTREAM_VERSION" =~ ^[0-9A-Za-z.+:~_-]+$ ]] ||
        die "versao oficial invalida: $UPSTREAM_VERSION"
    [[ "$SOURCE_FILENAME" =~ ^[0-9A-Za-z./+_~-]+$ ]] ||
        die "caminho oficial invalido: $SOURCE_FILENAME"
    [[ "$SOURCE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] ||
        die "SHA-256 oficial invalido para $SLACK_PACKAGE"

    VERSION=$(normalize_version "$UPSTREAM_VERSION")
    [[ "$VERSION" =~ ^[0-9A-Za-z.+_]+$ ]] ||
        die "versao Slackware invalida: $VERSION"
    SOURCE_URL="${REPOSITORY_BASE%/}/${SOURCE_FILENAME#./}"
}

latest_local_version()
{
    local package_file filename version suffix
    suffix="-$ARCH-$BUILD$TAG.txz"
    shopt -s nullglob
    for package_file in "$PACKAGES_DIR/${SLACK_PACKAGE}-"*"$suffix"; do
        filename=$(basename "$package_file")
        version=${filename#"$SLACK_PACKAGE-"}
        version=${version%"$suffix"}
        printf '%s\n' "$version"
    done | LC_ALL=C sort -V | tail -n 1
    shopt -u nullglob
}

retain_three_versions()
{
    local package_file filename version suffix
    local count=0
    local row
    local -a records=()

    suffix="-$ARCH-$BUILD$TAG.txz"
    shopt -s nullglob
    for package_file in "$PACKAGES_DIR/${SLACK_PACKAGE}-"*"$suffix"; do
        filename=$(basename "$package_file")
        version=${filename#"$SLACK_PACKAGE-"}
        version=${version%"$suffix"}
        records+=("$version"$'\t'"$package_file")
    done
    shopt -u nullglob

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        count=$((count + 1))
        if [ "$count" -gt 3 ]; then
            package_file=${row#*$'\t'}
            version=${row%%$'\t'*}
            log "Removendo versao excedente: $(basename "$package_file")"
            rm -f -- "$package_file"
            rm -f -- "$CACHE_DIR/pacotes-originais/${SLACK_PACKAGE}_${version}_amd64.deb"
        fi
    done < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1Vr)
}

install_current_package()
{
    local package_file=$1
    local installed_log="/var/log/packages/$(basename "${package_file%.txz}")"

    if [ -f "$installed_log" ]; then
        log "$SLACK_PACKAGE $UPSTREAM_VERSION ja esta instalado no conteiner."
        return 0
    fi

    log "Instalando $SLACK_PACKAGE $UPSTREAM_VERSION no conteiner persistente."
    (
        flock 8
        /sbin/upgradepkg --install-new "$package_file"
    ) 8>"$PKGTOOLS_LOCK"
}

update_one()
{
    local browser=$1
    local local_version package_file source_file

    configure_browser "$browser"
    [ -x "$SLACKBUILD" ] || die "SlackBuild ausente ou nao executavel: $SLACKBUILD"
    fetch_official_metadata
    local_version=$(latest_local_version || :)

    log "Comparacao $SLACK_PACKAGE: local=${local_version:-nenhuma}; oficial=$VERSION ($UPSTREAM_VERSION)."
    package_file="$PACKAGES_DIR/$SLACK_PACKAGE-$VERSION-$ARCH-$BUILD$TAG.txz"
    source_file="$CACHE_DIR/pacotes-originais/${SLACK_PACKAGE}_${VERSION}_amd64.deb"

    if [ -s "$package_file" ] && tar -tf "$package_file" >/dev/null 2>&1; then
        log 'A versao oficial ja foi convertida; download e conversao foram ignorados.'
    else
        if [ -e "$package_file" ]; then
            log "Pacote local invalido; reconstruindo: $(basename "$package_file")"
            rm -f "$package_file"
        fi
        log "Nova versao detectada; executando $(basename "$SLACKBUILD")."
        mkdir -p "$(dirname "$source_file")" "$PACKAGES_DIR" "$METADATA_DIR"
        UPSTREAM_VERSION="$UPSTREAM_VERSION" \
        VERSION="$VERSION" \
        SOURCE_URL="$SOURCE_URL" \
        SOURCE_SHA256="$SOURCE_SHA256" \
        SOURCE_FILE="$source_file" \
        CACHE_DIR="$(dirname "$source_file")" \
        OUTPUT="$PACKAGES_DIR" \
        TMP="/tmp/browser-slackbuilds/$SLACK_PACKAGE" \
        ARCH="$ARCH" BUILD="$BUILD" TAG="$TAG" \
            "$SLACKBUILD"
    fi

    [ -s "$package_file" ] || die "o SlackBuild nao gerou o pacote esperado: $package_file"
    tar -tf "$package_file" >/dev/null || die "pacote Slackware invalido: $package_file"
    printf '%s\n' '' > "$METADATA_DIR/$SLACK_PACKAGE.requires"
    install_current_package "$package_file"
    retain_three_versions
    printf '%s\n' "$UPSTREAM_VERSION" > "$STATE_DIR/$SLACK_PACKAGE.version"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/$SLACK_PACKAGE.ultima-verificacao"
    log "$SLACK_PACKAGE concluido; tres versoes mais recentes serao preservadas."
}

self_test()
{
    local temporary record normalized retention_root
    temporary=$(mktemp /tmp/browser-index-test.XXXXXX)
    cat > "$temporary" <<'EOF'
Package: outro-pacote
Version: 1.0-1
Filename: pool/outro.deb
SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

Package: google-chrome-stable
Version: 140.0.7339.41-1
Filename: pool/main/g/google-chrome-stable/google.deb
SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
    record=$(read_package_record "$temporary" google-chrome-stable)
    rm -f "$temporary"
    [[ "$record" == 140.0.7339.41-1$'\t'pool/main/g/google-chrome-stable/google.deb$'\t'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] ||
        die 'autoteste do leitor de metadados falhou'
    normalized=$(normalize_version 140.0.7339.41-1)
    [ "$normalized" = 140.0.7339.41_1 ] || die 'autoteste da versao falhou'

    retention_root=$(mktemp -d /tmp/browser-retention-test.XXXXXX)
    PACKAGES_DIR="$retention_root/packages"
    CACHE_DIR="$retention_root/cache"
    SLACK_PACKAGE=google-chrome
    mkdir -p "$PACKAGES_DIR" "$CACHE_DIR/pacotes-originais"
    for normalized in 136.0_1 137.0_1 138.0_1 139.0_1 140.0_1; do
        : > "$PACKAGES_DIR/google-chrome-$normalized-x86_64-1_browser.txz"
        : > "$CACHE_DIR/pacotes-originais/google-chrome_${normalized}_amd64.deb"
    done
    retain_three_versions
    [ "$(find "$PACKAGES_DIR" -type f -name '*.txz' | wc -l)" -eq 3 ] ||
        die 'autoteste da retencao nao preservou exatamente tres pacotes'
    [ -e "$PACKAGES_DIR/google-chrome-140.0_1-x86_64-1_browser.txz" ] ||
        die 'autoteste da retencao removeu a versao mais recente'
    [ ! -e "$PACKAGES_DIR/google-chrome-136.0_1-x86_64-1_browser.txz" ] ||
        die 'autoteste da retencao preservou versao excedente'
    [ ! -e "$CACHE_DIR/pacotes-originais/google-chrome_136.0_1_amd64.deb" ] ||
        die 'autoteste da retencao nao limpou o cache excedente'
    rm -rf "$retention_root"
    printf '%s\n' 'SELF-TESTE DOS NAVEGADORES OK'
}

case "${1:-}" in
    --self-test)
        self_test
        exit 0
        ;;
    --todos|--brave|--google-chrome) ;;
    -h|--help|'') usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

for command_name in wget awk sed sha256sum tar flock sort; do
    command -v "$command_name" >/dev/null 2>&1 || die "comando ausente: $command_name"
done
mkdir -p "$PACKAGES_DIR" "$METADATA_DIR" "$CACHE_DIR" "$STATE_DIR"
if [ "${BROWSER_INTERNAL_LOCK_HELD:-0}" != 1 ]; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log 'Outra verificacao dos navegadores esta em andamento; aguardando a conclusao.'
        flock 9
    fi
fi
if [ "${BROWSER_INTERNAL_PARENT_RUN:-0}" != 1 ]; then
    STATUS_TRACKING=1
    date +%s > "$STATE_DIR/ultima-tentativa-epoch"
    printf '%s\n' 'EM_ANDAMENTO' > "$STATE_DIR/status-ultima-tentativa"
fi

case "$1" in
    --brave) update_one brave ;;
    --google-chrome) update_one google-chrome ;;
    --todos)
        failures=0
        set +e
        BROWSER_INTERNAL_LOCK_HELD=1 BROWSER_INTERNAL_PARENT_RUN=1 \
            "$0" --brave
        brave_rc=$?
        BROWSER_INTERNAL_LOCK_HELD=1 BROWSER_INTERNAL_PARENT_RUN=1 \
            "$0" --google-chrome
        google_rc=$?
        set -e
        [ "$brave_rc" -eq 0 ] || failures=$((failures + 1))
        [ "$google_rc" -eq 0 ] || failures=$((failures + 1))
        ;;
esac

/usr/local/sbin/gerar-indice-repositorio "$BROWSER_REPO"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/ultima-execucao"
if [ "${failures:-0}" -ne 0 ]; then
    die "$failures atualizacao(oes) de navegador falharam"
fi
log 'Verificacao dos navegadores concluida.'
