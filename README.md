# pi-ops

GPU pod management toolkit. Currently supports Prime Intellect, designed to be provider-extensible.

## Quick Start

### 1. Install the Prime CLI

```bash
uv tool install prime
prime login
```

### 2. Configure

```bash
cp pods/pi-config.example.env ~/.pi-config.env
# Edit ~/.pi-config.env with your repo URL, GPU preferences, etc.
```

### 3. Launch a pod

```bash
# Create a pod with defaults from config
pods/pi-up.sh up

# Or specify options
pods/pi-up.sh up --gpu H100_80GB --name my-experiment

# Connect
pods/pi-up.sh ssh

# When done
pods/pi-up.sh down
```

## Commands

| Command | Description |
|---------|-------------|
| `pi-up.sh up [--name N] [--gpu T] [--count N] [--disk GB]` | Create pod, wait until running, bootstrap |
| `pi-up.sh ssh` | SSH into the active pod |
| `pi-up.sh down` | Terminate the active pod |
| `pi-up.sh status` | Show active pod details |
| `pi-up.sh list` | List all pods |

## What `up` does

1. Checks GPU availability via `prime availability list`
2. Creates a pod via `prime pods create`
3. Polls until the pod status is `running` (timeout: 5 min)
4. Waits for SSH to become reachable
5. SCPs the bootstrap script (and `.env` if configured) to the pod
6. Runs the bootstrap script, which:
   - Installs Claude Code
   - Clones your repo (or pulls if it already exists)
   - Runs your setup command (e.g., `bash setup.sh`)

## Configuration

Config is loaded in order (later values override):
1. `~/.pi-config.env` (user-level defaults)
2. `./pi-config.env` (project-level overrides)

See `pods/pi-config.example.env` for all available options.
