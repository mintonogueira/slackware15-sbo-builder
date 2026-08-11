#!/bin/sh

# Controlador POSIX executado no hospedeiro.

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
DATA_DIR=${SLACKBUILD_DATA_DIR:-"$SCRIPT_DIR/dados"}
STATE_DIR="$DATA_DIR/.estado"
CID_FILE="$STATE_DIR/container.cid"
PID_FILE="$STATE_DIR/controlador.pid"
MONITOR_PID_FILE="$STATE_DIR/monitor.pid"
IMAGE=${SLACKBUILD_IMAGE:-'ghcr.io/mintonogueira/slackware15-sbo-builder:15.0'}
LABEL='io.mintonogueira.slackware15-sbo-builder=runtime'
PACKAGE=''
ACTION='build'
RUN_NAME=''
RUN_PID=''
MONITOR_PID=''

usage()
{
    cat <<'EOF'
Uso:
  ./compilar-slackbuilds.sh --pacote NOME
  ./compilar-slackbuilds.sh --parar
  ./compilar-slackbuilds.sh --status
  ./compilar-slackbuilds.sh --atualizar-imagem
  ./compilar-slackbuilds.sh --limpar-falhas
  ./compilar-slackbuilds.sh --limpar-testes

Resultados concluidos: dados/resultados/
Tentativas malsucedidas: dados/falhas/
EOF
}

log()
{
    printf '%s\n' "[controle] $*"
}

require_podman()
{
    if ! command -v podman >/dev/null 2>&1; then
        printf '%s\n' 'ERRO: Podman nao esta instalado ou nao esta no PATH.' >&2
        exit 1
    fi
}

is_running_pid()
{
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

container_id()
{
    if [ -s "$CID_FILE" ]; then
        sed -n '1p' "$CID_FILE"
    fi
}

stop_execution()
{
    require_podman
    cid=$(container_id)
    if [ -n "$cid" ] && podman container exists "$cid" 2>/dev/null; then
        log "Interrompendo o conteiner $cid."
        podman stop --time 15 "$cid" >/dev/null 2>&1 || :
        podman rm --force "$cid" >/dev/null 2>&1 || :
    fi

    if [ -s "$PID_FILE" ]; then
        controller_pid=$(sed -n '1p' "$PID_FILE")
        if is_running_pid "$controller_pid" && [ "$controller_pid" -ne "$$" ]; then
            kill -TERM "$controller_pid" 2>/dev/null || :
        fi
    fi

    rm -f "$CID_FILE" "$PID_FILE" "$MONITOR_PID_FILE"
    log 'Execucao interrompida. Imagem e resultados foram preservados.'
}

cleanup_runtime()
{
    trap - EXIT HUP INT TERM
    if [ -n "$MONITOR_PID" ]; then
        kill "$MONITOR_PID" 2>/dev/null || :
        wait "$MONITOR_PID" 2>/dev/null || :
    fi
    cid=$(container_id)
    if [ -n "$cid" ] && command -v podman >/dev/null 2>&1; then
        podman rm --force "$cid" >/dev/null 2>&1 || :
    fi
    rm -f "$CID_FILE" "$PID_FILE" "$MONITOR_PID_FILE"
}

interrupt()
{
    log 'Interrupcao solicitada; encerrando a instancia temporaria.'
    cid=$(container_id)
    if [ -n "$cid" ] && command -v podman >/dev/null 2>&1; then
        podman stop --time 15 "$cid" >/dev/null 2>&1 || :
    fi
    exit 130
}

confirm()
{
    printf '%s' "$1 [s/N] "
    IFS= read -r answer
    case "$answer" in
        s|S|sim|SIM|Sim) return 0 ;;
        *) return 1 ;;
    esac
}

safe_clear_directory()
{
    target=$1
    case "$target" in
        "$DATA_DIR"/*) ;;
        *)
            printf '%s\n' "ERRO: caminho de limpeza recusado: $target" >&2
            exit 1
            ;;
    esac
    [ -d "$target" ] || return 0
    find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

clean_failures()
{
    target="$DATA_DIR/falhas"
    if [ ! -d "$target" ] || [ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        log 'Nao existem tentativas malsucedidas para apagar.'
        return 0
    fi
    find "$target" -mindepth 1 -maxdepth 1 -print
    if confirm 'Apagar somente as tentativas malsucedidas listadas?'; then
        safe_clear_directory "$target"
        log 'Tentativas malsucedidas apagadas.'
    else
        log 'Limpeza cancelada.'
    fi
}

clean_tests()
{
    log 'Serao apagados resultados, falhas, parciais e estado deste projeto.'
    log 'A imagem baixada pelo Podman sera preservada.'
    if ! confirm 'Continuar com a limpeza completa dos testes?'; then
        log 'Limpeza cancelada.'
        return 0
    fi

    stop_execution >/dev/null 2>&1 || :
    safe_clear_directory "$DATA_DIR/resultados"
    safe_clear_directory "$DATA_DIR/falhas"
    safe_clear_directory "$DATA_DIR/.parciais"
    safe_clear_directory "$STATE_DIR"

    podman ps -a --filter "label=$LABEL" --format '{{.ID}}' 2>/dev/null |
    while IFS= read -r stale_id; do
        [ -n "$stale_id" ] || continue
        podman rm --force "$stale_id" >/dev/null 2>&1 || :
    done
    log 'Resultados de testes e residuos de execucao foram apagados.'
}

show_status()
{
    require_podman
    if podman image exists "$IMAGE"; then
        log "Imagem disponivel localmente: $IMAGE"
    else
        log "Imagem ainda nao baixada: $IMAGE"
    fi

    cid=$(container_id)
    if [ -n "$cid" ] && podman container exists "$cid" 2>/dev/null; then
        podman ps -a --filter "id=$cid" --format 'Container: {{.ID}}  Estado: {{.Status}}'
    else
        log 'Nenhuma compilacao ativa.'
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
    cid=$1
    total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
    critical_kb=$(awk -v total="$total_kb" 'BEGIN {
        value = int(total * 0.05)
        if (value < 262144) value = 262144
        print value
    }')
    paused=0

    while podman container exists "$cid" 2>/dev/null; do
        available_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        if [ "$available_kb" -lt "$critical_kb" ]; then
            if [ "$paused" -eq 0 ]; then
                log 'Pressao critica de memoria; pausando temporariamente a compilacao.'
                podman pause "$cid" >/dev/null 2>&1 || :
                paused=1
            fi
        elif [ "$paused" -eq 1 ]; then
            log 'Memoria do hospedeiro recuperada; retomando a compilacao.'
            podman unpause "$cid" >/dev/null 2>&1 || :
            paused=0
        fi

        if [ "$paused" -eq 0 ]; then
            current_cpu=$(cpu_budget)
            podman update --cpus "$current_cpu" "$cid" >/dev/null 2>&1 || :
        else
            sleep 5
        fi
        sleep 5
    done
}

pull_image()
{
    require_podman
    log "Baixando a imagem pronta: $IMAGE"
    if ! podman pull "$IMAGE"; then
        printf '%s\n' 'ERRO: nao foi possivel baixar a imagem do GHCR.' >&2
        printf '%s\n' 'Confirme se o pacote do GitHub esta publico.' >&2
        exit 1
    fi
}

run_build()
{
    require_podman

    if [ -s "$PID_FILE" ]; then
        previous_pid=$(sed -n '1p' "$PID_FILE")
        if is_running_pid "$previous_pid"; then
            printf '%s\n' 'ERRO: ja existe uma compilacao ativa.' >&2
            exit 1
        fi
    fi

    if ! podman image exists "$IMAGE"; then
        pull_image
    fi

    memory_mb=$(memory_budget_mb) || {
        printf '%s\n' 'ERRO: nao ha pelo menos 512 MiB seguros para o conteiner.' >&2
        exit 1
    }
    cpus=$(cpu_budget)
    jobs=$(jobs_for_cpu "$cpus")

    mkdir -p "$STATE_DIR" "$DATA_DIR/resultados" "$DATA_DIR/falhas" \
        "$DATA_DIR/.parciais"
    printf '%s\n' "$$" > "$PID_FILE"
    RUN_NAME="slackware15-sbo-${PACKAGE}-$$"

    log "RAM maxima: ${memory_mb} MiB (nunca acima de 25% do total)."
    log "CPU inicial: ${cpus} nucleo(s) equivalente(s), teto de 25%."
    log "Jobs de compilacao: $jobs."

    nice -n 10 ionice -c 2 -n 7 podman run \
        --name "$RUN_NAME" \
        --label "$LABEL" \
        --cidfile "$CID_FILE" \
        --rm \
        --memory "${memory_mb}m" \
        --memory-swap "${memory_mb}m" \
        --cpus "$cpus" \
        --pids-limit 4096 \
        --security-opt no-new-privileges \
        --volume "$DATA_DIR:/work:rw" \
        "$IMAGE" --pacote "$PACKAGE" --jobs "$jobs" &
    RUN_PID=$!

    tries=0
    while [ ! -s "$CID_FILE" ] && is_running_pid "$RUN_PID" && [ "$tries" -lt 100 ]; do
        sleep 1
        tries=$((tries + 1))
    done

    cid=$(container_id)
    if [ -n "$cid" ]; then
        resource_monitor "$cid" &
        MONITOR_PID=$!
        printf '%s\n' "$MONITOR_PID" > "$MONITOR_PID_FILE"
    fi

    set +e
    wait "$RUN_PID"
    rc=$?
    set -e
    cleanup_runtime

    if [ "$rc" -ne 0 ]; then
        log "Compilacao terminou com erro (codigo $rc)."
        exit "$rc"
    fi
    log 'Compilacao concluida.'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --pacote)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PACKAGE=$2
            shift 2
            ;;
        --parar) ACTION='stop'; shift ;;
        --status) ACTION='status'; shift ;;
        --atualizar-imagem) ACTION='pull'; shift ;;
        --limpar-falhas) ACTION='clean-failures'; shift ;;
        --limpar-testes) ACTION='clean-tests'; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" "$DATA_DIR/resultados" "$DATA_DIR/falhas" "$DATA_DIR/.parciais"

case "$ACTION" in
    stop) stop_execution ;;
    status) show_status ;;
    pull) pull_image ;;
    clean-failures) clean_failures ;;
    clean-tests) require_podman; clean_tests ;;
    build)
        case "$PACKAGE" in
            ''|*[!A-Za-z0-9+_.-]*)
                printf '%s\n' 'ERRO: informe um nome valido com --pacote.' >&2
                exit 2
                ;;
        esac
        trap cleanup_runtime EXIT
        trap interrupt HUP INT TERM
        run_build
        ;;
esac
