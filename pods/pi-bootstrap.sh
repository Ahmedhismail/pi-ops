#!/usr/bin/env bash
# pi-bootstrap.sh — Runs ON the pod after SCP. Idempotent.
set -euo pipefail

# These are passed as environment variables by pi-up.sh
REPO_URL="${PI_REPO_URL:-}"
REPO_BRANCH="${PI_REPO_BRANCH:-main}"
SETUP_CMD="${PI_SETUP_CMD:-bash setup.sh}"
REPO_DIR="$HOME/workspace"

echo "============================================"
echo "  pi-bootstrap: setting up pod"
echo "============================================"

# ── 1. Source uploaded .env (needed for GIT_PAT before clone) ─────────────
# Use Python to parse the .env so KEY = VALUE (python-dotenv format) works.
if [ -f "$HOME/.pi-env-upload" ]; then
    echo "[..] Loading secrets from uploaded .env..."
    eval "$(python3 -c "
try:
    from dotenv import dotenv_values
    loader = dotenv_values
except ImportError:
    # Fallback: simple parser that strips spaces around = and quotes
    def loader(path):
        d = {}
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                d[k.strip()] = v.strip().strip('\"').strip(\"'\")
        return d
for k, v in loader('$HOME/.pi-env-upload').items():
    v = (v or '').replace(\"'\", \"'\\\\''\" )
    print(f\"export {k}='{v}'\")
")"
    echo "[OK] Secrets loaded"
fi

# ── 2. Install Claude Code ──────────────────────────────────────────────────
if command -v claude &>/dev/null; then
    echo "[OK] Claude Code already installed"
else
    echo "[..] Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | sh
    export PATH="$HOME/.claude/bin:$PATH"
    echo "[OK] Claude Code installed"
fi

# ── 3. Configure git credentials ──────────────────────────────────────────
GIT_PAT="${GIT_PAT:-}"
if [ -n "$GIT_PAT" ]; then
    echo "[..] Configuring git credentials..."
    git config --global credential.helper store
    echo "https://${GIT_PAT}@github.com" > ~/.git-credentials
    chmod 600 ~/.git-credentials
    echo "[OK] Git PAT configured"
else
    echo "[WARN] No GIT_PAT set — git clone will only work for public repos"
fi

# ── 4. Clone or update repo ────────────────────────────────────────────────
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

    # ── 5. Copy .env into repo ────────────────────────────────────────────
    if [ -f "$HOME/.pi-env-upload" ]; then
        cp "$HOME/.pi-env-upload" "$REPO_DIR/.env"
        rm "$HOME/.pi-env-upload"
        echo "[OK] .env copied into repo"
    fi

    # ── 6. Run setup command ────────────────────────────────────────────────
    echo "[..] Running setup: $SETUP_CMD"
    cd "$REPO_DIR"
    # Fix .config ownership if root owns it (some provider images ship this way)
    sudo chown -R "$USER:$USER" "$HOME/.config" 2>/dev/null || true
    # Prevent uv from writing fish/shell configs (avoids permission errors)
    export UV_NO_MODIFY_PATH=1
    eval "$SETUP_CMD"
    echo "[OK] Setup complete"
fi

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo "  Repo: $REPO_DIR"
echo "  Branch: $REPO_BRANCH"
echo "============================================"
