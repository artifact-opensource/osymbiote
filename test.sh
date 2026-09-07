#!/bin/sh
set -eu

BASE_URL="${OSYM_BASE_URL:-http://localhost:18422}"
FAIL=0

call() {
    NAME="$1"
    shift
    echo "=== $NAME ==="
    if RESP="$(curl -fsS --max-time 8 "$@" 2>/dev/null)"; then
        echo "$RESP"
    else
        echo "ERROR: request failed"
        FAIL=1
    fi
    echo ""
}

echo "Testing OSymbiote agent..."
echo ""

call "Health" "$BASE_URL/health"
call "Provider" "$BASE_URL/provider"
call "Hardware" "$BASE_URL/hardware"
call "Chat" -X POST -d "Hello, are you alive?" "$BASE_URL/chat"
call "COMB Stage" -X POST -d "Test memory entry from outside" "$BASE_URL/comb/stage"
call "COMB Recall" "$BASE_URL/comb/recall"

if [ -n "${OPENROUTER_AUTH_HEADER:-}" ]; then
    call "AI (OpenRouter)" -X POST \
        -H "Authorization: ${OPENROUTER_AUTH_HEADER}" \
        -d "Reply with one short sentence confirming connectivity." \
        "$BASE_URL/ai"
else
    echo "=== AI (OpenRouter) ==="
    echo "SKIPPED: set OPENROUTER_AUTH_HEADER to test /ai"
    echo ""
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Done. All required requests passed."
else
    echo "Done. One or more requests failed."
fi
exit "$FAIL"
