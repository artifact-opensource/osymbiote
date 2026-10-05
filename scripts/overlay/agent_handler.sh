#!/bin/sh
# OSymbiote HTTP agent — one request per invocation (tcpsvd / nc -e).
OSYM_LIB="${OSYM_LIB:-/usr/lib/osym}"
OSYM_UI="${OSYM_UI:-/usr/share/osym/ui.html}"
. "$OSYM_LIB/lib.sh"

read -r -t 15 REQUEST_LINE || exit 0
REQUEST_LINE="$(printf '%s' "$REQUEST_LINE" | tr -d '\r')"
[ -n "$REQUEST_LINE" ] || exit 0
METHOD="${REQUEST_LINE%% *}"
PATH_REQ="${REQUEST_LINE#* }"
PATH_REQ="${PATH_REQ%% *}"
PATH_ONLY="${PATH_REQ%%\?*}"
case "$PATH_ONLY" in /api/*) PATH_ONLY="${PATH_ONLY#/api}" ;; esac
PATH_ONLY="${PATH_ONLY%/}"
[ -n "$PATH_ONLY" ] || PATH_ONLY="/"
QUERY=""
case "$PATH_REQ" in *\?*) QUERY="${PATH_REQ#*\?}" ;; esac

CONTENT_LENGTH=0
AUTH_HEADER=""
COOKIE_HEADER=""
SESSION_HEADER=""
TOOL_CALL_TEST_HEADER=""
while IFS= read -r -t 15 header; do
    header="$(printf '%s' "$header" | tr -d '\r')"
    [ -z "$header" ] && break
    case "$header" in
        Content-Length:*|content-length:*) CONTENT_LENGTH="$(printf '%s' "$header" | awk '{print $2}')" ;;
        Authorization:*|authorization:*) AUTH_HEADER="${header#*: }" ;;
        Cookie:*|cookie:*) COOKIE_HEADER="${header#*: }" ;;
        X-Session-Token:*|x-session-token:*) SESSION_HEADER="${header#*: }" ;;
        X-Tool-Call-Test:*|x-tool-call-test:*) TOOL_CALL_TEST_HEADER="${header#*: }" ;;
    esac
done

BODY=""
case "$CONTENT_LENGTH" in ''|*[!0-9]*) CONTENT_LENGTH=0 ;; esac
BODY_TOO_LARGE=0
if [ "$CONTENT_LENGTH" -gt 65536 ]; then BODY_TOO_LARGE=1; fi
if [ "$CONTENT_LENGTH" -gt 0 ]; then
    [ "$BODY_TOO_LARGE" -eq 1 ] && CONTENT_LENGTH=0
    if [ "$CONTENT_LENGTH" -gt 0 ]; then
        BODY_FILE="$(mktemp /tmp/osym-body.XXXXXX)" || exit 0
        if ! timeout 15 head -c "$CONTENT_LENGTH" > "$BODY_FILE" 2>/dev/null; then
            rm -f "$BODY_FILE"; exit 0
        fi
        [ "$(wc -c < "$BODY_FILE" | tr -d ' ')" -eq "$CONTENT_LENGTH" ] || {
            rm -f "$BODY_FILE"; exit 0
        }
        BODY="$(cat "$BODY_FILE")"
        rm -f "$BODY_FILE"
    fi
fi

STATUS="200 OK"
CONTENT_TYPE="application/json"
EXTRA_HEADERS=""
RESP=""
RESP_FILE=""

UPTIME="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
CORES="$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)"
MEM_FREE="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_TOTAL="$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
ARCH="$(uname -m 2>/dev/null || echo unknown)"
OPENAI_BASE_URL="$(cfg_get base_url)"
OPENAI_MODEL="$(cfg_get model)"
AI_PROVIDER="$(cfg_get provider)"

SESSION_TTL=900
RATE_LIMIT_PER_MIN=15
LOCKOUT_AFTER=5
LOCKOUT_SECONDS=60
AUTH_FAIL_FILE="$AUTH_DIR/auth.fail"
AUTH_RATE_FILE="$AUTH_DIR/auth.rate"

cookie_value() {
    printf '%s' "$COOKIE_HEADER" | tr ';' '\n' | sed 's/^ *//' | grep -E "^$1=" | head -n1 | cut -d= -f2-
}

session_token() {
    if [ -n "$SESSION_HEADER" ]; then printf '%s' "$SESSION_HEADER"; return; fi
    cookie_value "osym_session"
}

is_authenticated() {
    TOKEN="$(session_token)"
    [ -n "$TOKEN" ] || return 1
    [ -f "$SESSION_FILE" ] || return 1
    STORED_TOKEN="$(awk -F'|' 'NR==1{print $1}' "$SESSION_FILE" 2>/dev/null)"
    EXPIRES_AT="$(awk -F'|' 'NR==1{print $2}' "$SESSION_FILE" 2>/dev/null)"
    [ "$TOKEN" = "$STORED_TOKEN" ] || return 1
    [ "${EXPIRES_AT:-0}" -gt "$(now_epoch)" ] || return 1
    return 0
}

enforce_auth() {
    if ! is_authenticated; then
        STATUS="401 Unauthorized"
        RESP='{"error":"auth_required","login":"POST /auth/login"}'
        return 1
    fi
    return 0
}

check_rate_limit() {
    NOW="$(now_epoch)"
    SLOT=$((NOW / 60))
    CUR_SLOT=0
    CUR_COUNT=0
    if [ -f "$AUTH_RATE_FILE" ]; then
        CUR_SLOT="$(awk '{print $1}' "$AUTH_RATE_FILE" 2>/dev/null || echo 0)"
        CUR_COUNT="$(awk '{print $2}' "$AUTH_RATE_FILE" 2>/dev/null || echo 0)"
    fi
    if [ "$CUR_SLOT" -eq "$SLOT" ]; then
        if [ "$CUR_COUNT" -ge "$RATE_LIMIT_PER_MIN" ]; then
            STATUS="429 Too Many Requests"
            RESP='{"error":"rate_limited","retry_seconds":60}'
            return 1
        fi
        CUR_COUNT=$((CUR_COUNT + 1))
    else
        CUR_SLOT="$SLOT"
        CUR_COUNT=1
    fi
    printf '%s %s\n' "$CUR_SLOT" "$CUR_COUNT" > "$AUTH_RATE_FILE"
    return 0
}

check_lockout() {
    NOW="$(now_epoch)"
    LOCK_UNTIL=0
    [ -f "$AUTH_FAIL_FILE" ] && LOCK_UNTIL="$(awk '{print $2}' "$AUTH_FAIL_FILE" 2>/dev/null || echo 0)"
    if [ "${LOCK_UNTIL:-0}" -gt "$NOW" ]; then
        STATUS="429 Too Many Requests"
        RESP="{\"error\":\"locked\",\"retry_seconds\":$((LOCK_UNTIL - NOW))}"
        return 1
    fi
    return 0
}

record_auth_failure() {
    NOW="$(now_epoch)"
    FAIL_COUNT=0
    LOCK_UNTIL=0
    [ -f "$AUTH_FAIL_FILE" ] && FAIL_COUNT="$(awk '{print $1}' "$AUTH_FAIL_FILE" 2>/dev/null || echo 0)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$FAIL_COUNT" -ge "$LOCKOUT_AFTER" ] && LOCK_UNTIL=$((NOW + LOCKOUT_SECONDS))
    printf '%s %s\n' "$FAIL_COUNT" "$LOCK_UNTIL" > "$AUTH_FAIL_FILE"
}

record_auth_success() { printf '0 0\n' > "$AUTH_FAIL_FILE"; }

handle_setup_init() {
    if ! lock_acquire auth; then
        STATUS="503 Service Unavailable"; RESP='{"error":"auth_busy"}'; return
    fi
    if ! check_rate_limit || ! check_lockout; then :
    elif is_setup_complete; then
        STATUS="409 Conflict"; RESP='{"error":"already_initialized"}'
    elif [ "$METHOD" != "POST" ]; then
        STATUS="405 Method Not Allowed"; RESP='{"error":"use POST with password body"}'
    elif [ "${#BODY}" -lt 8 ]; then
        STATUS="400 Bad Request"; RESP='{"error":"password_too_short","min_length":8}'
    elif ! set_password_unlocked "$BODY"; then
        STATUS="500 Internal Server Error"; RESP='{"error":"setup_failed"}'
    else
        RESP='{"status":"initialized","next":"POST /auth/login"}'
    fi
    lock_release
}

handle_auth_login() {
    if ! lock_acquire auth; then
        STATUS="503 Service Unavailable"; RESP='{"error":"auth_busy"}'; return
    fi
    if ! check_rate_limit || ! check_lockout; then :
    elif [ "$METHOD" != "POST" ]; then
        STATUS="405 Method Not Allowed"; RESP='{"error":"use POST with password body"}'
    elif [ -z "$BODY" ]; then
        STATUS="400 Bad Request"; RESP='{"error":"missing_password"}'
    else
        SALT="$(cut -d: -f1 "$PASS_FILE" 2>/dev/null)"
        EXPECTED_HASH="$(cut -d: -f2 "$PASS_FILE" 2>/dev/null)"
        GOT_HASH="$(hash_secret "$BODY" "$SALT")"
        if [ -n "$EXPECTED_HASH" ] && [ "$GOT_HASH" = "$EXPECTED_HASH" ]; then
            record_auth_success
            NOW="$(now_epoch)"
            EXPIRES_AT=$((NOW + SESSION_TTL))
            TOKEN_SRC="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
            if [ -z "$TOKEN_SRC" ] && [ -r /dev/urandom ]; then
                TOKEN_SRC="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            fi
            [ -n "$TOKEN_SRC" ] || TOKEN_SRC="${NOW}-$$-$(cat /proc/uptime 2>/dev/null)"
            TOKEN="$(printf '%s' "$TOKEN_SRC" | sha256sum | awk '{print $1}')"
            _session_tmp="$SESSION_FILE.$$"
            if printf '%s|%s\n' "$TOKEN" "$EXPIRES_AT" > "$_session_tmp" &&
                chmod 600 "$_session_tmp" 2>/dev/null && mv "$_session_tmp" "$SESSION_FILE"; then
                EXTRA_HEADERS="Set-Cookie: osym_session=${TOKEN}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_TTL}\r\n"
                RESP="{\"status\":\"ok\",\"expires_in\":$SESSION_TTL}"
            else
                rm -f "$_session_tmp"
                STATUS="500 Internal Server Error"; RESP='{"error":"session_create_failed"}'
            fi
        else
            record_auth_failure
            STATUS="401 Unauthorized"; RESP='{"error":"invalid_credentials"}'
        fi
    fi
    lock_release
}

handle_auth_logout() {
    if lock_acquire auth; then
        rm -f "$SESSION_FILE" 2>/dev/null || true
        lock_release
        EXTRA_HEADERS="Set-Cookie: osym_session=deleted; HttpOnly; SameSite=Strict; Path=/; Max-Age=0\r\n"
        RESP='{"status":"logged_out"}'
    else
        STATUS="503 Service Unavailable"; RESP='{"error":"auth_busy"}'
    fi
}

need_post() {
    if [ "$METHOD" != "POST" ]; then
        STATUS="405 Method Not Allowed"
        RESP='{"error":"use POST"}'
        return 1
    fi
    return 0
}

# Apply a complete config request under one lock so rejected updates never partially commit.
stage_config_value() {
    _stage_next="$1.next"
    grep -v "^$2=" "$1" > "$_stage_next"
    _grep_status=$?
    [ "$_grep_status" -le 1 ] || { rm -f "$_stage_next"; return 1; }
    printf '%s=%s\n' "$2" "$3" >> "$_stage_next" || { rm -f "$_stage_next"; return 1; }
    mv "$_stage_next" "$1"
}

stage_config_unset() {
    _stage_next="$1.next"
    grep -v "^$2=" "$1" > "$_stage_next"
    _grep_status=$?
    [ "$_grep_status" -le 1 ] || { rm -f "$_stage_next"; return 1; }
    mv "$_stage_next" "$1"
}

apply_llm_body() {
    lock_acquire config || { printf 'config_busy'; return; }
    _stage="$OSYM_DATA/config.stage.$$"
    _body_file="$OSYM_DATA/config.body.$$"
    _errors="$OSYM_DATA/config.errors.$$"
    if [ -f "$CFG_FILE" ]; then
        cp "$CFG_FILE" "$_stage" 2>/dev/null || {
            lock_release; printf 'config_stage_failed'; return
        }
    else
        : > "$_stage" || { lock_release; printf 'config_stage_failed'; return; }
    fi
    printf '%s\n' "$BODY" > "$_body_file" || {
        rm -f "$_stage" "$_body_file"; lock_release; printf 'config_stage_failed'; return
    }
    : > "$_errors"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        k="${line%%=*}"
        v="${line#*=}"
        [ "$k" != "$line" ] || { printf 'bad_line\n' >> "$_errors"; continue; }
        if [ "$k" = "preset" ]; then
            case "$v" in
                openrouter)
                    stage_config_value "$_stage" provider openrouter && stage_config_value "$_stage" base_url https://openrouter.ai/api/v1 || printf 'config_stage_failed\n' >> "$_errors" ;;
                openai)
                    stage_config_value "$_stage" provider openai && stage_config_value "$_stage" base_url https://api.openai.com/v1 || printf 'config_stage_failed\n' >> "$_errors" ;;
                ollama)
                    stage_config_value "$_stage" provider ollama && stage_config_value "$_stage" base_url http://10.0.2.2:11434/v1 || printf 'config_stage_failed\n' >> "$_errors" ;;
                lmstudio)
                    stage_config_value "$_stage" provider lmstudio && stage_config_value "$_stage" base_url http://10.0.2.2:1234/v1 || printf 'config_stage_failed\n' >> "$_errors" ;;
                *) printf 'bad_preset\n' >> "$_errors" ;;
            esac
        elif [ "$k" = "api_key" ] && [ -z "$v" ]; then
            stage_config_unset "$_stage" api_key || printf 'config_stage_failed\n' >> "$_errors"
        else
            cfg_validate "$k" "$v"
            case $? in
                0) stage_config_value "$_stage" "$k" "$_val" || printf 'config_stage_failed\n' >> "$_errors" ;;
                1) printf 'unknown_key:%s\n' "$k" >> "$_errors" ;;
                *) printf 'invalid_value:%s\n' "$k" >> "$_errors" ;;
            esac
        fi
    done < "$_body_file"
    if [ ! -s "$_errors" ]; then
        if ! chmod 600 "$_stage" 2>/dev/null || ! mv "$_stage" "$CFG_FILE"; then
            printf 'config_commit_failed\n' >> "$_errors"
        fi
    fi
    cat "$_errors"
    rm -f "$_stage" "$_stage.next" "$_body_file" "$_errors"
    lock_release
}

run_intent() {
    INTENT_INPUT="$(printf '%s' "$BODY" | tr '[:upper:]' '[:lower:]')"
    INTENT_ID=""
    case "$INTENT_INPUT" in
        *network*|*ip*|*route*) INTENT_ID="show_network" ;;
        *disk*|*storage*|*filesystem*|*space*) INTENT_ID="disk_usage" ;;
        *process*|*ps*|*task*) INTENT_ID="process_list" ;;
        *memory*|*ram*) INTENT_ID="memory_status" ;;
        *uptime*|*alive*) INTENT_ID="uptime_status" ;;
    esac
    case "$ARCH" in
        x86_64|amd64) ARCH_FAMILY="x86_64" ;;
        aarch64|arm64) ARCH_FAMILY="arm64" ;;
        riscv64) ARCH_FAMILY="riscv64" ;;
        *) ARCH_FAMILY="generic" ;;
    esac
    CMD=""
    case "$INTENT_ID" in
        show_network) if command -v ip >/dev/null 2>&1; then CMD="ip addr show; ip route"; elif command -v ifconfig >/dev/null 2>&1; then CMD="ifconfig"; fi ;;
        disk_usage) command -v df >/dev/null 2>&1 && CMD="df -h" ;;
        process_list) command -v ps >/dev/null 2>&1 && CMD="ps" ;;
        memory_status) if command -v free >/dev/null 2>&1; then CMD="free"; else CMD="cat /proc/meminfo"; fi ;;
        uptime_status) CMD="cat /proc/uptime" ;;
    esac
    if [ -z "$INTENT_ID" ]; then
        STATUS="400 Bad Request"
        RESP='{"error":"unsupported_intent","supported":["show network","disk usage","process list","memory status","uptime"]}'
    elif [ -z "$CMD" ]; then
        STATUS="501 Not Implemented"
        RESP="{\"error\":\"capability_missing\",\"intent\":\"$INTENT_ID\",\"arch\":\"$ARCH_FAMILY\"}"
    else
        CMD_OUT="$(sh -c "$CMD" 2>&1 | head -n 40)"
        RESP="{\"intent\":\"$INTENT_ID\",\"arch\":\"$ARCH_FAMILY\",\"command\":\"$(json_escape "$CMD")\",\"output\":\"$(json_escape "$CMD_OUT")\"}"
    fi
}

if [ "$BODY_TOO_LARGE" -eq 1 ]; then
    STATUS="413 Payload Too Large"
    RESP='{"error":"request_too_large","max_bytes":65536}'
elif [ "$METHOD" = "OPTIONS" ]; then
    STATUS="204 No Content"
elif ! is_setup_complete; then
    case "$PATH_ONLY" in
        /|/ui|/setup/status|/setup/init|/health) : ;;
        *)
            STATUS="403 Forbidden"
            RESP='{"error":"setup_required","setup":"POST /setup/init"}'
            ;;
    esac
fi

if [ -z "$RESP" ] && [ "$STATUS" = "200 OK" ]; then
    case "$PATH_ONLY" in
        /)
            STATUS="302 Found"
            CONTENT_TYPE="text/plain"
            EXTRA_HEADERS="Location: /ui\r\n"
            RESP="redirect"
            ;;
        /ui)
            if [ -f "$OSYM_UI" ]; then
                CONTENT_TYPE="text/html; charset=utf-8"
                RESP_FILE="$OSYM_UI"
            else
                STATUS="500 Internal Server Error"
                RESP='{"error":"ui_missing"}'
            fi
            ;;
        /setup/status)
            if is_setup_complete; then RESP='{"needs_setup":false,"setup_complete":true}'
            else RESP='{"needs_setup":true,"setup_complete":false}'; fi
            ;;
        /setup/init)
            handle_setup_init
            ;;
        /auth/login)
            handle_auth_login
            ;;
        /auth/logout)
            handle_auth_logout
            ;;
        /health)
            if is_authenticated; then AUTH_STATE=true; else AUTH_STATE=false; fi
            if is_setup_complete; then SETUP_STATE=true; else SETUP_STATE=false; fi
            RESP="{\"status\":\"alive\",\"agent\":\"osymbiote\",\"version\":\"0.3.0\",\"uptime_s\":${UPTIME:-0},\"cores\":$CORES,\"mem_free_kb\":${MEM_FREE:-0},\"mem_total_kb\":${MEM_TOTAL:-0},\"setup_complete\":$SETUP_STATE,\"authenticated\":$AUTH_STATE}"
            ;;
        /provider)
            RESP="{\"provider\":\"$AI_PROVIDER\",\"base_url\":\"$OPENAI_BASE_URL\",\"model\":\"$OPENAI_MODEL\",\"protocol\":\"openai-compatible\"}"
            ;;
        /hardware)
            RESP="$(cat "${OSYM_HW:-/run/hardware.json}" 2>/dev/null || echo '{"error":"no manifest"}')"
            ;;
        /llm)
            if enforce_auth; then
                if [ "$METHOD" = "POST" ]; then
                    ERRS="$(apply_llm_body)"
                    if [ -n "$ERRS" ]; then
                        STATUS="400 Bad Request"
                        RESP="{\"error\":\"invalid_config\",\"detail\":\"$(json_escape "$ERRS")\"}"
                    else
                        RESP="$(llm_json)"
                    fi
                else
                    RESP="$(llm_json)"
                fi
            fi
            ;;
        /llm/test)
            if enforce_auth && need_post; then
                if llm_chat "${BODY:-Reply with the single word: pong}"; then
                    RESP="{\"ok\":true,\"reply\":\"$LLM_REPLY\"}"
                else
                    STATUS="502 Bad Gateway"
                    RESP="{\"ok\":false,\"error\":\"$(json_escape "$LLM_ERR")\"}"
                fi
            fi
            ;;
        /llm/models)
            if enforce_auth; then
                if [ -z "$(cfg_get api_key)" ]; then
                    STATUS="400 Bad Request"; RESP='{"error":"no_api_key"}'
                else
                    RESP="$(llm_models_raw)"
                    [ -n "$RESP" ] || { STATUS="502 Bad Gateway"; RESP='{"error":"provider_request_failed"}'; }
                fi
            fi
            ;;
        /prompt)
            if enforce_auth; then
                case "$METHOD" in
                    POST) prompt_set "$BODY" ;;
                    DELETE) prompt_reset ;;
                esac
                RESP="{\"prompt\":\"$(json_escape "$(prompt_get)")\",\"default\":$([ -s "$PROMPT_FILE" ] && echo false || echo true)}"
            fi
            ;;
        /history)
            if enforce_auth; then
                if [ "$METHOD" = "DELETE" ]; then
                    history_clear
                    RESP='{"status":"cleared"}'
                else
                    LIMIT="$(printf '%s' "$QUERY" | sed -n 's/.*limit=\([0-9]\{1,4\}\).*/\1/p')"
                    RESP="$(history_json "${LIMIT:-100}")"
                fi
            fi
            ;;
        /comb/recall|/memory)
            if enforce_auth; then
                case "$METHOD" in
                    POST)
                        if [ -n "$BODY" ]; then "$OSYM_COMB" stage "$BODY"; RESP='{"status":"staged"}'
                        else STATUS="400 Bad Request"; RESP='{"error":"no body"}'; fi
                        ;;
                    DELETE) "$OSYM_COMB" clear; RESP='{"status":"cleared"}' ;;
                    *)
                        MEM_LINES="$("$OSYM_COMB" recall "${QUERY##*limit=}" 2>/dev/null | sed 's/$/,/' | tr -d '\n' | sed 's/,$//')"
                        RESP="[$MEM_LINES]"
                        ;;
                esac
            fi
            ;;
        /comb/stage)
            if enforce_auth && need_post; then
                if [ -n "$BODY" ]; then "$OSYM_COMB" stage "$BODY"; RESP='{"status":"staged"}'
                else RESP='{"error":"no body"}'; fi
            fi
            ;;
        /comb/stats|/memory/stats)
            if enforce_auth; then RESP="$("$OSYM_COMB" stats)"; fi
            ;;
        /chat)
            if enforce_auth; then
                if [ -z "$BODY" ]; then
                    RESP='{"error":"send POST with message body"}'
                elif llm_chat "$BODY"; then
                    RESP="{\"response\":\"$LLM_REPLY\",\"mode\":\"llm\",\"model\":\"$OPENAI_MODEL\",\"uptime\":${UPTIME:-0},\"arch\":\"$ARCH\"}"
                else
                    BODY_ESC="$(json_escape "$BODY")"
                    "$OSYM_COMB" stage "user: $BODY"
                    if [ "$LLM_ERR" = "no_api_key" ]; then
                        RESP="{\"response\":\"No LLM API key configured. Set one in the LLM tab or with 'llm key <key>' in the shell. I heard: $BODY_ESC\",\"mode\":\"echo\",\"error\":\"no_api_key\",\"uptime\":${UPTIME:-0},\"arch\":\"$ARCH\"}"
                    else
                        STATUS="502 Bad Gateway"
                        RESP="{\"error\":\"$(json_escape "$LLM_ERR")\",\"mode\":\"llm\"}"
                    fi
                fi
            fi
            ;;
        /intent|/command)
            if enforce_auth && need_post; then
                if [ -z "$BODY" ]; then STATUS="400 Bad Request"; RESP='{"error":"missing_intent"}'
                else run_intent; fi
            fi
            ;;
        /ai)
            if enforce_auth && need_post; then
                KEY_HDR="$AUTH_HEADER"
                [ -n "$KEY_HDR" ] || { [ -n "$(cfg_get api_key)" ] && KEY_HDR="Bearer $(cfg_get api_key)"; }
                if [ -z "$KEY_HDR" ]; then
                    STATUS="401 Unauthorized"
                    RESP='{"error":"missing_provider_authorization","hint":"send provider token in Authorization header or configure api_key"}'
                elif [ -z "$BODY" ]; then
                    RESP='{"error":"send POST with prompt body"}'
                else
                    PROMPT_ESC="$(json_escape "$BODY")"
                    if [ "$TOOL_CALL_TEST_HEADER" = "1" ]; then
                        PAYLOAD="{\"model\":\"$OPENAI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT_ESC\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_uptime\",\"description\":\"Read system uptime in seconds\",\"parameters\":{\"type\":\"object\",\"properties\":{},\"required\":[]}}}],\"tool_choice\":\"auto\",\"stream\":false}"
                    else
                        PAYLOAD="{\"model\":\"$OPENAI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT_ESC\"}],\"stream\":false}"
                    fi
                    AI_RESP="$(wget -qO- -T 20 \
                        --header="Content-Type: application/json" \
                        --header="Authorization: $KEY_HDR" \
                        --header="HTTP-Referer: https://osymbiote.local" \
                        --header="X-Title: OSymbiote" \
                        --post-data="$PAYLOAD" \
                        "${OPENAI_BASE_URL%/}/chat/completions" 2>/dev/null || true)"
                    if [ -n "$AI_RESP" ]; then RESP="$AI_RESP"
                    else STATUS="502 Bad Gateway"; RESP='{"error":"provider_request_failed"}'; fi
                fi
            fi
            ;;
        /exec)
            if enforce_auth && need_post; then
                if [ -z "$BODY" ]; then
                    STATUS="400 Bad Request"; RESP='{"error":"missing_command"}'
                else
                    EXEC_OUT="$(timeout 30 sh -c "$BODY" 2>&1 | head -c 32768)"
                    RESP="{\"command\":\"$(json_escape "$BODY")\",\"output\":\"$(json_escape "$EXEC_OUT")\"}"
                fi
            fi
            ;;
        /system/network|/system/processes|/system/disk|/system/memory)
            if enforce_auth; then
                case "$PATH_ONLY" in
                    */network) BODY="show network" ;;
                    */processes) BODY="process list" ;;
                    */disk) BODY="disk usage" ;;
                    */memory) BODY="memory status" ;;
                esac
                run_intent
            fi
            ;;
        *)
            STATUS="404 Not Found"
            RESP='{"error":"unknown_path","routes":["/ui","/setup/status","/setup/init","/auth/login","/auth/logout","/health","/provider","/hardware","/llm","/llm/test","/llm/models","/prompt","/history","/chat","/ai","/intent","/memory","/memory/stats","/comb/stage","/comb/recall","/comb/stats","/exec","/system/network","/system/processes","/system/disk","/system/memory"]}'
            ;;
    esac
fi

if [ -n "$RESP_FILE" ]; then
    RESP_LEN="$(wc -c < "$RESP_FILE" | tr -d ' ')"
else
    RESP_LEN="$(printf '%s' "$RESP" | wc -c | tr -d ' ')"
fi
printf "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, X-Session-Token\r\nAccess-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n%b\r\n" "$STATUS" "$CONTENT_TYPE" "$RESP_LEN" "$EXTRA_HEADERS"
if [ -n "$RESP_FILE" ]; then cat "$RESP_FILE"; else printf '%s' "$RESP"; fi
