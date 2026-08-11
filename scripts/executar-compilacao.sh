#!/bin/bash

set -Eeuo pipefail

METADATA='/var/lib/slackbuild-builder/SLACKBUILDS.TXT'
SLAPT_CONFIG='/etc/slapt-get/slapt-srcrc'
BUILDROOT='/usr/src/slapt-src'
WORKROOT='/work'
PACKAGE=''
JOBS='1'
PARTIAL=''
FINAL=''
FAILURE=''
COMPLETED=0

usage()
{
    cat <<'EOF'
Uso interno:
  executar-compilacao --pacote NOME [--jobs NUMERO]
  executar-compilacao --self-test
EOF
}

log()
{
    printf '%s\n' "[compilador] $*"
}

metadata_field()
{
    local package_name=$1
    local field=$2
    awk -v wanted="$package_name" -v wanted_field="$field" '
        $0 == "SLACKBUILD NAME: " wanted { selected = 1; next }
        selected && index($0, wanted_field ":") == 1 {
            value = $0
            sub(/^[^:]*:[[:space:]]*/, "", value)
            print value
            exit
        }
        selected && /^SLACKBUILD NAME:/ { exit }
    ' "$METADATA"
}

package_exists()
{
    awk -v wanted="$1" '$0 == "SLACKBUILD NAME: " wanted { found = 1; exit } END { exit !found }' "$METADATA"
}

resolve_package()
{
    local package_name=$1
    local requirements
    local old_ifs
    local dependency

    if grep -Fqx "$package_name" "$VISITED"; then
        return 0
    fi
    if grep -Fqx "$package_name" "$STACK"; then
        log "Ciclo de dependencias detectado em: $package_name"
        return 1
    fi
    if ! package_exists "$package_name"; then
        log "SlackBuild nao encontrado no catalogo Salix SBo: $package_name"
        return 1
    fi

    printf '%s\n' "$package_name" >> "$STACK"
    requirements=$(metadata_field "$package_name" 'SLACKBUILD REQUIRES')
    old_ifs=$IFS
    IFS=', '
    for dependency in $requirements; do
        case "$dependency" in
            '' ) ;;
            '%README%' )
                log "$package_name exige leitura e decisao manual indicada por %README%."
                return 1
                ;;
            * ) resolve_package "$dependency" ;;
        esac
    done
    IFS=$old_ifs

    grep -Fvx "$package_name" "$STACK" > "${STACK}.new" || :
    mv "${STACK}.new" "$STACK"
    printf '%s\n' "$package_name" >> "$VISITED"
    printf '%s\n' "$package_name" >> "$QUEUE"
}

find_built_package()
{
    local package_name=$1
    local marker=$2
    find "$PACKAGE_TEMP" "$BUILDROOT" /tmp \
        -type f -newer "$marker" \
        \( -name "${package_name}-*.txz" -o -name "${package_name}-*.tgz" \) \
        -print 2>/dev/null | head -n 1
}

copy_sources()
{
    local package_name=$1
    local location
    local source_dir
    local destination

    location=$(metadata_field "$package_name" 'SLACKBUILD LOCATION')
    location=${location#./}
    source_dir="${BUILDROOT}/${location}"
    destination="${PARTIAL}/fontes/${package_name}"

    mkdir -p "$destination"
    if [ -d "$source_dir" ]; then
        cp -a "$source_dir"/. "$destination"/
    else
        log "Diretorio de fontes nao localizado para $package_name: $source_dir"
        return 1
    fi
}

build_one()
{
    local package_name=$1
    local is_final=$2
    local marker
    local package_file
    local destination

    marker=$(mktemp /tmp/slackbuild-marker.XXXXXX)

    log "Compilando ${package_name}."
    TMP="/tmp/SBo-${package_name}" \
    OUTPUT="$PACKAGE_TEMP" \
    MAKEFLAGS="-j${JOBS}" \
    NUMJOBS="-j${JOBS}" \
        slapt-src --yes --no-dep --config="$SLAPT_CONFIG" --build "$package_name"

    package_file=$(find_built_package "$package_name" "$marker")
    rm -f "$marker"
    if [ -z "$package_file" ] || [ ! -f "$package_file" ]; then
        log "O pacote binario de $package_name nao foi localizado."
        return 1
    fi

    destination="${PARTIAL}/pacotes/$(basename "$package_file")"
    cp -p "$package_file" "$destination"
    printf '%s\n' "$(basename "$destination")" >> "${PARTIAL}/ORDEM_INSTALACAO.txt"
    copy_sources "$package_name"

    if [ "$is_final" -eq 0 ]; then
        log "Instalando ${package_name} somente no conteiner descartavel."
        installpkg "$destination"
    fi
}

write_installer()
{
    cat > "${PARTIAL}/instalar.sh" <<'EOF'
#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'ERRO: execute este instalador como root.' >&2
    exit 1
fi

if [ ! -r /etc/slackware-version ] ||
   ! grep -q '^Slackware 15\.0' /etc/slackware-version; then
    printf '%s\n' 'ERRO: este conjunto foi criado para Slackware 15.0.' >&2
    exit 1
fi

if [ "$(uname -m)" != 'x86_64' ]; then
    printf '%s\n' 'ERRO: este conjunto foi criado para x86_64.' >&2
    exit 1
fi

cd "$SCRIPT_DIR"
sha256sum -c CKSUMS.sha256

while IFS= read -r package_file; do
    [ -n "$package_file" ] || continue
    case "$package_file" in
        */*|.*)
            printf '%s\n' "ERRO: nome de pacote invalido: $package_file" >&2
            exit 1
            ;;
    esac
    if [ ! -f "pacotes/$package_file" ]; then
        printf '%s\n' "ERRO: pacote ausente: pacotes/$package_file" >&2
        exit 1
    fi
    printf '%s\n' "Instalando $package_file"
    /sbin/upgradepkg --install-new "pacotes/$package_file"
done < ORDEM_INSTALACAO.txt

printf '%s\n' 'Instalacao concluida.'
EOF
    chmod 0755 "${PARTIAL}/instalar.sh"
}

finish()
{
    local rc=$?
    trap - EXIT INT TERM

    if [ -n "$PARTIAL" ] && [ -d "$PARTIAL" ]; then
        if [ "$rc" -eq 0 ] && [ "$COMPLETED" -eq 1 ]; then
            printf '%s\n' 'SUCESSO' > "${PARTIAL}/STATUS"
            mkdir -p "$(dirname "$FINAL")"
            mv "$PARTIAL" "$FINAL"
            printf '%s\n' "Conjunto concluido: $FINAL"
        else
            printf '%s\n' 'FALHA' > "${PARTIAL}/STATUS"
            mkdir -p "$(dirname "$FAILURE")"
            mv "$PARTIAL" "$FAILURE" 2>/dev/null || :
            printf '%s\n' "Tentativa malsucedida preservada em: $FAILURE" >&2
        fi
    fi
    exit "$rc"
}

self_test()
{
    test -r /etc/slackware-version
    grep -q '^Slackware 15\.0' /etc/slackware-version
    test "$(uname -m)" = 'x86_64'
    command -v gcc >/dev/null
    command -v make >/dev/null
    command -v installpkg >/dev/null
    command -v slapt-src >/dev/null
    command -v sbopkg >/dev/null
    command -v sqg >/dev/null
    test -s "$METADATA"
    printf '%s\n' 'SELF-TESTE OK'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pacote)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PACKAGE=$2
            shift 2
            ;;
        --jobs)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            JOBS=$2
            shift 2
            ;;
        --self-test)
            self_test
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

case "$PACKAGE" in
    ''|*[!A-Za-z0-9+_.-]*)
        log 'Nome de pacote vazio ou invalido.'
        exit 2
        ;;
esac
case "$JOBS" in
    ''|*[!0-9]*|0)
        log 'Quantidade de jobs invalida.'
        exit 2
        ;;
esac

test -d "$WORKROOT"
test -s "$METADATA"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_name="${PACKAGE}-${timestamp}"
PARTIAL="${WORKROOT}/.parciais/${run_name}"
FINAL="${WORKROOT}/resultados/${run_name}"
FAILURE="${WORKROOT}/falhas/${run_name}"
PACKAGE_TEMP="/tmp/pacotes-${run_name}"
VISITED=$(mktemp /tmp/visited.XXXXXX)
STACK=$(mktemp /tmp/stack.XXXXXX)
QUEUE=$(mktemp /tmp/queue.XXXXXX)

mkdir -p "$PARTIAL/logs" "$PARTIAL/pacotes" "$PARTIAL/fontes" \
    "$PACKAGE_TEMP" "${WORKROOT}/resultados" "${WORKROOT}/falhas" \
    "${WORKROOT}/.parciais"

exec > >(tee -a "${PARTIAL}/logs/compilacao.log") 2>&1
trap finish EXIT INT TERM

log "Imagem: $(cat /etc/slackbuild-builder-release)"
log "Pacote solicitado: $PACKAGE"
log "Paralelismo interno: $JOBS"

resolve_package "$PACKAGE"
cp "$QUEUE" "${PARTIAL}/${PACKAGE}.sqf"
: > "${PARTIAL}/ORDEM_INSTALACAO.txt"

total=$(wc -l < "$QUEUE" | tr -d ' ')
current=0
while IFS= read -r item; do
    [ -n "$item" ] || continue
    current=$((current + 1))
    final_item=0
    if [ "$current" -eq "$total" ]; then
        final_item=1
    fi
    build_one "$item" "$final_item"
done < "$QUEUE"

write_installer
(
    cd "$PARTIAL"
    find pacotes -type f \( -name '*.txz' -o -name '*.tgz' \) -print |
        LC_ALL=C sort |
        xargs sha256sum > CKSUMS.sha256
)

cat > "${PARTIAL}/INFORMACOES.txt" <<EOF
Pacote principal: ${PACKAGE}
Arquitetura: x86_64
Sistema alvo: Slackware 15.0
Colecao: ${SALIX_SBO:-https://download.salixos.org/sbo/15.0/}
Gerado em UTC: ${timestamp}
EOF

rm -f "$VISITED" "$STACK" "$QUEUE"
COMPLETED=1
log 'Todas as compilacoes terminaram com sucesso.'
