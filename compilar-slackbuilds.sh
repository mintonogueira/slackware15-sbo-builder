#!/bin/sh

# Controlador POSIX executado no hospedeiro Linux.

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
DATA_DIR=${SLACKBUILD_DATA_DIR:-"$SCRIPT_DIR/dados"}
STATE_DIR="$DATA_DIR/.estado"
IMAGE=${SLACKBUILD_IMAGE:-'ghcr.io/mintonogueira/slackware15-sbo-builder:15.0'}
CONTAINER=${SLACKBUILD_CONTAINER:-'slackware15-repositorio'}
HTTP_PORT=${SLACKBUILD_HTTP_PORT:-8080}
HTTPS_PORT=${SLACKBUILD_HTTPS_PORT:-8443}
STARTUP_TIMEOUT=${SLACKBUILD_STARTUP_TIMEOUT:-600}
SLACKWARE_RSYNC_ROOT=${SLACKWARE_RSYNC_ROOT:-'rsync://slackware.uk/slackware/slackware64-15.0'}
SALIX_RSYNC_BASE=${SALIX_RSYNC_BASE:-'rsync://rsync.slackware.uk/salix'}
LABEL='io.mintonogueira.slackware15-sbo-builder=service'
ACTION=''
PACKAGE=''
MONITOR_PID=''

usage()
{
    cat <<'EOF'
Uso:
  ./compilar-slackbuilds.sh --preparar-hospedeiro
  ./compilar-slackbuilds.sh --iniciar
  ./compilar-slackbuilds.sh --sincronizar
  ./compilar-slackbuilds.sh --sincronizar-slackbuilds
  ./compilar-slackbuilds.sh --compilar-faltantes
  ./compilar-slackbuilds.sh --atualizar-navegadores
  ./compilar-slackbuilds.sh --executar-tudo
  ./compilar-slackbuilds.sh --pacote NOME
  ./compilar-slackbuilds.sh --configurar-vpn
  ./compilar-slackbuilds.sh --fontes-slapt-get
  ./compilar-slackbuilds.sh --status
  ./compilar-slackbuilds.sh --logs-servidor
  ./compilar-slackbuilds.sh --parar
  ./compilar-slackbuilds.sh --remover-instancia
  ./compilar-slackbuilds.sh --atualizar-imagem

Variaveis opcionais:
  SLACKBUILD_DATA_DIR     Diretorio persistente dos repositorios e resultados
  SLACKBUILD_HTTP_PORT    Porta HTTP no hospedeiro (padrao: 8080)
  SLACKBUILD_HTTPS_PORT   Porta HTTPS no hospedeiro (padrao: 8443)
  SLACKBUILD_STARTUP_TIMEOUT  Espera maxima pela primeira inicializacao (padrao: 600 segundos)
  SLACKBUILD_IMAGE        Imagem publicada no GHCR
  SLACKWARE_RSYNC_ROOT    Espelho rsync Slackware 15.0 alternativo
  SALIX_RSYNC_BASE        Espelho rsync Salix alternativo
EOF
}

log()
{
    printf '%s\n' "[controle] $*"
}

die()
{
    printf '%s\n' "ERRO: $*" >&2
    exit 1
}

confirm_default_yes()
{
    printf '%s' "$1 [S/n] "
    IFS= read -r answer || answer=''
    case "$answer" in
        n|N|nao|NAO|Nao) return 1 ;;
        *) return 0 ;;
    esac
}

valid_port()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

require_ports()
{
    valid_port "$HTTP_PORT" || die "porta HTTP invalida: $HTTP_PORT"
    valid_port "$HTTPS_PORT" || die "porta HTTPS invalida: $HTTPS_PORT"
    [ "$HTTP_PORT" -ne "$HTTPS_PORT" ] || die 'as portas HTTP e HTTPS devem ser diferentes'
    case "$STARTUP_TIMEOUT" in
        ''|*[!0-9]*) die "tempo de inicializacao invalido: $STARTUP_TIMEOUT" ;;
    esac
    [ "$STARTUP_TIMEOUT" -ge 30 ] ||
        die 'o tempo de inicializacao deve ser de pelo menos 30 segundos'
}

require_rootless_execution()
{
    [ "$(id -u)" -ne 0 ] ||
        die 'nao execute este controlador com sudo; use o usuario comum. Se existir uma instancia antiga criada com sudo, a migracao sera oferecida automaticamente.'
}

port_in_use()
{
    checked_port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v wanted="$checked_port" '
            NR > 1 {
                address = $4
                sub(/^.*:/, "", address)
                if (address == wanted) found = 1
            }
            END { exit(found ? 0 : 1) }
        '
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk -v wanted="$checked_port" '
            NR > 2 {
                address = $4
                sub(/^.*:/, "", address)
                if (address == wanted) found = 1
            }
            END { exit(found ? 0 : 1) }
        '
        return
    fi
    return 1
}

conflicting_ports()
{
    conflicts=''
    for checked_port in "$HTTP_PORT" "$HTTPS_PORT"; do
        if port_in_use "$checked_port"; then
            conflicts="${conflicts}${conflicts:+ }${checked_port}"
        fi
    done
    printf '%s\n' "$conflicts"
}

migrate_legacy_rootful_container()
{
    command -v sudo >/dev/null 2>&1 || return 1
    if ! sudo podman container exists "$CONTAINER" 2>/dev/null; then
        return 1
    fi

    log "Foi encontrada uma instancia antiga de $CONTAINER criada com sudo."
    if ! confirm_default_yes 'Migrar automaticamente para Podman rootless e preservar dados/?'; then
        return 1
    fi

    sudo podman rm --force "$CONTAINER" >/dev/null ||
        die 'nao foi possivel remover a instancia rootful antiga'
    sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR" ||
        die "nao foi possivel transferir a propriedade de $DATA_DIR"
    log 'Instancia rootful removida; dados persistentes preservados e propriedade corrigida.'
}

ensure_publish_ports_available()
{
    conflicts=$(conflicting_ports)
    [ -n "$conflicts" ] || return 0

    log "Porta(s) ocupada(s) no hospedeiro: $conflicts."
    if migrate_legacy_rootful_container; then
        attempts=0
        while [ "$attempts" -lt 10 ]; do
            conflicts=$(conflicting_ports)
            [ -n "$conflicts" ] || return 0
            sleep 1
            attempts=$((attempts + 1))
        done
    fi

    die "a(s) porta(s) $conflicts continua(m) em uso por outro servico"
}

canonical_directory()
{
    directory=$1
    if [ -d "$directory" ]; then
        (CDPATH= cd "$directory" && pwd -P)
    else
        printf '%s\n' "$directory"
    fi
}

container_work_source()
{
    podman inspect --format \
        '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}' \
        "$CONTAINER" 2>/dev/null || :
}

reconcile_container_data_mount()
{
    container_exists || return 0
    expected_source=$(canonical_directory "$DATA_DIR")
    mounted_source=$(container_work_source)
    if [ -n "$mounted_source" ]; then
        mounted_source=$(canonical_directory "$mounted_source")
    fi
    [ "$mounted_source" = "$expected_source" ] && return 0

    log "O conteiner existente aponta para dados em: ${mounted_source:-montagem ausente}."
    log "O projeto atual usa dados em: $expected_source."
    if ! confirm_default_yes 'Recriar somente o conteiner com a montagem do projeto atual?'; then
        die 'o conteiner existente pertence a outro diretorio do projeto'
    fi
    podman rm --force "$CONTAINER" >/dev/null ||
        die 'nao foi possivel remover o conteiner com a montagem antiga'
    log 'Conteiner antigo removido; os dados de ambos os diretorios foram preservados.'
}

start_created_container()
{
    start_error="$STATE_DIR/podman-start.erro"
    if podman start "$CONTAINER" > /dev/null 2>"$start_error"; then
        rm -f "$start_error"
        return 0
    fi

    sed -n '1,120p' "$start_error" >&2
    if grep -Eqi \
        'address already in use|listen failed|couldn.t listen|requested ports' \
        "$start_error"; then
        log 'O Podman confirmou um conflito nas portas publicadas.'
        if migrate_legacy_rootful_container; then
            sleep 1
            if podman start "$CONTAINER" > /dev/null 2>"$start_error"; then
                rm -f "$start_error"
                return 0
            fi
            sed -n '1,120p' "$start_error" >&2
        fi
    fi
    die "nao foi possivel iniciar o conteiner $CONTAINER"
}

create_service_container()
{
    tls_ips=$(host_ipv4_list | awk 'NF && !seen[$0]++' | paste -sd, -)
    podman create \
        --name "$CONTAINER" \
        --label "$LABEL" \
        --restart unless-stopped \
        --pids-limit 8192 \
        --security-opt no-new-privileges \
        --publish "${HTTP_PORT}:80" \
        --publish "${HTTPS_PORT}:443" \
        --env "SLACKWARE_RSYNC_ROOT=$SLACKWARE_RSYNC_ROOT" \
        --env "SALIX_RSYNC_BASE=$SALIX_RSYNC_BASE" \
        --env "REPO_TLS_IPS=$tls_ips" \
        --volume "$DATA_DIR:/work:rw,Z" \
        "$IMAGE" >/dev/null
}

prepare_host()
{
    if [ "$(id -u)" -eq 0 ]; then
        original_user=${SUDO_USER:-$(logname 2>/dev/null || :)}
        if [ -z "$original_user" ] || [ "$original_user" = root ]; then
            printf '%s' 'Usuario comum que executara o Podman: '
            IFS= read -r original_user
        fi
        original_home=$(getent passwd "$original_user" 2>/dev/null | awk -F: '{print $6; exit}')
        [ -n "$original_home" ] || original_home=${HOME:-/root}
        "$SCRIPT_DIR/preparar-hospedeiro.sh" "$original_user" "$original_home"
        return
    fi

    command -v sudo >/dev/null 2>&1 ||
        die 'sudo nao esta instalado; execute preparar-hospedeiro.sh como root'
    sudo "$SCRIPT_DIR/preparar-hospedeiro.sh" "$(id -un)" "$HOME"
    hash -r
}

require_podman()
{
    if ! command -v podman >/dev/null 2>&1; then
        log 'Podman nao esta instalado no hospedeiro.'
        if confirm_default_yes 'Instalar Podman e todas as dependencias agora?'; then
            prepare_host
        fi
        command -v podman >/dev/null 2>&1 || die 'Podman continua indisponivel'
    fi

    if ! podman info >/dev/null 2>"$STATE_DIR/podman-info.erro"; then
        printf '%s\n' 'ERRO: o Podman esta instalado, mas nao consegue iniciar.' >&2
        sed -n '1,120p' "$STATE_DIR/podman-info.erro" >&2
        printf '%s\n' \
            'Execute: ./compilar-slackbuilds.sh --preparar-hospedeiro' >&2
        exit 1
    fi
    rm -f "$STATE_DIR/podman-info.erro"
}

container_exists()
{
    podman container exists "$CONTAINER" 2>/dev/null
}

container_running()
{
    [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || printf false)" = true ]
}

pull_image()
{
    require_podman
    log "Baixando a imagem pronta: $IMAGE"
    podman pull "$IMAGE" || die 'nao foi possivel baixar a imagem do GHCR; leia o erro real do Podman acima'
    image_id=$(podman image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || :)
    image_hash=${image_id#sha256:}
    case "$image_hash" in
        ''|*[!0-9A-Fa-f]*)
            die 'o Podman baixou a imagem, mas nao informou um identificador SHA-256 valido'
            ;;
    esac
    [ "${#image_hash}" -eq 64 ] ||
        die 'o Podman baixou a imagem, mas nao informou um identificador SHA-256 valido'

    image_hash=$(printf '%s' "$image_hash" | tr 'A-F' 'a-f')
    image_id="sha256:$image_hash"
    printf '%s\n' "$image_id" > "$STATE_DIR/imagem-sha256.txt"
    log "Integridade OCI verificada pelo Podman: $image_id"
}

prepare_routines_directory()
{
    routines="$DATA_DIR/rotinas"
    custom="$DATA_DIR/slackbuilds-personalizados"
    routines_manifest="$routines/SHA256SUMS"
    custom_manifest="$custom/SHA256SUMS"
    mkdir -p "$routines/scripts" "$routines/cache/remotas" "$custom/cache/remotas"
    if [ ! -e "$routines/LEIA-ME.txt" ]; then
        cp "$SCRIPT_DIR/config/rotinas/LEIA-ME.txt" "$routines/LEIA-ME.txt"
    fi
    if [ ! -e "$routines/links.conf.exemplo" ]; then
        cp "$SCRIPT_DIR/config/rotinas/links.conf.exemplo" \
            "$routines/links.conf.exemplo"
    fi

    if [ ! -e "$custom/LEIA-ME.txt" ]; then
        cp "$SCRIPT_DIR/config/slackbuilds-personalizados/LEIA-ME.txt" \
            "$custom/LEIA-ME.txt"
    fi
    if [ ! -e "$custom/links.conf.exemplo" ]; then
        cp "$SCRIPT_DIR/config/slackbuilds-personalizados/links.conf.exemplo" \
            "$custom/links.conf.exemplo"
    fi

    if [ ! -s "$routines_manifest" ]; then
        if find "$routines/scripts" -type f -print -quit 2>/dev/null | grep -q .; then
            die 'dados/rotinas possui arquivos, mas SHA256SUMS esta ausente; os arquivos foram preservados'
        fi
        command -v sha256sum >/dev/null 2>&1 ||
            die 'sha256sum e necessario para preparar as rotinas'
        log 'Copiando todas as rotinas padrao para dados/rotinas; elas permanecerao editaveis.'
        for routine_script in \
            entrypoint-servico.sh \
            gerenciar-repositorios.sh \
            gerar-indice-repositorio.sh \
            atualizar-navegadores.sh \
            verificar-navegadores-diariamente.sh; do
            cp -p "$SCRIPT_DIR/scripts/$routine_script" "$routines/scripts/$routine_script"
            chmod 0755 "$routines/scripts/$routine_script"
        done
        (
            cd "$routines"
            find scripts -type f -print0 |
                LC_ALL=C sort -z |
                xargs -0 sha256sum > SHA256SUMS
        )
        log "Manifesto criado: $routines_manifest"
    else
        log 'Scripts de rotinas existentes e manifesto foram preservados.'
    fi

    if [ ! -s "$custom_manifest" ]; then
        if find "$custom" -mindepth 2 -maxdepth 2 -type f \
            ! -path "$custom/cache/*" -print -quit 2>/dev/null | grep -q .; then
            die 'dados/slackbuilds-personalizados possui arquivos, mas SHA256SUMS esta ausente; os arquivos foram preservados'
        fi
        log 'Copiando Brave e Google Chrome para dados/slackbuilds-personalizados.'
        cp -Rp "$SCRIPT_DIR/slackbuilds/." "$custom/"
        find "$custom" -type f \( -name '*.SlackBuild' -o -name 'doinst.sh' \) \
            -exec chmod 0755 {} \;
        (
            cd "$custom"
            find . -mindepth 2 -maxdepth 2 -type f ! -path './cache/*' \
                -printf '%P\0' |
                LC_ALL=C sort -z |
                xargs -0 sha256sum > SHA256SUMS
        )
        log "Manifesto criado: $custom_manifest"
    else
        log 'SlackBuilds personalizados existentes e manifesto foram preservados.'
    fi
}

routines_source_fingerprint()
{
    routines="$DATA_DIR/rotinas"
    custom="$DATA_DIR/slackbuilds-personalizados"
    {
        printf '%s\n' '[rotinas/scripts]'
        (cd "$routines" && find scripts -type f -print0 |
            LC_ALL=C sort -z | xargs -0 sha256sum)
        printf '%s\n' '[rotinas/controle]'
        sha256sum "$routines/SHA256SUMS" | awk '{print $1 " SHA256SUMS"}'
        if [ -f "$routines/links.conf" ]; then
            sha256sum "$routines/links.conf" | awk '{print $1 " links.conf"}'
        else
            printf '%s\n' 'links.conf ausente'
        fi
        printf '%s\n' '[slackbuilds-personalizados]'
        (cd "$custom" && find . -mindepth 2 -maxdepth 2 -type f \
            ! -path './cache/*' -printf '%P\0' |
            LC_ALL=C sort -z | xargs -0 sha256sum)
        printf '%s\n' '[slackbuilds/controle]'
        sha256sum "$custom/SHA256SUMS" | awk '{print $1 " SHA256SUMS"}'
        if [ -f "$custom/links.conf" ]; then
            sha256sum "$custom/links.conf" | awk '{print $1 " links.conf"}'
        else
            printf '%s\n' 'links.conf ausente'
        fi
    } | sha256sum | awk '{print $1}'
}

routines_need_reload()
{
    applied_file="$STATE_DIR/rotinas-fontes.sha256"
    [ -s "$applied_file" ] || return 0
    current=$(routines_source_fingerprint)
    applied=$(sed -n '1p' "$applied_file")
    [ "$current" != "$applied" ]
}

first_vpn_question()
{
    marker="$STATE_DIR/pergunta-vpn-respondida"
    [ -e "$marker" ] && return 0

    cat <<'EOF'

O conteiner possui rede privada do Podman, mas o repositorio e publicado nas
portas do hospedeiro. Assim, ele pode ser acessado pelo IP da rede local ou
pelo IP Tailscale do proprio hospedeiro, sem instalar VPN dentro do conteiner.
EOF
    if confirm_default_yes 'Usar a VPN do hospedeiro e deixar a configuracao interna para depois?'; then
        printf '%s\n' 'host' > "$marker"
        log 'VPN definida no hospedeiro. Esta escolha pode ser revista com --configurar-vpn.'
    else
        configure_vpn
    fi
}

start_service()
{
    require_ports
    require_podman

    if ! podman image exists "$IMAGE"; then
        pull_image
    fi

    mkdir -p "$DATA_DIR/repositorios" "$DATA_DIR/resultados" \
        "$DATA_DIR/falhas" "$DATA_DIR/ignorados" "$DATA_DIR/cache" \
        "$DATA_DIR/logs" "$STATE_DIR"
    mkdir -p "$DATA_DIR/repositorios/navegadores/15.0/packages" \
        "$DATA_DIR/repositorios/navegadores/15.0/metadata"
    prepare_routines_directory
    reconcile_container_data_mount

    if container_exists; then
        if container_running; then
            if routines_need_reload; then
                log 'Alteracao nas rotinas ou SlackBuilds detectada; reiniciando somente o servico.'
                podman restart "$CONTAINER" >/dev/null
            else
                log "Servico ja esta ativo no conteiner $CONTAINER."
            fi
        else
            log "Iniciando o conteiner existente $CONTAINER."
            ensure_publish_ports_available
            start_created_container
        fi
    else
        ensure_publish_ports_available
        log "Criando o servico persistente $CONTAINER."
        create_service_container
        start_created_container
    fi

    elapsed=0
    log "Aguardando o Apache; a primeira copia da arvore SBo pode demorar alguns minutos."
    while [ "$elapsed" -lt "$STARTUP_TIMEOUT" ]; do
        if ! container_running; then
            podman logs --tail 200 "$CONTAINER" >&2 || :
            die 'o conteiner encerrou durante a inicializacao'
        fi
        if podman exec "$CONTAINER" /usr/local/bin/gerenciar-repositorios --servidor-pronto \
            >/dev/null 2>&1; then
            show_urls
            first_vpn_question
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        if [ $((elapsed % 30)) -eq 0 ]; then
            log "Inicializacao em andamento: ${elapsed}/${STARTUP_TIMEOUT} segundos."
        fi
    done

    podman logs --tail 200 "$CONTAINER" >&2 || :
    die "o Apache nao ficou pronto em $STARTUP_TIMEOUT segundos"
}

ensure_service()
{
    if container_running; then
        prepare_routines_directory
        if routines_need_reload; then
            start_service
        fi
    else
        start_service
    fi
}

memory_budget_mb()
{
    total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
    available_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
    [ -n "$total_kb" ] && [ -n "$available_kb" ] || return 1

    awk -v total="$total_kb" -v available="$available_kb" 'BEGIN {
        ceiling = int(total * 0.25)
        reserve = int(total * 0.10)
        if (reserve < 524288) reserve = 524288
        safe = available - reserve
        budget = ceiling < safe ? ceiling : safe
        if (budget < 524288) exit 1
        print int(budget / 1024)
    }'
}

read_cpu_sample()
{
    awk '/^cpu / {
        total = 0
        for (i = 2; i <= NF; i++) total += $i
        idle = $5 + $6
        print total, idle
        exit
    }' /proc/stat
}

cpu_budget()
{
    processors=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)
    set -- $(read_cpu_sample)
    total_one=$1
    idle_one=$2
    sleep 1
    set -- $(read_cpu_sample)
    total_two=$1
    idle_two=$2

    awk -v n="$processors" -v t1="$total_one" -v i1="$idle_one" \
        -v t2="$total_two" -v i2="$idle_two" 'BEGIN {
        delta = t2 - t1
        idle_delta = i2 - i1
        idle_ratio = delta > 0 ? idle_delta / delta : 0.25
        ceiling = n * 0.25
        available = n * idle_ratio - n * 0.10
        budget = ceiling < available ? ceiling : available
        if (budget < 0.25) budget = 0.25
        if (budget > ceiling) budget = ceiling
        printf "%.2f\n", budget
    }'
}

jobs_for_cpu()
{
    awk -v cpu="$1" 'BEGIN {
        jobs = int(cpu)
        if (jobs < 1) jobs = 1
        print jobs
    }'
}

resource_monitor()
{
    total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
    critical_kb=$(awk -v total="$total_kb" 'BEGIN {
        value = int(total * 0.05)
        if (value < 262144) value = 262144
        print value
    }')
    paused=0

    while container_running; do
        available_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        if [ "$available_kb" -lt "$critical_kb" ] && [ "$paused" -eq 0 ]; then
            log 'Pressao critica de memoria; pausando temporariamente o conteiner.'
            podman pause "$CONTAINER" >/dev/null 2>&1 || :
            paused=1
        elif [ "$available_kb" -ge "$critical_kb" ] && [ "$paused" -eq 1 ]; then
            log 'Memoria recuperada; retomando o conteiner.'
            podman unpause "$CONTAINER" >/dev/null 2>&1 || :
            paused=0
        fi
        sleep 5
    done
}

stop_monitor()
{
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || :
        wait "$MONITOR_PID" 2>/dev/null || :
        MONITOR_PID=''
    fi
}

run_task()
{
    task=$1
    shift
    ensure_service

    memory_mb=$(memory_budget_mb) || die 'nao ha pelo menos 512 MiB seguros para executar a tarefa'
    cpus=$(cpu_budget)
    jobs=$(jobs_for_cpu "$cpus")

    log "Tarefa: $task"
    log "RAM maxima do servico: ${memory_mb} MiB; CPU: ${cpus}; jobs: ${jobs}."
    if ! podman update --memory "${memory_mb}m" --memory-swap "${memory_mb}m" \
        --cpus "$cpus" "$CONTAINER" >/dev/null 2>&1; then
        log 'O Podman rootless nao aceitou limites dinamicos neste hospedeiro.'
        log 'A tarefa continuara; o paralelismo interno permanece limitado.'
    fi

    resource_monitor &
    MONITOR_PID=$!
    trap stop_monitor EXIT HUP INT TERM

    # A execucao fica anexada ao terminal; stdout e stderr aparecem ao vivo.
    set +e
    podman exec \
        --env "JOBS=$jobs" \
        --env "REPO_HTTP_PORT=$HTTP_PORT" \
        "$CONTAINER" \
        /usr/local/bin/gerenciar-repositorios "$task" "$@"
    rc=$?
    set -e

    stop_monitor
    trap - EXIT HUP INT TERM
    [ "$rc" -eq 0 ] || exit "$rc"
}

host_ipv4_list()
{
    if command -v ip >/dev/null 2>&1; then
        ip -o -4 addr show scope global 2>/dev/null |
            awk '{ sub(/\/.*/, "", $4); print $4 }'
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | tr ' ' '\n'
    fi
}

show_urls()
{
    log 'Repositorio disponivel nestes enderecos do hospedeiro:'
    found=0
    host_ipv4_list | while IFS= read -r address; do
        [ -n "$address" ] || continue
        found=1
        printf '  HTTP:  http://%s:%s/\n' "$address" "$HTTP_PORT"
        printf '  HTTPS: https://%s:%s/\n' "$address" "$HTTPS_PORT"
    done
    printf '  Local: http://127.0.0.1:%s/\n' "$HTTP_PORT"

    if command -v tailscale >/dev/null 2>&1; then
        tail_ip=$(tailscale ip -4 2>/dev/null | sed -n '1p' || :)
        if [ -n "$tail_ip" ]; then
            printf '  VPN:   http://%s:%s/\n' "$tail_ip" "$HTTP_PORT"
        fi
    fi
}

configure_vpn()
{
    mkdir -p "$STATE_DIR"
    cat <<'EOF'

Escolha de VPN:
  1) Usar Tailscale/Headscale configurado no hospedeiro (recomendado)
  2) Reservar configuracao de Tailscale dentro do conteiner
  3) Reservar cliente Tailscale ligado a um servidor Headscale
  4) Decidir depois

Observacao: Headscale e o servidor de controle. Dentro do conteiner, o cliente
continua sendo o Tailscale, apontado para a URL do seu servidor Headscale.
EOF
    printf '%s' 'Opcao [1]: '
    IFS= read -r answer || answer=''
    case "$answer" in
        ''|1) mode='host' ;;
        2) mode='tailscale-container' ;;
        3) mode='headscale-container' ;;
        4) mode='later' ;;
        *) die 'opcao de VPN invalida' ;;
    esac
    printf '%s\n' "$mode" > "$STATE_DIR/pergunta-vpn-respondida"
    case "$mode" in
        host)
            log 'O acesso VPN usara o IP Tailscale do hospedeiro e as portas publicadas.'
            ;;
        tailscale-container|headscale-container)
            log 'Escolha registrada. Credenciais e URL nao serao solicitadas nem gravadas agora.'
            log 'A configuracao sera feita posteriormente, quando voce executar --configurar-vpn novamente.'
            ;;
        later)
            log 'Configuracao de VPN adiada.'
            ;;
    esac
}

show_status()
{
    require_podman
    if podman image exists "$IMAGE"; then
        log "Imagem local: $IMAGE"
    else
        log "Imagem ainda nao baixada: $IMAGE"
    fi

    if container_exists; then
        podman ps -a --filter "name=^${CONTAINER}$" \
            --format 'Conteiner: {{.Names}}  Estado: {{.Status}}'
        container_running && show_urls || :
    else
        log 'Servico ainda nao foi criado.'
    fi

    if [ -d "$DATA_DIR/repositorios" ]; then
        du -sh "$DATA_DIR/repositorios" 2>/dev/null || :
    fi

    browser_state="$STATE_DIR/navegadores"
    if [ -d "$browser_state" ]; then
        for browser in brave-browser google-chrome; do
            if [ -s "$browser_state/$browser.version" ]; then
                version=$(sed -n '1p' "$browser_state/$browser.version")
                log "$browser Stable publicado: $version"
            fi
        done
        if [ -s "$browser_state/status-ultima-tentativa" ]; then
            status=$(sed -n '1p' "$browser_state/status-ultima-tentativa")
            log "Ultima verificacao dos navegadores: $status"
        fi
    fi
}

stop_service()
{
    require_podman
    if container_exists; then
        log "Parando $CONTAINER."
        podman stop --time 30 "$CONTAINER" >/dev/null
        log 'Servico parado; imagem e todos os dados foram preservados.'
    else
        log 'O servico ainda nao existe.'
    fi
}

remove_instance()
{
    require_podman
    if container_exists; then
        log 'A instancia sera removida; repositorios, resultados e imagem serao preservados.'
        if confirm_default_yes 'Continuar?'; then
            podman rm --force "$CONTAINER" >/dev/null
            log 'Instancia removida.'
        else
            log 'Operacao cancelada.'
        fi
    fi
}

update_image()
{
    require_podman
    was_running=0
    container_running && was_running=1 || :
    container_exists && podman rm --force "$CONTAINER" >/dev/null || :
    pull_image
    if [ "$was_running" -eq 1 ]; then
        start_service
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --preparar-hospedeiro) ACTION='prepare-host'; shift ;;
        --iniciar) ACTION='start'; shift ;;
        --sincronizar) ACTION='sync'; shift ;;
        --sincronizar-slackbuilds) ACTION='sync-sbo'; shift ;;
        --compilar-faltantes) ACTION='build-missing'; shift ;;
        --atualizar-navegadores) ACTION='update-browsers'; shift ;;
        --executar-tudo) ACTION='all'; shift ;;
        --pacote)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            ACTION='package'
            PACKAGE=$2
            shift 2
            ;;
        --configurar-vpn) ACTION='vpn'; shift ;;
        --fontes-slapt-get) ACTION='sources'; shift ;;
        --status) ACTION='status'; shift ;;
        --logs-servidor) ACTION='logs'; shift ;;
        --parar) ACTION='stop'; shift ;;
        --remover-instancia) ACTION='remove'; shift ;;
        --atualizar-imagem) ACTION='update-image'; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

case "$ACTION" in
    prepare-host) ;;
    '') usage; exit 2 ;;
    *)
        require_rootless_execution
        mkdir -p "$STATE_DIR"
        ;;
esac

case "$ACTION" in
    prepare-host) prepare_host ;;
    start) start_service ;;
    sync) run_task --sincronizar ;;
    sync-sbo) run_task --sincronizar-sbo ;;
    build-missing) run_task --compilar-faltantes ;;
    update-browsers) run_task --atualizar-navegadores ;;
    all) run_task --executar-tudo ;;
    package)
        case "$PACKAGE" in
            ''|*[!A-Za-z0-9+_.-]*) die 'nome de pacote invalido' ;;
        esac
        run_task --pacote "$PACKAGE"
        ;;
    vpn) configure_vpn ;;
    sources) run_task --fontes-slapt-get ;;
    status) show_status ;;
    logs)
        require_podman
        container_exists || die 'o servico ainda nao existe'
        exec podman logs --follow "$CONTAINER"
        ;;
    stop) stop_service ;;
    remove) remove_instance ;;
    update-image) update_image ;;
esac
