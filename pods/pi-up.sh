#!/usr/bin/env bash
# pi-up.sh — Prime Intellect pod lifecycle management
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Resolve script directory (for finding bootstrap script) ─────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load config (defaults, then ~/.pi-config.env, then ./pi-config.env) ────
PI_DEFAULT_GPU="${PI_DEFAULT_GPU:-H100_80GB}"
PI_DEFAULT_GPU_COUNT="${PI_DEFAULT_GPU_COUNT:-1}"
PI_DEFAULT_DISK_SIZE="${PI_DEFAULT_DISK_SIZE:-200}"
PI_IMAGE="${PI_IMAGE:-}"
PI_REPO_URL="${PI_REPO_URL:-}"
PI_REPO_BRANCH="${PI_REPO_BRANCH:-main}"
PI_SETUP_CMD="${PI_SETUP_CMD:-bash setup.sh}"
PI_ENV_FILE="${PI_ENV_FILE:-.env}"
PI_SESSION_FILE="${PI_SESSION_FILE:-$HOME/.pi-session}"
PI_BOOTSTRAP_SCRIPT="${PI_BOOTSTRAP_SCRIPT:-pods/pi-bootstrap.sh}"

# shellcheck disable=SC1090
[ -f "$HOME/.pi-config.env" ] && source "$HOME/.pi-config.env"
# shellcheck disable=SC1091
[ -f "./pi-config.env" ] && source "./pi-config.env"

# Expand tilde in session file path
PI_SESSION_FILE="${PI_SESSION_FILE/#\~/$HOME}"

# ── Helpers ─────────────────────────────────────────────────────────────────
require_prime() {
    command -v prime &>/dev/null || die "prime CLI not found. Install with: uv tool install prime"
}

get_active_pod() {
    if [ -f "$PI_SESSION_FILE" ]; then
        cat "$PI_SESSION_FILE"
    else
        echo ""
    fi
}

set_active_pod() {
    echo "$1" > "$PI_SESSION_FILE"
}

clear_active_pod() {
    rm -f "$PI_SESSION_FILE"
}

require_active_pod() {
    local pod_id
    pod_id="$(get_active_pod)"
    if [ -z "$pod_id" ]; then
        die "No active pod. Run: pi-up.sh up"
    fi
    echo "$pod_id"
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_up() {
    require_prime

    local name=""
    local gpu="$PI_DEFAULT_GPU"
    local gpu_count="$PI_DEFAULT_GPU_COUNT"
    local disk_size="$PI_DEFAULT_DISK_SIZE"

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)  name="$2"; shift 2 ;;
            --gpu)   gpu="$2"; shift 2 ;;
            --count) gpu_count="$2"; shift 2 ;;
            --disk)  disk_size="$2"; shift 2 ;;
            *)       die "Unknown flag: $1" ;;
        esac
    done

    # Check if we already have an active pod
    local existing
    existing="$(get_active_pod)"
    if [ -n "$existing" ]; then
        warn "Active pod found: $existing"
        # Verify it's still running
        local status
        status=$(prime pods status "$existing" --output json --plain 2>/dev/null | jq -r '.status // "unknown"') || status="unknown"
        if [ "$status" = "running" ]; then
            ok "Pod $existing is already running. Use 'pi-up.sh ssh' to connect."
            return 0
        else
            warn "Pod $existing status is '$status'. Clearing session and creating new pod."
            clear_active_pod
        fi
    fi

    # ── Check availability ──────────────────────────────────────────────────
    info "Checking availability for $gpu (x$gpu_count)..."
    local avail
    avail=$(prime availability list --gpu-type "$gpu" --gpu-count "$gpu_count" --output json --plain 2>&1) || true

    local avail_count
    avail_count=$(echo "$avail" | jq -r '.total_count // 0' 2>/dev/null) || avail_count=0

    if [ "$avail_count" -eq 0 ]; then
        die "No $gpu (x$gpu_count) available right now. Try a different GPU type or check later."
    fi

    # Pick the first available resource ID
    local resource_id
    resource_id=$(echo "$avail" | jq -r '.gpu_resources[0].id')
    local price
    price=$(echo "$avail" | jq -r '.gpu_resources[0].price_per_hour // "unknown"')
    ok "Found $avail_count option(s). Using resource: $resource_id (\$$price/hr)"

    # ── Create pod ──────────────────────────────────────────────────────────
    info "Creating pod..."
    local create_args=(
        --id "$resource_id"
        --gpu-type "$gpu"
        --gpu-count "$gpu_count"
        --disk-size "$disk_size"
        --yes
        --plain
    )
    [ -n "$name" ] && create_args+=(--name "$name")
    [ -n "$PI_IMAGE" ] && create_args+=(--image "$PI_IMAGE")

    local create_output
    create_output=$(prime pods create "${create_args[@]}" 2>&1)

    # Extract pod ID from create output — try JSON first, then plain text
    local pod_id=""
    pod_id=$(echo "$create_output" | jq -r '.id // empty' 2>/dev/null) || true

    if [ -z "$pod_id" ]; then
        # Fallback: look for a UUID pattern in the output
        pod_id=$(echo "$create_output" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1) || true
    fi

    if [ -z "$pod_id" ]; then
        err "Could not extract pod ID from create output:"
        echo "$create_output"
        die "Pod creation may have failed."
    fi

    set_active_pod "$pod_id"
    ok "Pod created: $pod_id"

    # ── Poll until running ──────────────────────────────────────────────────
    info "Waiting for pod to start..."
    local timeout=300  # 5 minutes
    local elapsed=0
    local poll_interval=5
    local pod_status=""

    while [ "$elapsed" -lt "$timeout" ]; do
        pod_status=$(prime pods status "$pod_id" --output json --plain 2>/dev/null | jq -r '.status // "unknown"') || pod_status="unknown"

        if [ "$pod_status" = "running" ]; then
            break
        fi

        echo -e "  ${YELLOW}Status: $pod_status (${elapsed}s / ${timeout}s)${NC}"
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    if [ "$pod_status" != "running" ]; then
        die "Pod did not reach 'running' state within ${timeout}s (last status: $pod_status)"
    fi

    ok "Pod is running!"

    # ── Get SSH info ────────────────────────────────────────────────────────
    local pod_info
    pod_info=$(prime pods status "$pod_id" --output json --plain 2>/dev/null)
    local ssh_host
    ssh_host=$(echo "$pod_info" | jq -r '.ssh.host // .ip // "unknown"')
    local ssh_port
    ssh_port=$(echo "$pod_info" | jq -r '.ssh.port // 22')
    local ssh_user
    ssh_user=$(echo "$pod_info" | jq -r '.ssh.user // "root"')

    info "SSH: ${ssh_user}@${ssh_host} -p ${ssh_port}"

    # ── Bootstrap ───────────────────────────────────────────────────────────
    local bootstrap_path="$SCRIPT_DIR/pi-bootstrap.sh"
    if [ ! -f "$bootstrap_path" ]; then
        warn "Bootstrap script not found at $bootstrap_path — skipping bootstrap"
        return 0
    fi

    info "Uploading bootstrap script..."

    # Wait a bit for SSH to become ready
    local ssh_ready=false
    for i in $(seq 1 12); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p "$ssh_port" "${ssh_user}@${ssh_host}" "echo ok" &>/dev/null; then
            ssh_ready=true
            break
        fi
        echo -e "  ${YELLOW}Waiting for SSH... (attempt $i/12)${NC}"
        sleep 5
    done

    if [ "$ssh_ready" != "true" ]; then
        warn "SSH not ready after 60s. Pod is running but bootstrap was skipped."
        warn "Connect manually: prime pods ssh $pod_id"
        return 0
    fi

    # SCP bootstrap script
    scp -o StrictHostKeyChecking=no -P "$ssh_port" "$bootstrap_path" "${ssh_user}@${ssh_host}:/root/pi-bootstrap.sh"

    # SCP .env file if it exists
    if [ -n "$PI_ENV_FILE" ] && [ -f "$PI_ENV_FILE" ]; then
        info "Uploading .env file..."
        scp -o StrictHostKeyChecking=no -P "$ssh_port" "$PI_ENV_FILE" "${ssh_user}@${ssh_host}:/root/.pi-env-upload"
    fi

    # Run bootstrap
    info "Running bootstrap on pod..."
    ssh -o StrictHostKeyChecking=no -p "$ssh_port" "${ssh_user}@${ssh_host}" \
        "PI_REPO_URL='$PI_REPO_URL' PI_REPO_BRANCH='$PI_REPO_BRANCH' PI_SETUP_CMD='$PI_SETUP_CMD' bash /root/pi-bootstrap.sh"

    echo ""
    ok "Pod is ready!"
    echo -e "  ${BOLD}SSH:${NC}  pi-up.sh ssh  ${BLUE}(or: prime pods ssh $pod_id)${NC}"
    echo -e "  ${BOLD}Stop:${NC} pi-up.sh down"
}

cmd_ssh() {
    require_prime
    local pod_id
    pod_id="$(require_active_pod)"
    info "Connecting to pod $pod_id..."
    exec prime pods ssh "$pod_id"
}

cmd_down() {
    require_prime
    local pod_id
    pod_id="$(require_active_pod)"
    info "Terminating pod $pod_id..."
    prime pods terminate "$pod_id" --yes --plain
    clear_active_pod
    ok "Pod terminated and session cleared."
}

cmd_status() {
    require_prime
    local pod_id
    pod_id="$(get_active_pod)"
    if [ -z "$pod_id" ]; then
        warn "No active pod session."
        return 0
    fi

    info "Active pod: $pod_id"
    prime pods status "$pod_id" --plain
}

cmd_list() {
    require_prime
    info "All pods:"
    prime pods list --plain
    echo ""
    local active
    active="$(get_active_pod)"
    if [ -n "$active" ]; then
        info "Active session: $active"
    else
        info "No active session."
    fi
}

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}pi-up.sh${NC} — Prime Intellect pod lifecycle management

${BOLD}Usage:${NC}
  pi-up.sh up [--name NAME] [--gpu TYPE] [--count N] [--disk GB]
  pi-up.sh ssh
  pi-up.sh down
  pi-up.sh status
  pi-up.sh list

${BOLD}Commands:${NC}
  up       Create a pod, wait until running, bootstrap it
  ssh      SSH into the active pod
  down     Terminate the active pod
  status   Show active pod status
  list     List all pods

${BOLD}Config:${NC}
  Loaded from ~/.pi-config.env then ./pi-config.env
  See pods/pi-config.example.env for available options.

${BOLD}Examples:${NC}
  pi-up.sh up                          # Use defaults from config
  pi-up.sh up --gpu H100_80GB --name my-pod
  pi-up.sh ssh                         # Connect to active pod
  pi-up.sh down                        # Terminate active pod
EOF
}

# ── Main dispatch ───────────────────────────────────────────────────────────
case "${1:-}" in
    up)      shift; cmd_up "$@" ;;
    ssh)     cmd_ssh ;;
    down)    cmd_down ;;
    status)  cmd_status ;;
    list)    cmd_list ;;
    -h|--help|help|"")  usage ;;
    *)       die "Unknown command: $1. Run 'pi-up.sh --help' for usage." ;;
esac
