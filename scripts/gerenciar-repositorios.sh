#!/bin/bash

# Sincroniza os repositorios binarios, compara a colecao SBo completa,
# compila somente o que falta e publica o resultado pelo Apache.

set -Eeuo pipefail

WORKROOT='/work'
REPOROOT='/work/repositorios'
SLACKWARE_REPO="$REPOROOT/slackware/slackware64-15.0"
SALIX_REPO="$REPOROOT/salix/15.0"
SALIX_EXTRA_REPO="$REPOROOT/salix/extra-15.0"
CUSTOM_REPO="$REPOROOT/compilados/15.0"
CUSTOM_PACKAGES="$CUSTOM_REPO/packages"
CUSTOM_METADATA="$CUSTOM_REPO/metadata"
BROWSER_REPO="$REPOROOT/navegadores/15.0"
BROWSER_PACKAGES="$BROWSER_REPO/packages"
BROWSER_METADATA="$BROWSER_REPO/metadata"
STATE_DIR='/work/.estado'
RUNS_DIR='/work/execucoes'
PKGTOOLS_LOCK="$STATE_DIR/pkgtools.lock"
JOBS=${JOBS:-1}
SALIX_RSYNC_BASE=${SALIX_RSYNC_BASE:-'rsync://rsync.slackware.uk/salix'}
SLACKWARE_RSYNC_ROOT=${SLACKWARE_RSYNC_ROOT:-'rsync://slackware.uk/slackware/slackware64-15.0'}
ROUTINE_SLACKBUILDS=${ROTINAS_ATIVAS_ROOT:-/run/slackrepo-rotinas}/slackbuilds
SBO_ROOT=''
PACKAGE=''

declare -A BINARY_PACKAGES=()
declare -A BINARY_FILE=()
declare -A BINARY_REQUIRES=()
declare -A CUSTOM_BUILT=()
declare -A INSTALLED_PACKAGES=()
declare -A RECIPE_PATH=()
declare -A RECIPE_KIND=()
declare -A RESOLVE_STATE=()
declare -A RESOLVE_OK=()
declare -A RESOLVE_REASON=()
declare -A BUILD_STATUS=()
declare -A CLOSURE_SEEN=()

usage()
{
    cat <<'EOF'
Uso interno:
  gerenciar-repositorios --sincronizar
  gerenciar-repositorios --sincronizar-sbo
  gerenciar-repositorios --compilar-faltantes
  gerenciar-repositorios --atualizar-navegadores
  gerenciar-repositorios --executar-tudo
  gerenciar-repositorios --pacote NOME
  gerenciar-repositorios --fontes-slapt-get
  gerenciar-repositorios --servidor-pronto
  gerenciar-repositorios --self-test
EOF
}

log()
{
    printf '%s\n' "[repositorio] $*"
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

timestamp()
{
    date -u +%Y%m%dT%H%M%SZ
}

validate_jobs()
{
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "quantidade de jobs invalida: $JOBS"
}

rsync_common()
{
    rsync --archive --hard-links --partial --delete-delay \
        --human-readable --itemize-changes --info=progress2 \
        --timeout=120 "$@"
}

acquire_operation_lock()
{
    exec 9>"$STATE_DIR/operacao.lock"
    flock -n 9 || die 'ja existe outra sincronizacao ou compilacao em andamento'
}

report_disk_space()
{
    local available_kib available_gib
    available_kib=$(df -Pk "$WORKROOT" | awk 'NR == 2 {print $4}')
    available_gib=$((available_kib / 1024 / 1024))
    log "Espaco livre no armazenamento persistente: ${available_gib} GiB."
    if [ "$available_gib" -lt 20 ]; then
        log 'AVISO: o espelho binario completo provavelmente nao cabera neste espaco.'
    fi
}

sync_root_metadata()
{
    local source=$1
    local destination=$2
    mkdir -p "$destination"
    rsync_common \
        --include='/PACKAGES.TXT' \
        --include='/PACKAGES.TXT.gz' \
        --include='/PACKAGES.json' \
        --include='/CHECKSUMS.md5' \
        --include='/CHECKSUMS.md5.gz' \
        --include='/CHECKSUMS.md5.asc' \
        --include='/CHECKSUMS.md5.gz.asc' \
        --include='/FILELIST.TXT' \
        --include='/ChangeLog.txt' \
        --include='/GPG-KEY' \
        --exclude='*' \
        "$source/" "$destination/"
}

sync_slackware()
{
    local source="$SLACKWARE_RSYNC_ROOT"
    log 'Sincronizando pacotes oficiais do Slackware 15.0.'
    sync_root_metadata "$source" "$SLACKWARE_REPO"
    mkdir -p "$SLACKWARE_REPO/slackware64" "$SLACKWARE_REPO/patches/packages" \
        "$SLACKWARE_REPO/extra" "$SLACKWARE_REPO/deps"
    rsync_common "$source/slackware64/" "$SLACKWARE_REPO/slackware64/"
    rsync_common "$source/patches/packages/" "$SLACKWARE_REPO/patches/packages/"
    rsync_common --exclude='source/' --exclude='*/source/' \
        "$source/extra/" "$SLACKWARE_REPO/extra/"
    rsync_common "$source/deps/" "$SLACKWARE_REPO/deps/"
}

sync_salix_repository()
{
    local remote_name=$1
    local destination=$2
    local source="$SALIX_RSYNC_BASE/x86_64/$remote_name"
    log "Sincronizando repositorio Salix $remote_name."
    sync_root_metadata "$source" "$destination"
    mkdir -p "$destination/salix"
    rsync_common "$source/salix/" "$destination/salix/"
}

verify_signed_index()
{
    local repository=$1
    local checksum=$2
    local signature=$3
    local label=$4
    local gnupg_home

    [ -s "$repository/GPG-KEY" ] || die "GPG-KEY ausente em $label"
    [ -s "$repository/$checksum" ] || die "$checksum ausente em $label"
    [ -s "$repository/$signature" ] || die "$signature ausente em $label"

    gnupg_home=$(mktemp -d /tmp/repo-gpg.XXXXXX)
    chmod 0700 "$gnupg_home"
    gpg --homedir "$gnupg_home" --batch --import "$repository/GPG-KEY" \
        >/dev/null 2>&1
    gpg --homedir "$gnupg_home" --batch \
        --verify "$repository/$signature" "$repository/$checksum"
    rm -rf "$gnupg_home"
    log "Assinatura verificada: $label."
}

verify_repository_files()
{
    local repository=$1
    local checksum_file=$2
    local label=$3
    local list_file=$checksum_file

    if [[ "$checksum_file" == *.gz ]]; then
        list_file=$(mktemp /tmp/checksums.XXXXXX)
        gzip -dc "$repository/$checksum_file" > "$list_file"
    fi

    log "Validando checksums dos arquivos presentes: $label."
    (
        cd "$repository"
        md5sum --check --ignore-missing "$list_file"
    )
    [[ "$list_file" == "$checksum_file" ]] || rm -f "$list_file"
}

verify_mirrors()
{
    verify_signed_index "$SLACKWARE_REPO" CHECKSUMS.md5 CHECKSUMS.md5.asc \
        'Slackware 15.0'
    verify_repository_files "$SLACKWARE_REPO" CHECKSUMS.md5 'Slackware 15.0'

    verify_signed_index "$SALIX_REPO" CHECKSUMS.md5.gz CHECKSUMS.md5.gz.asc \
        'Salix 15.0'
    verify_repository_files "$SALIX_REPO" CHECKSUMS.md5.gz 'Salix 15.0'

    verify_signed_index "$SALIX_EXTRA_REPO" CHECKSUMS.md5.gz CHECKSUMS.md5.gz.asc \
        'Salix extra-15.0'
    verify_repository_files "$SALIX_EXTRA_REPO" CHECKSUMS.md5.gz 'Salix extra-15.0'
}

configure_local_slapt_get()
{
    mkdir -p /etc/slapt-get "$CUSTOM_PACKAGES" "$CUSTOM_METADATA"
    mkdir -p "$BROWSER_PACKAGES" "$BROWSER_METADATA"
    [ -e "$BROWSER_REPO/PACKAGES.TXT" ] ||
        /usr/local/sbin/gerar-indice-repositorio "$BROWSER_REPO"
    cat > /etc/slapt-get/slapt-getrc <<'EOF'
WORKINGDIR=/var/slapt-get
EXCLUDE=^aaa_base$,^aaa_glibc-solibs$,^aaa_libraries$,^devs$,^etc$,^glibc$,^kernel-.*$,^pkgtools$,^sysvinit$,^sysvinit-functions$,^sysvinit-scripts$
SOURCE=http://127.0.0.1/slackware/slackware64-15.0/:OFFICIAL
SOURCE=http://127.0.0.1/salix/15.0/:PREFERRED
SOURCE=http://127.0.0.1/salix/extra-15.0/:CUSTOM
SOURCE=http://127.0.0.1/compilados/15.0/:CUSTOM
SOURCE=http://127.0.0.1/navegadores/15.0/:CUSTOM
EOF
    slapt-get --update
}

sync_sbo()
{
    log 'Sincronizando a colecao completa SBo 15.0 pelo sbopkg.'
    sbopkg -r
    locate_sbo_root
    log "Colecao SBo completa: $SBO_ROOT"
}

locate_sbo_root()
{
    local candidate
    for candidate in \
        /var/lib/sbopkg/SBo/15.0 \
        /var/lib/sbopkg/SBo-git/15.0; do
        if [ -d "$candidate" ]; then
            SBO_ROOT=$candidate
            return 0
        fi
    done
    SBO_ROOT=$(find /var/lib/sbopkg -type d -path '*/SBo/15.0' -print -quit)
    [ -n "$SBO_ROOT" ] || die 'a arvore completa SBo 15.0 nao foi localizada'
}

sync_all()
{
    report_disk_space
    mkdir -p "$SLACKWARE_REPO" "$SALIX_REPO" "$SALIX_EXTRA_REPO" \
        "$CUSTOM_PACKAGES" "$CUSTOM_METADATA" "$RUNS_DIR"
    mkdir -p "$BROWSER_PACKAGES" "$BROWSER_METADATA"
    sync_slackware
    sync_salix_repository 15.0 "$SALIX_REPO"
    sync_salix_repository extra-15.0 "$SALIX_EXTRA_REPO"
    verify_mirrors
    /usr/local/sbin/gerar-indice-repositorio "$CUSTOM_REPO"
    configure_local_slapt_get
    sync_sbo
    date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/ultima-sincronizacao"
    log 'Sincronizacao concluida.'
}

base_name_from_package_file()
{
    local filename=$1
    local stem rest
    stem=${filename##*/}
    stem=${stem%.txz}
    stem=${stem%.tgz}
    stem=${stem%.tlz}
    rest=${stem%-*}
    rest=${rest%-*}
    rest=${rest%-*}
    printf '%s\n' "$rest"
}

load_package_names_from_index()
{
    local index_file=$1
    local repository_root=$2
    local filename location requirements name relative
    [ -s "$index_file" ] || die "indice ausente ou vazio: $index_file"
    while IFS=$'\t' read -r filename location requirements; do
        [ -n "$filename" ] || continue
        name=$(base_name_from_package_file "$filename")
        BINARY_PACKAGES["$name"]=1
        relative=${location#./}
        if [ -f "$repository_root/$relative/$filename" ]; then
            BINARY_FILE["$name"]="$repository_root/$relative/$filename"
        fi
        BINARY_REQUIRES["$name"]=$requirements
    done < <(awk '
        $1 == "PACKAGE" && $2 == "NAME:" {filename=$3; location=""; required=""; next}
        $1 == "PACKAGE" && $2 == "LOCATION:" {location=$3; next}
        $1 == "PACKAGE" && $2 == "REQUIRED:" {
            required=$0
            sub(/^[^:]*:[[:space:]]*/, "", required)
            print filename "\t" location "\t" required
        }
    ' "$index_file")
}

load_binary_inventory()
{
    BINARY_PACKAGES=()
    BINARY_FILE=()
    BINARY_REQUIRES=()
    load_package_names_from_index "$SLACKWARE_REPO/PACKAGES.TXT" "$SLACKWARE_REPO"
    load_package_names_from_index "$SALIX_REPO/PACKAGES.TXT" "$SALIX_REPO"
    load_package_names_from_index "$SALIX_EXTRA_REPO/PACKAGES.TXT" "$SALIX_EXTRA_REPO"
    if [ -s "$BROWSER_REPO/PACKAGES.TXT" ]; then
        load_package_names_from_index "$BROWSER_REPO/PACKAGES.TXT" "$BROWSER_REPO"
    fi
    log "Inventario binario carregado: ${#BINARY_PACKAGES[@]} nomes unicos."
}

load_custom_inventory()
{
    local package_file name
    CUSTOM_BUILT=()
    shopt -s nullglob
    for package_file in "$CUSTOM_PACKAGES"/*.t?z; do
        name=$(base_name_from_package_file "$package_file")
        CUSTOM_BUILT["$name"]=$package_file
        BUILD_STATUS["$name"]='success'
    done
    shopt -u nullglob
}

load_installed_inventory()
{
    local package_file name
    INSTALLED_PACKAGES=()
    shopt -s nullglob
    for package_file in /var/log/packages/*; do
        name=$(base_name_from_package_file "$package_file")
        INSTALLED_PACKAGES["$name"]=1
    done
    shopt -u nullglob
}

load_recipe_inventory()
{
    local info_file name slackbuild_file
    RECIPE_PATH=()
    RECIPE_KIND=()
    while IFS= read -r -d '' info_file; do
        name=$(basename "$info_file" .info)
        RECIPE_PATH["$name"]=${info_file%/*}
        RECIPE_KIND["$name"]='sbo'
    done < <(find "$SBO_ROOT" -type f -name '*.info' -print0)

    if [ -d "$ROUTINE_SLACKBUILDS" ]; then
        while IFS= read -r -d '' info_file; do
            name=$(basename "$info_file" .info)
            slackbuild_file="${info_file%/*}/$name.SlackBuild"
            [ -x "$slackbuild_file" ] ||
                die "rotina $name possui .info, mas nao possui $name.SlackBuild executavel"
            RECIPE_PATH["$name"]=${info_file%/*}
            RECIPE_KIND["$name"]='routine'
        done < <(find "$ROUTINE_SLACKBUILDS" -mindepth 2 -maxdepth 2 \
            -type f -name '*.info' -print0)
    fi
    log "Receitas carregadas, incluindo rotinas validadas: ${#RECIPE_PATH[@]}."
}

read_info_value()
{
    local info_file=$1
    local field=$2
    bash -c '
        set +u
        source "$1"
        case "$2" in
            REQUIRES) printf "%s\n" "${REQUIRES:-}" ;;
            DOWNLOAD) printf "%s\n" "${DOWNLOAD:-}" ;;
            DOWNLOAD_x86_64) printf "%s\n" "${DOWNLOAD_x86_64:-}" ;;
            *) exit 2 ;;
        esac
    ' bash "$info_file" "$field"
}

package_requirements()
{
    local package_name=$1
    local recipe=${RECIPE_PATH[$package_name]:-}
    [ -n "$recipe" ] || return 1
    read_info_value "$recipe/$package_name.info" REQUIRES
}

prepare_catalogs()
{
    [ -s "$SLACKWARE_REPO/PACKAGES.TXT" ] ||
        die 'execute --sincronizar antes de compilar'
    locate_sbo_root
    load_binary_inventory
    load_custom_inventory
    load_installed_inventory
    load_recipe_inventory
}

normalize_dependency()
{
    local dependency=$1
    local candidate first=''
    dependency=${dependency%%:*}
    if [[ "$dependency" == *'|'* ]]; then
        IFS='|' read -r -a alternatives <<< "$dependency"
        for candidate in "${alternatives[@]}"; do
            [ -n "$first" ] || first=$candidate
            if [[ -n ${INSTALLED_PACKAGES[$candidate]:-} ||
                  -n ${BINARY_PACKAGES[$candidate]:-} ||
                  -n ${CUSTOM_BUILT[$candidate]:-} ]]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
        printf '%s\n' "$first"
    else
        printf '%s\n' "$dependency"
    fi
}

resolve_package()
{
    local package_name=$1
    local dependency requirements

    if [[ -n ${BINARY_PACKAGES[$package_name]:-} ]]; then
        RESOLVE_OK["$package_name"]=1
        return 0
    fi
    if [[ ${RESOLVE_STATE[$package_name]:-} == done ]]; then
        [[ ${RESOLVE_OK[$package_name]:-0} == 1 ]]
        return
    fi
    if [[ ${RESOLVE_STATE[$package_name]:-} == visiting ]]; then
        RESOLVE_STATE["$package_name"]='done'
        RESOLVE_OK["$package_name"]=0
        RESOLVE_REASON["$package_name"]="ciclo de dependencias envolvendo $package_name"
        return 1
    fi
    if [[ -z ${RECIPE_PATH[$package_name]:-} ]]; then
        RESOLVE_STATE["$package_name"]='done'
        RESOLVE_OK["$package_name"]=0
        RESOLVE_REASON["$package_name"]='dependencia sem pacote binario e sem receita SBo'
        return 1
    fi

    RESOLVE_STATE["$package_name"]='visiting'
    requirements=$(package_requirements "$package_name")
    for dependency in $requirements; do
        dependency=$(normalize_dependency "$dependency")
        case "$dependency" in
            '') continue ;;
            %README%)
                RESOLVE_STATE["$package_name"]='done'
                RESOLVE_OK["$package_name"]=0
                RESOLVE_REASON["$package_name"]='a receita exige decisao manual indicada por %README%'
                return 1
                ;;
        esac
        if ! resolve_package "$dependency"; then
            RESOLVE_STATE["$package_name"]='done'
            RESOLVE_OK["$package_name"]=0
            RESOLVE_REASON["$package_name"]="dependencia bloqueada: $dependency (${RESOLVE_REASON[$dependency]:-erro})"
            return 1
        fi
    done

    RESOLVE_STATE["$package_name"]='done'
    RESOLVE_OK["$package_name"]=1
    if [[ -z ${BINARY_PACKAGES[$package_name]:-} && -z ${CUSTOM_BUILT[$package_name]:-} ]]; then
        printf '%s\n' "$package_name" >> "$CURRENT_ORDER"
    fi
}

is_installed()
{
    [[ -n ${INSTALLED_PACKAGES[$1]:-} ]]
}

ensure_dependency_installed()
{
    local dependency=$1
    if is_installed "$dependency"; then
        return 0
    fi

    if [[ -n ${CUSTOM_BUILT[$dependency]:-} ]]; then
        log "Instalando dependencia compilada no ambiente do conteiner: $dependency."
        (
            flock 8
            installpkg "${CUSTOM_BUILT[$dependency]}"
        ) 8>"$PKGTOOLS_LOCK"
        INSTALLED_PACKAGES["$dependency"]=1
        return 0
    fi

    if [[ -n ${BINARY_PACKAGES[$dependency]:-} ]]; then
        log "Instalando dependencia binaria do espelho local: $dependency."
        (
            flock 8
            slapt-get --yes --install "$dependency"
        ) 8>"$PKGTOOLS_LOCK"
        load_installed_inventory
        is_installed "$dependency"
        return
    fi

    return 1
}

ensure_direct_dependencies()
{
    local package_name=$1
    local dependency requirements
    requirements=$(package_requirements "$package_name")
    for dependency in $requirements; do
        dependency=$(normalize_dependency "$dependency")
        case "$dependency" in ''|%README%) continue ;; esac
        if ! ensure_dependency_installed "$dependency"; then
            log "Dependencia ainda indisponivel para $package_name: $dependency"
            return 1
        fi
    done
}

copy_recipe_and_sources()
{
    local package_name=$1
    local destination=$2
    local recipe=${RECIPE_PATH[$package_name]}
    local field urls url filename cached

    mkdir -p "$destination"
    cp -a "$recipe/." "$destination/"

    for field in DOWNLOAD_x86_64 DOWNLOAD; do
        urls=$(read_info_value "$recipe/$package_name.info" "$field")
        [ -n "$urls" ] || continue
        for url in $urls; do
            case "$url" in ''|UNSUPPORTED|UNTESTED) continue ;; esac
            filename=${url%%\?*}
            filename=${filename##*/}
            [ -n "$filename" ] || continue
            cached=$(find /var/cache/sbopkg /tmp/SBo -type f -name "$filename" -print -quit 2>/dev/null || :)
            if [ -n "$cached" ] && [ ! -e "$destination/$filename" ]; then
                cp -p "$cached" "$destination/$filename"
            fi
        done
        [ "$field" = DOWNLOAD_x86_64 ] && [ -n "$urls" ] && break
    done
}

find_new_package()
{
    local package_name=$1
    local marker=$2
    find "$CUSTOM_PACKAGES" /tmp /var/cache/sbopkg \
        -type f -newer "$marker" \
        \( -name "${package_name}-*.txz" -o -name "${package_name}-*.tgz" \) \
        -print 2>/dev/null | head -n 1
}

write_result_installer()
{
    local destination=$1
    cat > "$destination/instalar.sh" <<'EOF'
#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'ERRO: execute como root.' >&2; exit 1; }
grep -q '^Slackware 15\.0' /etc/slackware-version || {
    printf '%s\n' 'ERRO: pacotes destinados ao Slackware 15.0.' >&2; exit 1;
}
cd "$SCRIPT_DIR"
sha256sum -c CKSUMS.sha256
while IFS= read -r package_file; do
    [ -n "$package_file" ] || continue
    /sbin/upgradepkg --install-new "pacotes/$package_file"
done < ORDEM_INSTALACAO.txt
EOF
    chmod 0755 "$destination/instalar.sh"
}

collect_custom_closure()
{
    local package_name=$1
    local dependency requirements
    [[ -n ${CLOSURE_SEEN[$package_name]:-} ]] && return 0
    CLOSURE_SEEN["$package_name"]=1
    if [[ -n ${CUSTOM_BUILT[$package_name]:-} ]]; then
        requirements=$(package_requirements "$package_name")
    else
        requirements=${BINARY_REQUIRES[$package_name]:-}
        requirements=${requirements//,/ }
    fi
    for dependency in $requirements; do
        dependency=$(normalize_dependency "$dependency")
        case "$dependency" in ''|%README%) continue ;; esac
        if [[ -n ${CUSTOM_BUILT[$dependency]:-} || -n ${BINARY_FILE[$dependency]:-} ]]; then
            collect_custom_closure "$dependency"
        fi
    done
    if [[ -n ${CUSTOM_BUILT[$package_name]:-} || -n ${BINARY_FILE[$package_name]:-} ]]; then
        printf '%s\n' "$package_name" >> "$CLOSURE_FILE"
    fi
}

finalize_success_result()
{
    local package_name=$1
    local partial=$2
    local final=$3
    local package_file=$4
    local dependency dependency_file

    CUSTOM_BUILT["$package_name"]=$package_file
    BUILD_STATUS["$package_name"]='success'
    CLOSURE_SEEN=()
    CLOSURE_FILE=$(mktemp /tmp/closure.XXXXXX)
    collect_custom_closure "$package_name"
    awk '!seen[$0]++' "$CLOSURE_FILE" > "$partial/$package_name.sqf"
    : > "$partial/ORDEM_INSTALACAO.txt"

    while IFS= read -r dependency; do
        [ -n "$dependency" ] || continue
        if [[ -n ${CUSTOM_BUILT[$dependency]:-} ]]; then
            dependency_file=${CUSTOM_BUILT[$dependency]}
        else
            dependency_file=${BINARY_FILE[$dependency]}
        fi
        ln "$dependency_file" "$partial/pacotes/$(basename "$dependency_file")" 2>/dev/null ||
            cp -p "$dependency_file" "$partial/pacotes/"
        printf '%s\n' "$(basename "$dependency_file")" >> "$partial/ORDEM_INSTALACAO.txt"
        if [[ -n ${CUSTOM_BUILT[$dependency]:-} && -n ${RECIPE_PATH[$dependency]:-} ]]; then
            copy_recipe_and_sources "$dependency" "$partial/fontes/$dependency"
        fi
    done < "$partial/$package_name.sqf"
    rm -f "$CLOSURE_FILE"

    write_result_installer "$partial"
    (
        cd "$partial"
        find pacotes -maxdepth 1 -type f -print | LC_ALL=C sort |
            xargs sha256sum > CKSUMS.sha256
    )
    cat > "$partial/INFORMACOES.txt" <<EOF
Pacote principal: $package_name
Arquitetura: x86_64
Sistema alvo: Slackware 15.0
Origem da receita: SBo 15.0 completo sincronizado pelo sbopkg
Gerado em UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Repositorio local: compilados/15.0/
EOF
    printf '%s\n' 'SUCESSO' > "$partial/STATUS"
    mkdir -p "$(dirname "$final")"
    mv "$partial" "$final"
    log "Resultado concluido: $final"
}

record_ignored()
{
    local package_name=$1
    local reason=$2
    local run_name="${package_name}-$(timestamp)"
    local destination="$WORKROOT/ignorados/$run_name"
    mkdir -p "$destination/logs" "$destination/pacotes" "$destination/fontes"
    printf '%s\n' 'IGNORADO' > "$destination/STATUS"
    printf '%s\n' "$reason" > "$destination/INFORMACOES.txt"
    printf '%s\n' "$reason" > "$destination/logs/compilacao.log"
    : > "$destination/ORDEM_INSTALACAO.txt"
    : > "$destination/CKSUMS.sha256"
    log "Ignorado: $package_name - $reason"
}

build_one()
{
    local package_name=$1
    local run_name="${package_name}-$(timestamp)"
    local partial="$WORKROOT/.parciais/$run_name"
    local final="$WORKROOT/resultados/$run_name"
    local failure="$WORKROOT/falhas/$run_name"
    local marker package_file rc requirements routine_build_dir

    if [[ -n ${CUSTOM_BUILT[$package_name]:-} ]]; then
        BUILD_STATUS["$package_name"]='success'
        ensure_dependency_installed "$package_name"
        log "Ja compilado anteriormente: $package_name."
        return 0
    fi

    if ! ensure_direct_dependencies "$package_name"; then
        BUILD_STATUS["$package_name"]='blocked'
        record_ignored "$package_name" 'uma ou mais dependencias nao puderam ser instaladas'
        return 1
    fi

    mkdir -p "$partial/logs" "$partial/pacotes" "$partial/fontes" \
        "$WORKROOT/.parciais" "$WORKROOT/resultados" "$WORKROOT/falhas"
    marker=$(mktemp /tmp/build-marker.XXXXXX)
    log "Compilando $package_name ($JOBS job(s))."

    routine_build_dir=''
    set +e
    if [[ ${RECIPE_KIND[$package_name]:-sbo} == routine ]]; then
        routine_build_dir=$(mktemp -d "/tmp/rotina-${package_name}.XXXXXX")
        cp -a "${RECIPE_PATH[$package_name]}/." "$routine_build_dir/"
        (
            flock 8
            cd "$routine_build_dir"
            OUTPUT="$CUSTOM_PACKAGES" \
            TMP="/tmp/SBo-${package_name}" \
            MAKEFLAGS="-j${JOBS}" \
            NUMJOBS="-j${JOBS}" \
            ARCH=x86_64 \
                "./${package_name}.SlackBuild"
        ) 8>"$PKGTOOLS_LOCK" \
            2>&1 | tee -a "$partial/logs/compilacao.log"
    else
        (
            flock 8
            OUTPUT="$CUSTOM_PACKAGES" \
            TMP="/tmp/SBo-${package_name}" \
            MAKEFLAGS="-j${JOBS}" \
            NUMJOBS="-j${JOBS}" \
                sbopkg -B -e stop -k -i "$package_name"
        ) 8>"$PKGTOOLS_LOCK" \
            2>&1 | tee -a "$partial/logs/compilacao.log"
    fi
    rc=${PIPESTATUS[0]}
    set -e
    [ -z "$routine_build_dir" ] || rm -rf "$routine_build_dir"

    if [ "$rc" -eq 0 ]; then
        package_file=$(find_new_package "$package_name" "$marker")
    else
        package_file=''
    fi
    rm -f "$marker"

    if [ "$rc" -ne 0 ] || [ -z "$package_file" ] || [ ! -f "$package_file" ]; then
        printf '%s\n' 'FALHA' > "$partial/STATUS"
        printf 'Pacote: %s\nCodigo de retorno: %s\n' "$package_name" "$rc" \
            > "$partial/INFORMACOES.txt"
        mv "$partial" "$failure"
        BUILD_STATUS["$package_name"]='failed'
        log "Falha preservada: $failure"
        return 1
    fi

    if [[ "$package_file" != "$CUSTOM_PACKAGES/"* ]]; then
        cp -p "$package_file" "$CUSTOM_PACKAGES/"
        package_file="$CUSTOM_PACKAGES/$(basename "$package_file")"
    fi

    requirements=$(package_requirements "$package_name")
    printf '%s\n' "$requirements" > "$CUSTOM_METADATA/$package_name.requires"
    INSTALLED_PACKAGES["$package_name"]=1
    finalize_success_result "$package_name" "$partial" "$final" "$package_file"
}

dependencies_ready_for_build()
{
    local package_name=$1
    local dependency requirements
    requirements=$(package_requirements "$package_name")
    for dependency in $requirements; do
        dependency=$(normalize_dependency "$dependency")
        case "$dependency" in ''|%README%) continue ;; esac
        if [[ -n ${BINARY_PACKAGES[$dependency]:-} || -n ${CUSTOM_BUILT[$dependency]:-} ]]; then
            continue
        fi
        [[ ${BUILD_STATUS[$dependency]:-} == success ]] || return 1
    done
}

compile_order()
{
    local order_file=$1
    local requested_label=$2
    local execution="$RUNS_DIR/${requested_label}-$(timestamp)"
    local package_name total current successes failures ignored

    mkdir -p "$execution"
    cp "$order_file" "$execution/ORDEM_GLOBAL.txt"
    : > "$execution/SUCESSOS.txt"
    : > "$execution/FALHAS.txt"
    : > "$execution/IGNORADOS.txt"

    total=$(awk 'NF {count++} END {print count+0}' "$order_file")
    current=0
    successes=0
    failures=0
    ignored=0

    while IFS= read -r package_name; do
        [ -n "$package_name" ] || continue
        current=$((current + 1))
        log "Fila global: $current/$total - $package_name"

        if ! dependencies_ready_for_build "$package_name"; then
            BUILD_STATUS["$package_name"]='blocked'
            printf '%s\n' "$package_name" >> "$execution/IGNORADOS.txt"
            record_ignored "$package_name" 'dependencia SBo falhou ou foi ignorada anteriormente'
            ignored=$((ignored + 1))
            continue
        fi

        if build_one "$package_name"; then
            printf '%s\n' "$package_name" >> "$execution/SUCESSOS.txt"
            successes=$((successes + 1))
        else
            printf '%s\n' "$package_name" >> "$execution/FALHAS.txt"
            failures=$((failures + 1))
        fi
    done < "$order_file"

    /usr/local/sbin/gerar-indice-repositorio "$CUSTOM_REPO"
    configure_local_slapt_get
    cat > "$execution/RELATORIO.txt" <<EOF
Execucao: $requested_label
Total na fila: $total
Sucessos: $successes
Falhas: $failures
Ignorados durante a compilacao: $ignored
Concluido em UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    printf '%s\n' 'CONCLUIDO' > "$execution/STATUS"
    log "Relatorio final: $execution/RELATORIO.txt"
    log "Sucessos: $successes; falhas: $failures; ignorados: $ignored."
}

compile_missing()
{
    local target=${1:-}
    local package_name order_file ignored_file missing_count=0 ignored_count=0
    report_disk_space
    prepare_catalogs
    configure_local_slapt_get

    RESOLVE_STATE=()
    RESOLVE_OK=()
    RESOLVE_REASON=()
    order_file=$(mktemp /tmp/order.XXXXXX)
    ignored_file=$(mktemp /tmp/ignored.XXXXXX)
    CURRENT_ORDER=$order_file

    if [ -n "$target" ]; then
        if [[ -n ${BINARY_PACKAGES[$target]:-} ]]; then
            log "$target ja existe em um repositorio binario Slackware/Salix/navegadores; nenhuma compilacao necessaria."
            rm -f "$order_file" "$ignored_file"
            return 0
        fi
        if [[ -n ${CUSTOM_BUILT[$target]:-} ]]; then
            log "$target ja foi compilado e esta no repositorio local."
            rm -f "$order_file" "$ignored_file"
            return 0
        fi
        if ! resolve_package "$target"; then
            record_ignored "$target" "${RESOLVE_REASON[$target]:-nao resolvido}"
            rm -f "$order_file" "$ignored_file"
            return 1
        fi
        awk '!seen[$0]++' "$order_file" > "$order_file.unique"
        compile_order "$order_file.unique" "$target"
        rm -f "$order_file" "$order_file.unique" "$ignored_file"
        return 0
    fi

    log 'Comparando toda a colecao SBo com Slackware, Salix, navegadores e compilados locais.'
    mapfile -t all_recipes < <(printf '%s\n' "${!RECIPE_PATH[@]}" | LC_ALL=C sort)
    for package_name in "${all_recipes[@]}"; do
        if [[ -n ${BINARY_PACKAGES[$package_name]:-} || -n ${CUSTOM_BUILT[$package_name]:-} ]]; then
            continue
        fi
        missing_count=$((missing_count + 1))
        if ! resolve_package "$package_name"; then
            printf '%s\t%s\n' "$package_name" "${RESOLVE_REASON[$package_name]:-nao resolvido}" \
                >> "$ignored_file"
            ignored_count=$((ignored_count + 1))
        fi
    done

    awk '!seen[$0]++' "$order_file" > "$order_file.unique"
    mkdir -p "$STATE_DIR"
    cp "$order_file.unique" "$STATE_DIR/ultima-fila-global.txt"
    cp "$ignored_file" "$STATE_DIR/ultimos-ignorados-resolucao.txt"
    log "Receitas sem pacote binario: $missing_count."
    log "Ignoradas na resolucao: $ignored_count."
    log "Fila compilavel: $(awk 'NF {count++} END {print count+0}' "$order_file.unique")."

    while IFS=$'\t' read -r package_name reason; do
        [ -n "$package_name" ] || continue
        record_ignored "$package_name" "$reason"
    done < "$ignored_file"

    compile_order "$order_file.unique" 'REPOSITORIO-COMPLETO'
    rm -f "$order_file" "$order_file.unique" "$ignored_file"
}

show_sources()
{
    cat <<'EOF'
# Substitua IP_DO_SERVIDOR pelo IP local ou pelo IP Tailscale do hospedeiro.
SOURCE=http://IP_DO_SERVIDOR:8080/slackware/slackware64-15.0/:OFFICIAL
SOURCE=http://IP_DO_SERVIDOR:8080/salix/15.0/:PREFERRED
SOURCE=http://IP_DO_SERVIDOR:8080/salix/extra-15.0/:CUSTOM
SOURCE=http://IP_DO_SERVIDOR:8080/compilados/15.0/:CUSTOM
SOURCE=http://IP_DO_SERVIDOR:8080/navegadores/15.0/:CUSTOM

# Depois execute no cliente:
# sudo slapt-get --update
EOF
}

server_ready()
{
    pgrep -x httpd >/dev/null
    wget -q -O /dev/null http://127.0.0.1/
}

self_test()
{
    validate_jobs
    for command_name in rsync gpg md5sum sbopkg slapt-get httpd awk sed tar flock; do
        command -v "$command_name" >/dev/null || die "comando ausente: $command_name"
    done
    test -x /usr/local/sbin/gerar-indice-repositorio
    test -x /usr/local/bin/atualizar-navegadores
    test -d /var/lib/sbopkg
    /usr/local/bin/atualizar-navegadores --self-test
    printf '%s\n' 'SELF-TESTE DO GERENCIADOR OK'
}

validate_jobs
mkdir -p "$REPOROOT" "$CUSTOM_PACKAGES" "$CUSTOM_METADATA" "$STATE_DIR" \
    "$BROWSER_PACKAGES" "$BROWSER_METADATA" \
    "$RUNS_DIR" "$WORKROOT/.parciais" "$WORKROOT/resultados" \
    "$WORKROOT/falhas" "$WORKROOT/ignorados"

case "${1:-}" in
    --sincronizar)
        acquire_operation_lock
        sync_all
        ;;
    --sincronizar-sbo)
        acquire_operation_lock
        sync_sbo
        date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/ultima-sincronizacao-sbo"
        ;;
    --compilar-faltantes)
        acquire_operation_lock
        compile_missing
        ;;
    --atualizar-navegadores)
        /usr/local/bin/atualizar-navegadores --todos
        ;;
    --executar-tudo)
        acquire_operation_lock
        if ! /usr/local/bin/atualizar-navegadores --todos; then
            log 'AVISO: a verificacao dos navegadores falhou; os pacotes existentes foram preservados.'
            log 'A sincronizacao Slackware/Salix e a compilacao SBo continuarao normalmente.'
        fi
        sync_all
        compile_missing
        ;;
    --pacote)
        [ "$#" -ge 2 ] || die 'informe o pacote'
        PACKAGE=$2
        [[ "$PACKAGE" =~ ^[A-Za-z0-9+_.-]+$ ]] || die 'nome de pacote invalido'
        acquire_operation_lock
        compile_missing "$PACKAGE"
        ;;
    --fontes-slapt-get) show_sources ;;
    --servidor-pronto) server_ready ;;
    --self-test) self_test ;;
    -h|--help|'') usage ;;
    *) usage >&2; exit 2 ;;
esac
