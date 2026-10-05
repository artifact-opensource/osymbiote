#!/bin/sh
# OSymbiote shared library — sourced by the shell (osh) and the HTTP agent.

OSYM_DATA="${OSYM_DATA:-/data/osymbiote}"
OSYM_COMB="${OSYM_COMB:-/bin/comb}"
CFG_FILE="$OSYM_DATA/config"
HIST_FILE="$OSYM_DATA/history.jsonl"
PROMPT_FILE="$OSYM_DATA/system_prompt"
AUTH_DIR="$OSYM_DATA/auth"
PASS_FILE="$AUTH_DIR/password.hash"
SETUP_MARKER="$AUTH_DIR/setup.done"
SESSION_FILE="$AUTH_DIR/session.state"
mkdir -p "$AUTH_DIR" 2>/dev/null

DEFAULT_SYSTEM_PROMPT="You are OSymbiote, an AI agent that is the operating system of this machine. Be concise, accurate and helpful."
CFG_KEYS="provider base_url model api_key temperature max_tokens history_turns"

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
    _v="$(grep "^$1=" "$CFG_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
    [ -n "$_v" ] || _v="$(provider_default "$1")"
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
        temperature) printf '%s' "$_val" | grep -Eq '^(0|[1-9][0-9]*)(\.[0-9]+)?$' || return 2 ;;
        max_tokens|history_turns) printf '%s' "$_val" | grep -Eq '^(0|[1-9][0-9]{0,4})$' || return 2 ;;
        base_url) printf '%s' "$_val" | grep -Eq '^https?://[^ "]+$' || return 2 ;;
        model|provider) printf '%s' "$_val" | grep -Eq '^[A-Za-z0-9._:/@+-]+$' || return 2 ;;
        api_key) printf '%s' "$_val" | grep -Eq '^[^ "\\]+$' || return 2 ;;
    esac
    return 0
}

cfg_set() {
    cfg_validate "$1" "$2" || return $?
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
