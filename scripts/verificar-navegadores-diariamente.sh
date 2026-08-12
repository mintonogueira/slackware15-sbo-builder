#!/bin/bash

# Agendador simples do servico persistente. Faz no maximo uma tentativa a cada
# 24 horas e deixa toda a saida nos logs do conteiner e na pasta persistente.

set -Eeuo pipefail

WORKROOT=${WORKROOT:-/work}
INTERVAL=${BROWSER_CHECK_INTERVAL_SECONDS:-86400}
POLL_INTERVAL=${BROWSER_POLL_INTERVAL_SECONDS:-300}
INITIAL_DELAY=${BROWSER_INITIAL_DELAY_SECONDS:-30}
STATE_DIR="$WORKROOT/.estado/navegadores"
LAST_ATTEMPT="$STATE_DIR/ultima-tentativa-epoch"
LOG_DIR="$WORKROOT/logs/navegadores"

log()
{
    printf '%s\n' "[agendador-navegadores] $*"
}

[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
    log "intervalo diario invalido: $INTERVAL"
    exit 1
}
[[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || {
    log "intervalo de consulta invalido: $POLL_INTERVAL"
    exit 1
}
[[ "$INITIAL_DELAY" =~ ^[0-9]+$ ]] || {
    log "atraso inicial invalido: $INITIAL_DELAY"
    exit 1
}

mkdir -p "$STATE_DIR" "$LOG_DIR"
log 'Ativo: Brave Stable e Google Chrome Stable serao verificados a cada 24 horas.'
if [ ! -s "$LAST_ATTEMPT" ] && [ "$INITIAL_DELAY" -gt 0 ]; then
    log "Primeira verificacao automatica em ${INITIAL_DELAY}s; uma execucao manual tem prioridade."
    sleep "$INITIAL_DELAY"
fi

while :; do
    now=$(date +%s)
    last=0
    if [ -s "$LAST_ATTEMPT" ]; then
        read -r last < "$LAST_ATTEMPT" || last=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi

    if [ "$now" -ge $((last + INTERVAL)) ]; then
        log_file="$LOG_DIR/$(date -u +%Y-%m-%d).log"
        log 'Iniciando a verificacao diaria dos navegadores.'
        set +e
        /usr/local/bin/atualizar-navegadores --todos \
            2>&1 | tee -a "$log_file"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 0 ]; then
            log 'Verificacao diaria concluida com sucesso.'
        else
            log "A verificacao diaria falhou (codigo $rc); detalhes: $log_file"
        fi
    fi
    sleep "$POLL_INTERVAL"
done
