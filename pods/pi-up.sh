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
PI_DEFAULT_GPU="${PI_DEFAULT_GPU:-A100_80GB}"
PI_DEFAULT_GPU_COUNT="${PI_DEFAULT_GPU_COUNT:-1}"
PI_DEFAULT_DISK_SIZE="${PI_DEFAULT_DISK_SIZE:-200}"
PI_IMAGE="${PI_IMAGE:-ubuntu_22_cuda_12}"
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

is_running() {
    local s
    s=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$s" == "running" || "$s" == "active" ]]
}

# Returns known GPU type slugs from prime, one per line. Empty if unavailable.
get_gpu_types() {
    prime availability gpu-types --output json --plain 2>/dev/null \
        | jq -r '.gpu_types[]? // .[]?' 2>/dev/null \
        || true
}

# ── Commands ────────────────────────────────────────────────────────────────

cmd_up() {
    require_prime

    local name=""
    local gpu="$PI_DEFAULT_GPU"
    local gpu_count="$PI_DEFAULT_GPU_COUNT"
    local disk_size="$PI_DEFAULT_DISK_SIZE"
    local allow_spot=false

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)       name="$2"; shift 2 ;;
            --gpu)        gpu="$2"; shift 2 ;;
            --count)      gpu_count="$2"; shift 2 ;;
            --disk)       disk_size="$2"; shift 2 ;;
            --allow-spot) allow_spot=true; shift ;;
            *)            die "Unknown flag: $1" ;;
        esac
    done

    # ── Single-instance guard ────────────────────────────────────────────────
    # Only one pod allowed at a time to prevent runaway costs.
    # TODO: revisit — allow multiple pods with a budget cap or confirmation prompt.
    local existing
    existing="$(get_active_pod)"
    if [ -n "$existing" ]; then
        local status
        status=$(prime pods status "$existing" --output json --plain 2>/dev/null | jq -r '.status // "unknown"') || status="unknown"
        if is_running "$status"; then
            die "Pod $existing is already running. Only one pod allowed at a time.
  Use 'pi-up.sh ssh' to connect, or 'pi-up.sh down' to terminate it first."
        else
            warn "Stale session found (pod $existing, status: $status). Clearing."
            clear_active_pod
        fi
    fi

    # ── Resolve GPU slug ────────────────────────────────────────────────────
    # Query the live GPU type list and fuzzy-match if the user passed a short
    # name (e.g. "H200" instead of "H200_96GB"). Pre-populates avail/avail_count
    # when we already did availability checks during multi-candidate resolution.
    local all_gpu_types avail="" avail_count=""
    all_gpu_types=$(get_gpu_types)

    if [ -n "$all_gpu_types" ] && ! echo "$all_gpu_types" | grep -qx "$gpu"; then
        local candidates
        candidates=$(echo "$all_gpu_types" | grep -i "$gpu" || true)

        if [ -z "$candidates" ]; then
            err "Unknown GPU type: '$gpu'"
            err "Known types:"
            echo "$all_gpu_types" | sed 's/^/  /' >&2
            die "Pass one of the above to --gpu."
        fi

        local candidate_count
        candidate_count=$(echo "$candidates" | wc -l | tr -d ' ')

        if [ "$candidate_count" -eq 1 ]; then
            gpu=$(echo "$candidates" | tr -d '[:space:]')
            info "Resolved --gpu to: $gpu"
        else
            # Multiple matches — check availability across each, take first with stock
            info "Multiple matches for '$gpu': $(echo "$candidates" | tr '\n' ' ')"
            info "Checking availability across candidates..."
            local found_gpu=""
            while IFS= read -r candidate; do
                local c_avail c_count
                c_avail=$(prime availability list --gpu-type "$candidate" --gpu-count "$gpu_count" \
                    --output json --plain 2>/dev/null) || continue
                c_count=$(echo "$c_avail" | jq -r '.total_count // 0' 2>/dev/null) || continue
                if [ "${c_count:-0}" -gt 0 ]; then
                    found_gpu="$candidate"
                    avail="$c_avail"
                    avail_count="$c_count"
                    break
                fi
            done <<< "$candidates"

            if [ -z "$found_gpu" ]; then
                err "No availability for any match of '$gpu':"
                echo "$candidates" | sed 's/^/  /' >&2
                die "Try a different GPU type or check later."
            fi
            gpu="$found_gpu"
            info "Using: $gpu"
        fi
    fi

    # ── Check availability ──────────────────────────────────────────────────
    info "Checking availability for $gpu (x$gpu_count)..."
    if [ -z "$avail" ]; then
        avail=$(prime availability list --gpu-type "$gpu" --gpu-count "$gpu_count" --output json --plain 2>&1) || true
        avail_count=$(echo "$avail" | jq -r '.total_count // 0' 2>/dev/null) || avail_count=0
    fi

    if [ "${avail_count:-0}" -eq 0 ]; then
        err "No $gpu (x$gpu_count) available right now."
        if [ -n "$all_gpu_types" ]; then
            err "Known GPU types (for reference):"
            echo "$all_gpu_types" | sed 's/^/  /' >&2
        fi
        die "Try a different GPU type or check later."
    fi

    # ── Filter spot vs on-demand ────────────────────────────────────────────
    local filtered_resources
    if [ "$allow_spot" = "true" ]; then
        filtered_resources=$(echo "$avail" | jq -c '[.gpu_resources[]]')
    else
        filtered_resources=$(echo "$avail" | jq -c '[.gpu_resources[] | select(.is_spot != true)]')
    fi

    local filtered_count
    filtered_count=$(echo "$filtered_resources" | jq 'length')

    if [ "${filtered_count:-0}" -eq 0 ]; then
        if [ "$allow_spot" = "false" ]; then
            warn "No on-demand $gpu (x$gpu_count) available. Re-run with --allow-spot to include spot instances."
        fi
        die "No usable resources available right now."
    fi

    local resource_id is_spot price spot_label
    resource_id=$(echo "$filtered_resources" | jq -r '.[0].id')
    is_spot=$(echo "$filtered_resources" | jq -r '.[0].is_spot // false')
    price=$(echo "$filtered_resources" | jq -r '.[0].price_per_hour // "unknown"')
    spot_label="[ON-DEMAND]"
    [ "$is_spot" = "true" ] && spot_label="[SPOT]"
    ok "Found $filtered_count option(s). Using resource: $resource_id $spot_label (\$$price/hr)"

    # ── Create pod ──────────────────────────────────────────────────────────
    # Pull vcpus/memory from the selected resource so prime doesn't prompt interactively.
    local vcpus memory
    vcpus=$(echo "$filtered_resources" | jq -r '.[0].vcpus // .[0].cpu_count // empty')
    memory=$(echo "$filtered_resources" | jq -r '.[0].memory // .[0].ram // empty')

    info "Creating pod..."
    local create_args=(
        --id "$resource_id"
        --gpu-type "$gpu"
        --gpu-count "$gpu_count"
        --disk-size "$disk_size"
        --yes
        --plain
    )
    [ -n "$vcpus" ]  && create_args+=(--vcpus "$vcpus")
    [ -n "$memory" ] && create_args+=(--memory "$memory")
    [ -n "$name" ]   && create_args+=(--name "$name")
    [ -n "$PI_IMAGE" ] && create_args+=(--image "$PI_IMAGE")

    local create_output
    create_output=$(prime pods create "${create_args[@]}" 2>&1)

    # Extract pod ID from create output — try JSON, then dashed UUID, then 32-char hex,
    # then fall back to querying the pod list for the newest entry.
    local pod_id=""
    pod_id=$(echo "$create_output" | jq -r '.id // empty' 2>/dev/null) || true

    if [ -z "$pod_id" ]; then
        pod_id=$(echo "$create_output" \
            | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
            | head -1) || true
    fi

    if [ -z "$pod_id" ]; then
        pod_id=$(echo "$create_output" | grep -oE '\b[0-9a-f]{32}\b' | head -1) || true
    fi

    if [ -z "$pod_id" ]; then
        warn "Could not parse ID from create output; querying pod list..."
        pod_id=$(prime pods list --output json --plain 2>/dev/null \
            | jq -r '.pods | sort_by(.created_at) | last | .id // empty') || true
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

        if is_running "$pod_status"; then
            break
        fi

        echo -e "  ${YELLOW}Status: $pod_status (${elapsed}s / ${timeout}s)${NC}"
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    if ! is_running "$pod_status"; then
        die "Pod did not reach running state within ${timeout}s (last status: $pod_status)"
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

    # Derive remote home dir from the SSH user (root vs ubuntu/etc.)
    local remote_home
    if [ "$ssh_user" = "root" ]; then
        remote_home="/root"
    else
        remote_home="/home/$ssh_user"
    fi

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
    scp -o StrictHostKeyChecking=no -P "$ssh_port" "$bootstrap_path" "${ssh_user}@${ssh_host}:${remote_home}/pi-bootstrap.sh"

    # SCP .env file if it exists
    if [ -n "$PI_ENV_FILE" ] && [ -f "$PI_ENV_FILE" ]; then
        info "Uploading .env file..."
        scp -o StrictHostKeyChecking=no -P "$ssh_port" "$PI_ENV_FILE" "${ssh_user}@${ssh_host}:${remote_home}/.pi-env-upload"
    fi

    # Run bootstrap
    info "Running bootstrap on pod..."
    ssh -o StrictHostKeyChecking=no -p "$ssh_port" "${ssh_user}@${ssh_host}" \
        "PI_REPO_URL='$PI_REPO_URL' PI_REPO_BRANCH='$PI_REPO_BRANCH' PI_SETUP_CMD='$PI_SETUP_CMD' bash ${remote_home}/pi-bootstrap.sh"

    echo ""
    ok "Pod is ready!"
    echo -e "  ${BOLD}SSH:${NC}  pi-up.sh ssh  ${BLUE}(or: prime pods ssh $pod_id)${NC}"
    echo -e "  ${BOLD}Stop:${NC} pi-up.sh down"

    # ── Update POD_SSH_HOST in project .env ─────────────────────────────────
    # Keep cron/monitoring scripts pointed at the new pod automatically.
    local env_file="${PI_ENV_FILE:-.env}"
    if [ -f "$env_file" ]; then
        local pod_ssh="${ssh_user}@${ssh_host}"
        if grep -q '^POD_SSH_HOST=' "$env_file"; then
            sed -i.bak "s|^POD_SSH_HOST=.*|POD_SSH_HOST=$pod_ssh|" "$env_file"
            ok "Updated POD_SSH_HOST=$pod_ssh in $env_file"
        else
            echo "POD_SSH_HOST=$pod_ssh" >> "$env_file"
            ok "Appended POD_SSH_HOST=$pod_ssh to $env_file"
        fi
    fi
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

    # TODO: safe teardown — before terminating, verify:
    #   1. rsync/scp results back to local machine
    #   2. confirm git push completed (check for unpushed commits)
    #   3. prompt user: "Data synced? Terminate? [y/N]"
    # For now, we just terminate with a warning.

    warn "Make sure you've pulled any results/data from the pod before terminating."
    echo -n "  Terminate pod $pod_id? [y/N] "
    read -r confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        info "Aborted."
        return 0
    fi

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
  pi-up.sh up [--name NAME] [--gpu TYPE] [--count N] [--disk GB] [--allow-spot]
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
  pi-up.sh up --gpu H200 --allow-spot  # Include spot instances
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
