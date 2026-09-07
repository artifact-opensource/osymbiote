#!/bin/sh
set -eu

BASE_URL="${OSYM_BASE_URL:-http://localhost:18422}"
SETUP_PASSWORD="${OSYM_SETUP_PASSWORD:-osym-setup-$(date +%s)-$$}"
LOGIN_PASSWORD="${OSYM_LOGIN_PASSWORD:-$SETUP_PASSWORD}"
PROVIDER_AUTH_HEADER="${OPENROUTER_AUTH_HEADER:-}"
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

call_expect_code() {
    NAME="$1"
    EXPECTED="$2"
    shift 2
    echo "=== $NAME ==="
    RESP="$(curl -sS -i --max-time 8 "$@" 2>/dev/null || true)"
    CODE="$(printf '%s\n' "$RESP" | awk 'NR==1{print $2}')"
    BODY="$(printf '%s\n' "$RESP" | sed '1,/^\r\{0,1\}$/d')"
    echo "HTTP $CODE"
    echo "$BODY"
    if [ "$CODE" != "$EXPECTED" ]; then
        echo "ERROR: expected HTTP $EXPECTED"
        FAIL=1
    fi
    echo ""
}

extract_cookie() {
    printf '%s\n' "$1" | awk 'BEGIN{IGNORECASE=1}/^Set-Cookie: osym_session=/{sub(/\r/,"");sub(/^Set-Cookie: osym_session=/,"");sub(/;.*/,"");print;exit}'
}

echo "Testing OSymbiote agent..."
echo ""

SETUP_STATUS="$(curl -fsS --max-time 8 "$BASE_URL/setup/status" 2>/dev/null || true)"
echo "=== Setup Status ==="
echo "$SETUP_STATUS"
echo ""

if echo "$SETUP_STATUS" | grep -q '"needs_setup":[[:space:]]*true'; then
    call_expect_code "Chat blocked before setup" "403" -X POST -d "Hello" "$BASE_URL/chat"
    call_expect_code "Setup init" "200" -X POST -d "$SETUP_PASSWORD" "$BASE_URL/setup/init"
fi

call_expect_code "Login wrong password" "401" -X POST -d "__incorrect__" "$BASE_URL/auth/login"

echo "=== Login correct password ==="
LOGIN_RESP="$(curl -sS -i --max-time 8 -X POST -d "$LOGIN_PASSWORD" "$BASE_URL/auth/login" 2>/dev/null || true)"
LOGIN_CODE="$(printf '%s\n' "$LOGIN_RESP" | awk 'NR==1{print $2}')"
LOGIN_BODY="$(printf '%s\n' "$LOGIN_RESP" | sed '1,/^\r\{0,1\}$/d')"
COOKIE="$(extract_cookie "$LOGIN_RESP")"
echo "HTTP $LOGIN_CODE"
echo "$LOGIN_BODY"
if [ "$LOGIN_CODE" != "200" ] || [ -z "$COOKIE" ]; then
    echo "ERROR: login failed or cookie missing"
    FAIL=1
fi
echo ""

AUTH_COOKIE="Cookie: osym_session=$COOKIE"

call "Health (authed)" -H "$AUTH_COOKIE" "$BASE_URL/health"
call "Provider" "$BASE_URL/provider"
call "Hardware" "$BASE_URL/hardware"
call "Chat (authed)" -H "$AUTH_COOKIE" -X POST -d "Hello, are you alive?" "$BASE_URL/chat"
call "Intent (authed)" -H "$AUTH_COOKIE" -X POST -d "show network" "$BASE_URL/intent"
call "COMB Stage (authed)" -H "$AUTH_COOKIE" -X POST -d "Test memory entry from outside" "$BASE_URL/comb/stage"
call "COMB Recall (authed)" -H "$AUTH_COOKIE" "$BASE_URL/comb/recall"

if [ -n "$PROVIDER_AUTH_HEADER" ]; then
    call "AI (OpenRouter, authed)" -H "$AUTH_COOKIE" -X POST \
        -H "Authorization: ${PROVIDER_AUTH_HEADER}" \
        -d "Reply with one short sentence confirming connectivity." \
        "$BASE_URL/ai"
else
    echo "=== AI (OpenRouter, authed) ==="
    echo "SKIPPED: set OPENROUTER_AUTH_HEADER to test /ai provider call"
    echo ""
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Done. All required requests passed."
else
    echo "Done. One or more requests failed."
fi
exit "$FAIL"
