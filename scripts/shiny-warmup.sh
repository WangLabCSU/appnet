#!/bin/bash
# Shiny App Warmup - OncoHarmony Europe
# Touch all Shiny apps via shiny-portal Docker to keep R processes alive

SHINY_BASE="http://localhost:3939"
LOG_DIR="/home/deploy/appnet/logs"
LOG_FILE="$LOG_DIR/shiny-warmup.log"
TIMEOUT=30

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Shiny Warmup Start ==="

APPS=$(curl -s --connect-timeout 5 "$SHINY_BASE/" 2>/dev/null \
    | grep -oP 'href="[^"]+/"' \
    | sed 's|href="||;s|/"||' \
    | grep -v '^$\|shiny_logs')

if [ -z "$APPS" ]; then
    log "ERROR: Cannot fetch app list from $SHINY_BASE"
    exit 1
fi

log "Found apps: $(echo $APPS | tr '\n' ' ')"

WARMED=0
FAILED=0

for app in $APPS; do
    url="$SHINY_BASE/$app/"
    log "Warming: $url"
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time "$TIMEOUT" "$url" 2>/dev/null)
    if [ "$HTTP_CODE" = "200" ]; then
        log "  OK $app (HTTP $HTTP_CODE)"
        WARMED=$((WARMED + 1))
    else
        log "  WARN $app (HTTP $HTTP_CODE)"
        FAILED=$((FAILED + 1))
    fi
done

log "=== Done: $WARMED warmed, $FAILED failed ==="
