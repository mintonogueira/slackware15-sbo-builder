#!/bin/bash

# Bootstrap minimo e imutavel. Os scripts operacionais e os SlackBuilds
# personalizados sao carregados exclusivamente dos volumes persistentes.

set -Eeuo pipefail

WORKROOT=${WORKROOT:-/work}
ROUTINES_ROOT=${ROTINAS_ROOT:-$WORKROOT/rotinas}
CUSTOM_ROOT=${SLACKBUILDS_PERSONALIZADOS_ROOT:-$WORKROOT/slackbuilds-personalizados}
ACTIVE_ROOT=${ROTINAS_ATIVAS_ROOT:-/run/slackrepo-rotinas}

log()
{
    printf '%s\n' "[rotinas] $*"
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

safe_path()
{
    local kind=$1
    local relative=$2
    case "$kind" in
        routines) [[ "$relative" =~ ^scripts/[A-Za-z0-9+_.-]+\.sh$ ]] ;;
        slackbuilds) [[ "$relative" =~ ^[A-Za-z0-9+_.-]+/[A-Za-z0-9+_.-]+$ ]] ;;
        *) return 1 ;;
    esac
}

active_path()
{
    case "$1" in
        routines) printf '%s/%s\n' "$ACTIVE_ROOT" "$2" ;;
        slackbuilds) printf '%s/slackbuilds/%s\n' "$ACTIVE_ROOT" "$2" ;;
        *) return 1 ;;
    esac
}

sha256_matches()
{
    local file=$1
    local expected=$2
    local actual

    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    [ -s "$file" ] || return 1
    actual=$(sha256sum "$file" | awk '{print $1}')
    [ "${actual,,}" = "${expected,,}" ]
}

verify_sha256()
{
    sha256_matches "$1" "$2" || die "integridade SHA-256 falhou: $1"
}

install_active_file()
{
    local source=$1
    local relative=$2
    local kind=$3
    local destination

    safe_path "$kind" "$relative" ||
        die "caminho nao permitido no conjunto $kind: $relative"
    destination=$(active_path "$kind" "$relative")
    mkdir -p "$(dirname "$destination")"
    cp -p "$source" "$destination"
    case "$destination" in
        *.sh|*.SlackBuild) chmod 0755 "$destination" ;;
        *) chmod 0644 "$destination" ;;
    esac
}

list_source_files()
{
    local root=$1
    local kind=$2
    case "$kind" in
        routines)
            (cd "$root" && find scripts -type f -printf '%p\n' | LC_ALL=C sort)
            ;;
        slackbuilds)
            find "$root" -mindepth 2 -maxdepth 2 -type f \
                ! -path "$root/cache/*" -printf '%P\n' | LC_ALL=C sort
            ;;
    esac
}

apply_local_manifest()
{
    local root=$1
    local kind=$2
    local manifest="$root/SHA256SUMS"
    local expected relative remainder source count=0 line_number=0
    local actual_list manifest_list

    [ -s "$manifest" ] || die "$manifest esta ausente ou vazio"
    actual_list=$(mktemp /tmp/rotinas-reais.XXXXXX)
    manifest_list=$(mktemp /tmp/rotinas-manifesto.XXXXXX)
    list_source_files "$root" "$kind" > "$actual_list"

    log "Validando o conjunto local: $root"
    while read -r expected relative remainder || [ -n "$expected$relative${remainder:-}" ]; do
        line_number=$((line_number + 1))
        case "$expected" in ''|'#'*) continue ;; esac
        [ -z "${remainder:-}" ] ||
            die "$manifest linha $line_number possui campos excedentes"
        relative=${relative#\*}
        safe_path "$kind" "$relative" ||
            die "$manifest linha $line_number possui caminho invalido: $relative"
        source="$root/$relative"
        verify_sha256 "$source" "$expected"
        install_active_file "$source" "$relative" "$kind"
        printf '%s\n' "$relative" >> "$manifest_list"
        count=$((count + 1))
    done < "$manifest"

    LC_ALL=C sort -u -o "$manifest_list" "$manifest_list"
    if ! cmp -s "$actual_list" "$manifest_list"; then
        printf '%s\n' "ERRO: $manifest nao corresponde exatamente aos arquivos." >&2
        diff -u "$manifest_list" "$actual_list" >&2 || :
        rm -f "$actual_list" "$manifest_list"
        exit 1
    fi
    rm -f "$actual_list" "$manifest_list"
    [ "$count" -gt 0 ] || die "$manifest nao contem arquivos"
    log "$count arquivo(s) validado(s) em $root."
}

download_verified_links()
{
    local root=$1
    local kind=$2
    local links="$root/links.conf"
    local cache="$root/cache/remotas"
    local line_number=0 expected relative url cached partial remainder

    [ -s "$links" ] || return 0
    log "Processando links verificados de $links."
    while IFS='|' read -r expected relative url remainder ||
        [ -n "$expected$relative$url${remainder:-}" ]; do
        line_number=$((line_number + 1))
        expected=${expected//[[:space:]]/}
        relative=${relative#${relative%%[![:space:]]*}}
        relative=${relative%${relative##*[![:space:]]}}
        url=${url#${url%%[![:space:]]*}}
        url=${url%${url##*[![:space:]]}}

        case "$expected" in ''|'#'*) continue ;; esac
        [ -z "${remainder:-}" ] || die "$links linha $line_number possui campos excedentes"
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "$links linha $line_number possui SHA-256 invalido"
        safe_path "$kind" "$relative" || die "$links linha $line_number possui caminho invalido: $relative"
        [[ "$url" == https://* ]] || die "$links linha $line_number deve usar HTTPS"

        cached="$cache/$relative"
        mkdir -p "$(dirname "$cached")"
        if sha256_matches "$cached" "$expected"; then
            log "Cache remoto verificado: $relative"
        else
            partial="${cached}.parcial.$$"
            rm -f "$partial"
            log "Baixando e validando: $url"
            if ! wget --https-only --timeout=90 --tries=3 --no-verbose -O "$partial" "$url"; then
                rm -f "$partial"
                die "link indisponivel e sem cache valido: $url"
            fi
            verify_sha256 "$partial" "$expected"
            mv "$partial" "$cached"
        fi
        install_active_file "$cached" "$relative" "$kind"
    done < "$links"
}

require_active_files()
{
    local required
    for required in \
        scripts/entrypoint-servico.sh \
        scripts/gerenciar-repositorios.sh \
        scripts/gerar-indice-repositorio.sh \
        scripts/atualizar-navegadores.sh \
        scripts/verificar-navegadores-diariamente.sh \
        slackbuilds/brave-browser/brave-browser.SlackBuild \
        slackbuilds/google-chrome/google-chrome.SlackBuild; do
        [ -x "$ACTIVE_ROOT/$required" ] || die "arquivo obrigatorio ausente ou nao executavel: $required"
    done
}

publish_active_manifest()
{
    (
        cd "$ACTIVE_ROOT"
        find scripts slackbuilds -type f -print0 |
            LC_ALL=C sort -z |
            xargs -0 sha256sum > "$WORKROOT/.estado/rotinas-ativas.sha256"
    )
    date -u +%Y-%m-%dT%H:%M:%SZ > "$WORKROOT/.estado/rotinas-ativadas-em"
}

source_fingerprint()
{
    {
        printf '%s\n' '[rotinas/scripts]'
        (cd "$ROUTINES_ROOT" && find scripts -type f -print0 |
            LC_ALL=C sort -z | xargs -0 sha256sum)
        printf '%s\n' '[rotinas/controle]'
        sha256sum "$ROUTINES_ROOT/SHA256SUMS" | awk '{print $1 " SHA256SUMS"}'
        if [ -f "$ROUTINES_ROOT/links.conf" ]; then
            sha256sum "$ROUTINES_ROOT/links.conf" | awk '{print $1 " links.conf"}'
        else
            printf '%s\n' 'links.conf ausente'
        fi
        printf '%s\n' '[slackbuilds-personalizados]'
        (cd "$CUSTOM_ROOT" && find . -mindepth 2 -maxdepth 2 -type f \
            ! -path './cache/*' -printf '%P\0' |
            LC_ALL=C sort -z | xargs -0 sha256sum)
        printf '%s\n' '[slackbuilds/controle]'
        sha256sum "$CUSTOM_ROOT/SHA256SUMS" | awk '{print $1 " SHA256SUMS"}'
        if [ -f "$CUSTOM_ROOT/links.conf" ]; then
            sha256sum "$CUSTOM_ROOT/links.conf" | awk '{print $1 " links.conf"}'
        else
            printf '%s\n' 'links.conf ausente'
        fi
    } | sha256sum | awk '{print $1}'
}

link_operational_commands()
{
    ln -sfn "$ACTIVE_ROOT/scripts/entrypoint-servico.sh" /usr/local/sbin/entrypoint-servico
    ln -sfn "$ACTIVE_ROOT/scripts/gerenciar-repositorios.sh" /usr/local/bin/gerenciar-repositorios
    ln -sfn "$ACTIVE_ROOT/scripts/gerar-indice-repositorio.sh" /usr/local/sbin/gerar-indice-repositorio
    ln -sfn "$ACTIVE_ROOT/scripts/atualizar-navegadores.sh" /usr/local/bin/atualizar-navegadores
    ln -sfn "$ACTIVE_ROOT/scripts/verificar-navegadores-diariamente.sh" /usr/local/sbin/verificar-navegadores-diariamente
}

mkdir -p "$ROUTINES_ROOT/scripts" "$ROUTINES_ROOT/cache/remotas" \
    "$CUSTOM_ROOT/cache/remotas" "$WORKROOT/.estado"
rm -rf "$ACTIVE_ROOT"
mkdir -p "$ACTIVE_ROOT"
apply_local_manifest "$ROUTINES_ROOT" routines
apply_local_manifest "$CUSTOM_ROOT" slackbuilds
download_verified_links "$ROUTINES_ROOT" routines
download_verified_links "$CUSTOM_ROOT" slackbuilds
require_active_files
publish_active_manifest
source_fingerprint > "$WORKROOT/.estado/rotinas-fontes.sha256"
if [ "${ROTINAS_NAO_LINKAR:-0}" != 1 ]; then
    link_operational_commands
fi

export ROTINAS_ATIVAS_ROOT="$ACTIVE_ROOT"
export BROWSER_SLACKBUILDS_ROOT="$ACTIVE_ROOT/slackbuilds"
log 'Scripts e SlackBuilds personalizados preparados e validados.'
if [ "${1:-}" = '--preparar-rotinas-apenas' ]; then
    exit 0
fi
exec "$ACTIVE_ROOT/scripts/entrypoint-servico.sh" "$@"
