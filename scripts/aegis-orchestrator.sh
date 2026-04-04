#!/bin/bash
# OSymbiote — AEGIS Deploy & Build Orchestrator
# Deploys build scripts to AEGIS, runs the build, monitors, fixes issues
# Run from Dragonfly.

set -euo pipefail

AEGIS_USER="u0_a473"
AEGIS_HOST="192.168.1.3"
AEGIS_PORT=8022
AEGIS_SSH="ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p $AEGIS_PORT ${AEGIS_USER}@${AEGIS_HOST}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()  { echo -e "${GREEN}[✓]${NC} $*"; }
err() { echo -e "${RED}[✗]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }

# ── Phase 0: Verify AEGIS connectivity ──
verify_aegis() {
    log "Checking AEGIS connectivity..."
    
    # Try SSH
    if $AEGIS_SSH "echo ALIVE" 2>/dev/null; then
        ok "AEGIS SSH connected"
        return 0
    fi
    
    err "AEGIS SSH failed. Trying ADB..."
    
    # Try ADB to start sshd
    local ADB_PORT=""
    # Scan for wireless debug port
    for port in $(seq 37000 37100) $(seq 42000 42100); do
        if timeout 1 bash -c "echo >/dev/tcp/$AEGIS_HOST/$port" 2>/dev/null; then
            ADB_PORT=$port
            break
        fi
    done
    
    if [ -n "$ADB_PORT" ]; then
        log "Found ADB at port $ADB_PORT"
        adb connect "$AEGIS_HOST:$ADB_PORT"
        adb shell "am startservice com.termux/.app.TermuxService" 2>/dev/null || true
        sleep 3
        # Retry SSH
        if $AEGIS_SSH "echo ALIVE" 2>/dev/null; then
            ok "AEGIS SSH connected after ADB wake"
            return 0
        fi
    fi
    
    err "Cannot reach AEGIS. Please open Termux on the phone."
    return 1
}

# ── Phase 1: Deploy build scripts ──
deploy() {
    log "Deploying OSymbiote build to AEGIS..."
    
    # Create dirs
    $AEGIS_SSH "mkdir -p ~/osymbiote/{build,images,rootfs}"
    
    # Copy build script
    scp -P $AEGIS_PORT \
        /home/adam/workspace/projects/symbiote-os/scripts/build-phase1.sh \
        "${AEGIS_USER}@${AEGIS_HOST}:~/osymbiote/build.sh"
    
    $AEGIS_SSH "chmod +x ~/osymbiote/build.sh"
    ok "Build scripts deployed"
}

# ── Phase 2: Run the build ──
build() {
    log "Starting Phase 1 build on AEGIS..."
    
    # Run build with output capture
    $AEGIS_SSH "cd ~/osymbiote && bash build.sh 2>&1 | tee build.log" &
    BUILD_PID=$!
    
    # Monitor
    local TIMEOUT=600  # 10 minutes max
    local ELAPSED=0
    
    while kill -0 $BUILD_PID 2>/dev/null && [ $ELAPSED -lt $TIMEOUT ]; do
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        
        # Get last line of build log
        local STATUS=$($AEGIS_SSH "tail -1 ~/osymbiote/build.log 2>/dev/null" || echo "...")
        log "Build progress ($ELAPSED/${TIMEOUT}s): $STATUS"
    done
    
    wait $BUILD_PID 2>/dev/null
    local RC=$?
    
    if [ $RC -eq 0 ]; then
        ok "Build completed successfully!"
    else
        err "Build failed (exit $RC). Checking logs..."
        $AEGIS_SSH "tail -30 ~/osymbiote/build.log"
        return 1
    fi
}

# ── Phase 3: Boot QEMU ──
boot() {
    log "Booting OSymbiote in QEMU on AEGIS..."
    
    # Start QEMU in background via tmux/screen
    $AEGIS_SSH "command -v tmux >/dev/null 2>&1 || pkg install -y tmux"
    
    # Kill any existing QEMU
    $AEGIS_SSH "pkill -f qemu-system 2>/dev/null || true"
    sleep 1
    
    # Start in tmux
    $AEGIS_SSH "tmux new-session -d -s osymbiote 'cd ~/osymbiote && bash boot.sh 2>&1 | tee boot.log'"
    
    ok "QEMU started in tmux session 'osymbiote'"
    log "Waiting for boot..."
    sleep 15
    
    # Check if QEMU is running
    if $AEGIS_SSH "pgrep -f qemu-system" >/dev/null 2>&1; then
        ok "QEMU process alive"
    else
        err "QEMU died. Checking boot log..."
        $AEGIS_SSH "cat ~/osymbiote/boot.log 2>/dev/null | tail -20"
        return 1
    fi
}

# ── Phase 4: Verify agent ──
verify_agent() {
    log "Verifying OSymbiote agent..."
    
    # The QEMU has port forwarding: host:18422 → guest:8422
    local RESPONSE=$($AEGIS_SSH "curl -s --connect-timeout 5 http://localhost:18422/" 2>/dev/null || echo "TIMEOUT")
    
    if echo "$RESPONSE" | grep -q "alive"; then
        ok "OSymbiote agent is ALIVE!"
        echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
        return 0
    else
        warn "Agent not responding yet. Boot log:"
        $AEGIS_SSH "tmux capture-pane -t osymbiote -p 2>/dev/null | tail -20"
        return 1
    fi
}

# ── Main ──
main() {
    echo "╔══════════════════════════════════════════╗"
    echo "║  OSymbiote — AEGIS Deploy Orchestrator   ║"
    echo "╚══════════════════════════════════════════╝"
    
    verify_aegis || exit 1
    deploy || exit 1
    build || exit 1
    boot || exit 1
    
    # Retry agent verification with backoff
    for i in 1 2 3 4 5; do
        if verify_agent; then
            echo ""
            echo "╔══════════════════════════════════════════╗"
            echo "║  🎉 OSymbiote PROOF OF LIFE: SUCCESS     ║"
            echo "║  Agent booted on AEGIS/QEMU x86_64       ║"
            echo "║  $(date)           ║"
            echo "╚══════════════════════════════════════════╝"
            exit 0
        fi
        log "Retry $i/5 in 10s..."
        sleep 10
    done
    
    err "Agent did not respond after 5 retries."
    exit 1
}

# Allow running individual phases
case "${1:-all}" in
    verify) verify_aegis ;;
    deploy) deploy ;;
    build)  build ;;
    boot)   boot ;;
    check)  verify_agent ;;
    all)    main ;;
    *)      echo "Usage: $0 {all|verify|deploy|build|boot|check}" ;;
esac
