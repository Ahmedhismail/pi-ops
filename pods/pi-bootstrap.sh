#!/usr/bin/env bash
# pi-bootstrap.sh — Runs ON the pod after SCP. Idempotent.
set -euo pipefail

# These are passed as environment variables by pi-up.sh
REPO_URL="${PI_REPO_URL:-}"
REPO_BRANCH="${PI_REPO_BRANCH:-main}"
SETUP_CMD="${PI_SETUP_CMD:-bash setup.sh}"
REPO_DIR="/root/workspace"

echo "============================================"
echo "  pi-bootstrap: setting up pod"
echo "============================================"

# ── 1. Install Claude Code ──────────────────────────────────────────────────
if command -v claude &>/dev/null; then
    echo "[OK] Claude Code already installed"
else
    echo "[..] Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | sh
    # Add to PATH for this session if not already there
    export PATH="$HOME/.claude/bin:$PATH"
    echo "[OK] Claude Code installed"
fi

# ── 2. Clone or update repo ────────────────────────────────────────────────
if [ -z "$REPO_URL" ]; then
    echo "[SKIP] No PI_REPO_URL set — skipping clone"
else
    if [ -d "$REPO_DIR/.git" ]; then
        echo "[..] Repo exists, pulling latest..."
        cd "$REPO_DIR"
        git fetch origin
        git checkout "$REPO_BRANCH"
        git pull origin "$REPO_BRANCH"
        echo "[OK] Repo updated"
    else
        echo "[..] Cloning $REPO_URL (branch: $REPO_BRANCH)..."
        git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
        echo "[OK] Repo cloned"
    fi

    # ── 3. Copy .env if it was uploaded ─────────────────────────────────────
    if [ -f "/root/.pi-env-upload" ]; then
        cp /root/.pi-env-upload "$REPO_DIR/.env"
        rm /root/.pi-env-upload
        echo "[OK] .env copied into repo"
    fi

    # ── 4. Run setup command ────────────────────────────────────────────────
    echo "[..] Running setup: $SETUP_CMD"
    cd "$REPO_DIR"
    eval "$SETUP_CMD"
    echo "[OK] Setup complete"
fi

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "  Repo: $REPO_DIR"
echo "  Branch: $REPO_BRANCH"
echo "============================================"
