#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_CMD="${SCRIPT_DIR}/venv/bin/python"
if [ -f "$PYTHON_CMD" ]; then
    export PATH="${SCRIPT_DIR}/venv/bin:$PATH"
    export VIRTUAL_ENV="${SCRIPT_DIR}/venv"
else
    PYTHON_CMD="python3"
    if ! command -v python3 &> /dev/null; then
        PYTHON_CMD="python"
    fi
fi

HOST=${API_HOST:-0.0.0.0}
PORT=${API_PORT:-8765}

export UCSCXENA_TRUST_PROXY_HEADERS=true
export UCSCXENA_ENABLE_DOCS=true

echo "Starting UCSCXenaToolsPy TCGA Analysis API..."
echo "Host: $HOST"
echo "Port: $PORT"
echo "Python: $PYTHON_CMD"
echo ""

"$PYTHON_CMD" -m uvicorn ucscxenatoolspy.api_service.main:app --host "$HOST" --port "$PORT" "$@"