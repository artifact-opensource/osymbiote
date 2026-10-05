#!/bin/sh
# OSymbiote shared library — sourced by the shell (osh) and the HTTP agent.

OSYM_DATA="${OSYM_DATA:-/data/osymbiote}"
OSYM_COMB="${OSYM_COMB:-/bin/comb}"
CFG_FILE="$OSYM_DATA/config"
ENV_FILE="${OSYM_ENV_FILE:-$OSYM_DATA/.env}"
SYSTEM_CONFIG_FILE="${OSYM_SYSTEM_CONFIG_FILE:-$OSYM_DATA/system.conf}"
HIST_FILE="$OSYM_DATA/history.jsonl"
PROMPT_FILE="$OSYM_DATA/system_prompt"
AUTH_DIR="$OSYM_DATA/auth"
PASS_FILE="$AUTH_DIR/password.hash"
SETUP_MARKER="$AUTH_DIR/setup.done"
SESSION_FILE="$AUTH_DIR/session.state"
mkdir -p "$AUTH_DIR" 2>/dev/null

DEFAULT_SYSTEM_PROMPT="You are OSymbiote, an AI agent that is the operating system of this machine. Be concise, accurate and helpful."
CFG_KEYS="provider base_url model api_key temperature max_tokens history_turns"
SYSTEM_CONFIG_KEYS="web_role fs_read_role fs_write_role exec_role config_role sudo_mode owner_uid owner_gid"

env_key_valid() {
    case "$1" in
        OSYM_OPENAI_API_KEY|OSYM_OPENAI_BASE_URL|OSYM_OPENAI_MODEL|OSYM_AI_PROVIDER|\
        OPENAI_API_KEY|OPENROUTER_API_KEY|ANTHROPIC_API_KEY|GEMINI_API_KEY|GROQ_API_KEY) return 0 ;;
        *) return 1 ;;
    esac
}

env_load() {
    [ -r "$ENV_FILE" ] || return 0
    [ "${OSYM_OPENAI_API_KEY+x}" = x ] || { _v="$(env_file_get OSYM_OPENAI_API_KEY)"; [ -z "$_v" ] || export "OSYM_OPENAI_API_KEY=$_v"; }
    [ "${OSYM_OPENAI_BASE_URL+x}" = x ] || { _v="$(env_file_get OSYM_OPENAI_BASE_URL)"; [ -z "$_v" ] || export "OSYM_OPENAI_BASE_URL=$_v"; }
    [ "${OSYM_OPENAI_MODEL+x}" = x ] || { _v="$(env_file_get OSYM_OPENAI_MODEL)"; [ -z "$_v" ] || export "OSYM_OPENAI_MODEL=$_v"; }
    [ "${OSYM_AI_PROVIDER+x}" = x ] || { _v="$(env_file_get OSYM_AI_PROVIDER)"; [ -z "$_v" ] || export "OSYM_AI_PROVIDER=$_v"; }
    [ "${OPENAI_API_KEY+x}" = x ] || { _v="$(env_file_get OPENAI_API_KEY)"; [ -z "$_v" ] || export "OPENAI_API_KEY=$_v"; }
    [ "${OPENROUTER_API_KEY+x}" = x ] || { _v="$(env_file_get OPENROUTER_API_KEY)"; [ -z "$_v" ] || export "OPENROUTER_API_KEY=$_v"; }
    [ "${ANTHROPIC_API_KEY+x}" = x ] || { _v="$(env_file_get ANTHROPIC_API_KEY)"; [ -z "$_v" ] || export "ANTHROPIC_API_KEY=$_v"; }
    [ "${GEMINI_API_KEY+x}" = x ] || { _v="$(env_file_get GEMINI_API_KEY)"; [ -z "$_v" ] || export "GEMINI_API_KEY=$_v"; }
    [ "${GROQ_API_KEY+x}" = x ] || { _v="$(env_file_get GROQ_API_KEY)"; [ -z "$_v" ] || export "GROQ_API_KEY=$_v"; }
}

env_file_get() {
    env_key_valid "$1" || return 1
    awk -v key="$1" 'index($0, "=") && substr($0, 1, index($0, "=") - 1) == key { value = substr($0, index($0, "=") + 1) } END { if (value != "") print value }' "$ENV_FILE" 2>/dev/null
}

env_stage_value() {
    _env_file="$1"; _env_key="$2"; _env_value="$3"
    env_key_valid "$_env_key" || return 1
    grep -v "^$_env_key=" "$_env_file" > "$_env_file.next" || [ "$?" -eq 1 ] || return 1
    printf '%s=%s\n' "$_env_key" "$_env_value" >> "$_env_file.next" || return 1
    mv "$_env_file.next" "$_env_file"
}

env_stage_unset() {
    _env_file="$1"; _env_key="$2"
    env_key_valid "$_env_key" || return 1
    grep -v "^$_env_key=" "$_env_file" > "$_env_file.next" || [ "$?" -eq 1 ] || return 1
    mv "$_env_file.next" "$_env_file"
}

env_stage_clear_secrets() {
    for _env_key in OSYM_OPENAI_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY \
        ANTHROPIC_API_KEY GEMINI_API_KEY GROQ_API_KEY; do
        env_stage_unset "$1" "$_env_key" || return 1
    done
}

env_set() {
    cfg_validate api_key "$2" || return 2
    lock_acquire config || return 3
    mkdir -p "$OSYM_DATA" || { lock_release; return 3; }
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    _tmp="$ENV_FILE.$$"
    if ! cp "$ENV_FILE" "$_tmp" || ! env_stage_value "$_tmp" OSYM_OPENAI_API_KEY "$_val" || ! chmod 600 "$_tmp" || ! mv "$_tmp" "$ENV_FILE"; then
        rm -f "$_tmp" "$_tmp.next"
        lock_release
        return 3
    fi
    export "OSYM_OPENAI_API_KEY=$_val"
    lock_release
}

env_unset() {
    lock_acquire config || return 2
    if [ -f "$ENV_FILE" ]; then
        _tmp="$ENV_FILE.$$"
        if ! cp "$ENV_FILE" "$_tmp" || ! env_stage_clear_secrets "$_tmp"; then
            rm -f "$_tmp" "$_tmp.next"
            lock_release
            return 2
        fi
        chmod 600 "$_tmp" 2>/dev/null
        mv "$_tmp" "$ENV_FILE" || { rm -f "$_tmp"; lock_release; return 2; }
    fi
    unset OSYM_OPENAI_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY GROQ_API_KEY
    if [ -f "$CFG_FILE" ]; then
        _tmp="$CFG_FILE.$$"
        grep -v '^api_key=' "$CFG_FILE" > "$_tmp" || true
        chmod 600 "$_tmp" 2>/dev/null
        mv "$_tmp" "$CFG_FILE" || { rm -f "$_tmp"; lock_release; return 2; }
    fi
    lock_release
}

env_load

json_escape() {
    printf '%s' "$1" | od -An -v -tu1 | LC_ALL=C awk '{
        for (i = 1; i <= NF; i++) {
            c = $i + 0
            if (c < 32) printf "\\u%04x", c
            else if (c == 34) printf "\\\""
            else if (c == 92) printf "\\\\"
            else printf "%c", c
        }
    }'
}

json_unescape() {
    sed -e 's/\\\\/\x01/g' -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's/\\"/"/g' -e 's/\\\//\//g' -e 's/\x01/\\/g'
}

now_epoch() { date +%s 2>/dev/null || echo 0; }
now_iso() { date -Iseconds 2>/dev/null || date; }

# ── Config ──
cfg_key_valid() {
    for _k in $CFG_KEYS; do [ "$_k" = "$1" ] && return 0; done
    return 1
}

provider_default() {
    case "$1" in
        base_url) printf '%s' "${OSYM_OPENAI_BASE_URL:-https://openrouter.ai/api/v1}" ;;
        model) printf '%s' "${OSYM_OPENAI_MODEL:-openrouter/free}" ;;
        provider) printf '%s' "${OSYM_AI_PROVIDER:-openrouter}" ;;
        temperature) printf '0.7' ;;
        max_tokens) printf '512' ;;
        history_turns) printf '10' ;;
        *) printf '' ;;
    esac
}

cfg_get() {
    case "$1" in
        api_key)
            _v="${OSYM_OPENAI_API_KEY:-}"
            [ -n "$_v" ] || _v="${OPENAI_API_KEY:-}"
            [ -n "$_v" ] || _v="$(env_file_get OSYM_OPENAI_API_KEY)"
            [ -n "$_v" ] || _v="$(env_file_get OPENAI_API_KEY)"
            case "$(cfg_get provider)" in
                openrouter) _v="${_v:-${OPENROUTER_API_KEY:-$(env_file_get OPENROUTER_API_KEY)}}" ;;
                anthropic) _v="${_v:-${ANTHROPIC_API_KEY:-$(env_file_get ANTHROPIC_API_KEY)}}" ;;
                gemini) _v="${_v:-${GEMINI_API_KEY:-$(env_file_get GEMINI_API_KEY)}}" ;;
                groq) _v="${_v:-${GROQ_API_KEY:-$(env_file_get GROQ_API_KEY)}}" ;;
            esac
            [ -n "$_v" ] || _v="$(grep '^api_key=' "$CFG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
            ;;
        *) _v="$(grep "^$1=" "$CFG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-)" ;;
    esac
    [ -n "$_v" ] || _v="$(provider_default "$1")"
    if [ -n "$_v" ]; then
        cfg_validate "$1" "$_v" >/dev/null 2>&1 || _v=""
    fi
    case "$1" in
        model) case "$_v" in openrouter/openrouter/*) _v="${_v#openrouter/}" ;; esac ;;
    esac
    printf '%s' "$_v"
}

# Lock directories serialize read/modify/write operations across shell and HTTP workers.
lock_acquire() {
    mkdir -p "$OSYM_DATA" || return 1
    LOCK_PATH="$OSYM_DATA/$1.lock"
    _wait=0
    while ! mkdir "$LOCK_PATH" 2>/dev/null; do
        _owner="$(cat "$LOCK_PATH/pid" 2>/dev/null)"
        if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
            :
        elif [ -n "$_owner" ] || [ "$_wait" -ge 2 ]; then
            _stale="$LOCK_PATH.stale.$$"
            if mv "$LOCK_PATH" "$_stale" 2>/dev/null; then
                rm -rf "$_stale"
                continue
            fi
        fi
        [ "$_wait" -lt 30 ] || { LOCK_PATH=""; return 1; }
        sleep 1
        _wait=$((_wait + 1))
    done
    if ! printf '%s\n' "$$" > "$LOCK_PATH/pid"; then
        rmdir "$LOCK_PATH" 2>/dev/null || true
        LOCK_PATH=""
        return 1
    fi
    return 0
}

lock_release() {
    [ -n "${LOCK_PATH:-}" ] || return 0
    _owner="$(cat "$LOCK_PATH/pid" 2>/dev/null)"
    [ "$_owner" = "$$" ] && rm -rf "$LOCK_PATH"
    LOCK_PATH=""
}

# cfg_set KEY VALUE — returns 0 on success, 1 invalid key, 2 invalid value
cfg_validate() {
    cfg_key_valid "$1" || return 1
    _val="$(printf '%s' "$2" | tr -d '\r\n')"
    case "$1" in
        temperature)
            printf '%s' "$_val" | grep -Eq '^(0|[1-9][0-9]*)(\.[0-9]+)?$' || return 2
            awk -v value="$_val" 'BEGIN { exit !(value >= 0 && value <= 2) }' || return 2 ;;
        max_tokens)
            printf '%s' "$_val" | grep -Eq '^[1-9][0-9]{0,4}$' || return 2
            [ "$_val" -le 65535 ] || return 2 ;;
        history_turns)
            printf '%s' "$_val" | grep -Eq '^(0|[1-9][0-9]{0,2})$' || return 2
            [ "$_val" -le 100 ] || return 2 ;;
        base_url) printf '%s' "$_val" | grep -Eq '^https?://[^ "]+$' || return 2 ;;
        model|provider) printf '%s' "$_val" | grep -Eq '^[A-Za-z0-9._:/@+-]+$' || return 2 ;;
        api_key) printf '%s' "$_val" | grep -Eq '^[^ "\\]+$' || return 2 ;;
    esac
    return 0
}

cfg_set() {
    cfg_validate "$1" "$2" || return $?
    [ "$1" != api_key ] || { env_set api_key "$2"; return $?; }
    lock_acquire config || return 3
    mkdir -p "$OSYM_DATA"
    _tmp="$CFG_FILE.$$"
    grep -v "^$1=" "$CFG_FILE" 2>/dev/null > "$_tmp" || true
    printf '%s=%s\n' "$1" "$_val" >> "$_tmp"
    chmod 600 "$_tmp" 2>/dev/null
    if mv "$_tmp" "$CFG_FILE"; then
        lock_release
        return 0
    fi
    rm -f "$_tmp"
    lock_release
    return 3
}

cfg_unset() {
    cfg_key_valid "$1" || return 1
    [ "$1" != api_key ] || { env_unset; return $?; }
    lock_acquire config || return 2
    if [ ! -f "$CFG_FILE" ]; then lock_release; return 0; fi
    _tmp="$CFG_FILE.$$"
    grep -v "^$1=" "$CFG_FILE" > "$_tmp" || true
    chmod 600 "$_tmp" 2>/dev/null
    if mv "$_tmp" "$CFG_FILE"; then
        lock_release
        return 0
    fi
    rm -f "$_tmp"
    lock_release
    return 2
}

system_default() {
    case "$1" in
        web_role) printf admin ;;
        fs_read_role) printf viewer ;;
        fs_write_role) printf admin ;;
        exec_role) printf root ;;
        config_role) printf root ;;
        sudo_mode) printf confirm ;;
        owner_uid|owner_gid) printf 0 ;;
        *) printf '' ;;
    esac
}

system_get() {
    case " $SYSTEM_CONFIG_KEYS " in *" $1 "*) ;; *) return 1 ;; esac
    _v="$(grep "^$1=" "$SYSTEM_CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    if [ -n "$_v" ]; then system_validate "$1" "$_v" || _v=""; fi
    [ -n "$_v" ] || _v="$(system_default "$1")"
    printf '%s' "$_v"
}

role_rank() {
    case "$1" in viewer) printf 1 ;; operator) printf 2 ;; admin) printf 3 ;; root) printf 4 ;; *) printf 0 ;; esac
}

role_allows() {
    [ "$(role_rank "$(system_get web_role)")" -ge "$(role_rank "$1")" ]
}

system_validate() {
    case " $SYSTEM_CONFIG_KEYS " in *" $1 "*) ;; *) return 1 ;; esac
    case "$1" in
        web_role|fs_read_role|fs_write_role|exec_role|config_role)
            case "$2" in viewer|operator|admin|root) return 0 ;; *) return 2 ;; esac ;;
        sudo_mode) case "$2" in confirm|disabled) return 0 ;; *) return 2 ;; esac ;;
        owner_uid|owner_gid)
            case "$2" in ''|*[!0-9]*|0[0-9]*) return 2 ;; esac
            [ "${#2}" -le 5 ] && [ "$2" -le 65535 ] || return 2 ;;
    esac
}

system_set() {
    system_validate "$1" "$2" || return $?
    lock_acquire system || return 3
    mkdir -p "$OSYM_DATA" || { lock_release; return 3; }
    _tmp="$SYSTEM_CONFIG_FILE.$$"
    grep -v "^$1=" "$SYSTEM_CONFIG_FILE" 2>/dev/null > "$_tmp" || true
    printf '%s=%s\n' "$1" "$2" >> "$_tmp"
    chmod 600 "$_tmp" 2>/dev/null
    if mv "$_tmp" "$SYSTEM_CONFIG_FILE"; then lock_release; return 0; fi
    rm -f "$_tmp"
    lock_release
    return 3
}

system_config_json() {
    printf '{"web_role":"%s","fs_read_role":"%s","fs_write_role":"%s","exec_role":"%s","config_role":"%s","sudo_mode":"%s","owner_uid":%s,"owner_gid":%s}' \
        "$(system_get web_role)" "$(system_get fs_read_role)" "$(system_get fs_write_role)" \
        "$(system_get exec_role)" "$(system_get config_role)" "$(system_get sudo_mode)" \
        "$(system_get owner_uid)" "$(system_get owner_gid)"
}

mask_key() {
    _k="$(cfg_get api_key)"
    if [ -z "$_k" ]; then printf ''; return; fi
    _n="${#_k}"
    if [ "$_n" -le 8 ]; then printf '****'; else printf '%s...%s' "$(printf '%s' "$_k" | cut -c1-4)" "$(printf '%s' "$_k" | cut -c$((_n-3))-)"; fi
}

llm_json() {
    _ks=false; [ -n "$(cfg_get api_key)" ] && _ks=true
    printf '{"provider":"%s","base_url":"%s","model":"%s","api_key_set":%s,"api_key_masked":"%s","temperature":%s,"max_tokens":%s,"history_turns":%s,"protocol":"openai-compatible"}' \
        "$(cfg_get provider)" "$(cfg_get base_url)" "$(cfg_get model)" "$_ks" "$(mask_key)" \
        "$(cfg_get temperature)" "$(cfg_get max_tokens)" "$(cfg_get history_turns)"
}

llm_preset() {
    case "$1" in
        openrouter) cfg_set provider openrouter; cfg_set base_url https://openrouter.ai/api/v1 ;;
        openai) cfg_set provider openai; cfg_set base_url https://api.openai.com/v1 ;;
        ollama) cfg_set provider ollama; cfg_set base_url http://10.0.2.2:11434/v1 ;;
        lmstudio) cfg_set provider lmstudio; cfg_set base_url http://10.0.2.2:1234/v1 ;;
        *) return 1 ;;
    esac
}

# ── System prompt ──
prompt_get() {
    if [ -s "$PROMPT_FILE" ]; then cat "$PROMPT_FILE"; else printf '%s' "$DEFAULT_SYSTEM_PROMPT"; fi
}
prompt_set() {
    mkdir -p "$OSYM_DATA"
    printf '%s' "$1" > "$PROMPT_FILE"
}
prompt_reset() { rm -f "$PROMPT_FILE"; }

# ── History (one JSON object per line: {"role","content","ts"}; content stored escaped) ──
history_add() { # role escaped_content
    mkdir -p "$OSYM_DATA"
    printf '{"role":"%s","content":"%s","ts":"%s"}\n' "$1" "$2" "$(now_iso)" >> "$HIST_FILE"
}
history_recent() { # N
    [ -f "$HIST_FILE" ] && tail -n "${1:-50}" "$HIST_FILE"
}
history_json() {
    _body="$(history_recent "${1:-100}" | sed 's/$/,/' | tr -d '\n' | sed 's/,$//')"
    printf '[%s]' "$_body"
}
history_clear() {
    lock_acquire history || return 1
    rm -f "$HIST_FILE"
    lock_release
}

# ── LLM ──
# llm_call_raw ESCAPED_USER_TEXT → raw provider response on stdout (return 1 on transport failure)
llm_call_raw() {
    _key="$(cfg_get api_key)"
    _turns="$(cfg_get history_turns)"
    _msgs="{\"role\":\"system\",\"content\":\"$(json_escape "$(prompt_get)")\"},"
    if [ "$_turns" -gt 0 ] 2>/dev/null; then
        _h="$(history_recent $((_turns * 2)) | sed 's/,"ts":"[^"]*"}$/}/' | sed 's/$/,/' | tr -d '\n')"
        _msgs="$_msgs$_h"
    fi
    _msgs="$_msgs{\"role\":\"user\",\"content\":\"$1\"}"
    _payload="{\"model\":\"$(cfg_get model)\",\"messages\":[$_msgs],\"temperature\":$(cfg_get temperature),\"max_tokens\":$(cfg_get max_tokens),\"stream\":false}"
    wget -qO- -T 60 \
        --header="Content-Type: application/json" \
        --header="Authorization: Bearer $_key" \
        --header="HTTP-Referer: https://osymbiote.local" \
        --header="X-Title: OSymbiote" \
        --post-data="$_payload" \
        "$(cfg_get base_url | sed 's#/*$##')/chat/completions" 2>/dev/null
}

llm_tools_raw() {
    _messages="${1#\[}"
    _messages="${_messages%\]}"
    _payload="{\"model\":\"$(cfg_get model)\",\"messages\":[{\"role\":\"system\",\"content\":\"$(json_escape "$(prompt_get) Never claim a tool succeeded until its result confirms success. Mutating operations require explicit user approval.")\"},$_messages],\"temperature\":$(cfg_get temperature),\"max_tokens\":$(cfg_get max_tokens),\"stream\":false,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"os_exec\",\"description\":\"Propose a shell command. It will only run after explicit user approval.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"],\"additionalProperties\":false}}},{\"type\":\"function\",\"function\":{\"name\":\"os_read_file\",\"description\":\"Read a text file from the guest system.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}}},{\"type\":\"function\",\"function\":{\"name\":\"os_write_file\",\"description\":\"Propose writing text to a file. It will only be written after explicit user approval.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}}}],\"tool_choice\":\"auto\"}"
    wget -qO- -T 60 \
        --header="Content-Type: application/json" \
        --header="Authorization: ******" \
        --header="HTTP-Referer: https://osymbiote.local" \
        --header="X-Title: OSymbiote" \
        --post-data="$_payload" \
        "$(cfg_get base_url | sed 's#/*$##')/chat/completions" 2>/dev/null
}

# llm_chat PLAIN_TEXT — sets LLM_REPLY (JSON-escaped) or LLM_ERR; records history on success
llm_chat() {
    LLM_REPLY=""; LLM_ERR=""
    if ! lock_acquire history; then LLM_ERR="history_busy"; return 1; fi
    if [ -z "$(cfg_get api_key)" ]; then LLM_ERR="no_api_key"; lock_release; return 1; fi
    _u="$(json_escape "$1")"
    _raw="$(llm_call_raw "$_u" | tr -d '\n')"
    if [ -z "$_raw" ]; then LLM_ERR="provider_request_failed"; lock_release; return 1; fi
    LLM_REPLY="$(printf '%s' "$_raw" | sed -nE 's/.*"content": *"(([^"\\]|\\.)*)".*/\1/p')"
    if [ -z "$LLM_REPLY" ]; then
        LLM_ERR="$(printf '%s' "$_raw" | sed -nE 's/.*"message": *"(([^"\\]|\\.)*)".*/\1/p' | head -n 1)"
        [ -n "$LLM_ERR" ] || LLM_ERR="empty_or_unparseable_response"
        lock_release
        return 1
    fi
    history_add user "$_u"
    history_add assistant "$LLM_REPLY"
    lock_release
    return 0
}

llm_models_raw() {
    wget -qO- -T 20 --header="Authorization: Bearer $(cfg_get api_key)" \
        "$(cfg_get base_url | sed 's#/*$##')/models" 2>/dev/null
}

# ── Auth ──
hash_secret() { printf '%s' "$2:$1" | sha256sum 2>/dev/null | awk '{print $1}'; }
is_setup_complete() { [ -f "$SETUP_MARKER" ] && [ -s "$PASS_FILE" ]; }
set_password_unlocked() { # plain; caller holds the auth lock
    [ "${#1}" -ge 8 ] || return 1
    mkdir -p "$AUTH_DIR"
    _salt="$(printf '%s' "$(now_epoch)-$$-$(cat /proc/uptime 2>/dev/null)-$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')" | sha256sum | cut -c1-16)"
    printf '%s:%s\n' "$_salt" "$(hash_secret "$1" "$_salt")" > "$PASS_FILE"
    chmod 600 "$PASS_FILE" 2>/dev/null
    now_iso > "$SETUP_MARKER"
    rm -f "$SESSION_FILE"
}

set_password() {
    lock_acquire auth || return 1
    set_password_unlocked "$1"
    _rc=$?
    lock_release
    return "$_rc"
}
