# pi-ops

Ops toolkit for GPU pod management and agent infrastructure. Provider-agnostic design, currently targeting Prime Intellect.

## Structure

```
pods/           Prime Intellect pod lifecycle scripts
  pi-up.sh      Main CLI: up, ssh, down, status, list
  pi-bootstrap.sh  Runs on the pod after creation (SCP'd over)
  pi-config.example.env  Template configuration
rules/          Workflow-specific instructions
```

## Pod Management

Uses the `prime` CLI (`uv tool install prime`).

```bash
pods/pi-up.sh up                    # create and bootstrap a pod
pods/pi-up.sh up --gpu H100_80GB    # specify GPU type
pods/pi-up.sh ssh                   # connect to active pod
pods/pi-up.sh status                # show active pod info
pods/pi-up.sh down                  # terminate active pod
pods/pi-up.sh list                  # list all pods
```

Config is loaded from `~/.pi-config.env` (user-level), then `./pi-config.env` (project-level). See `pods/pi-config.example.env` for all options.

## Context Loading

- **Ops work** (writing/modifying shell scripts, debugging pod issues): read `rules/ops.md`

## Conventions

- Shell scripts use `set -euo pipefail`
- No silent failures -- every command's exit code matters
- Scripts must be idempotent (safe to run multiple times)
- Parse CLI output defensively -- `prime` output formats may change between versions
- Use `--plain` and `--output json` flags when calling `prime` from scripts
- Color output: green = success, yellow = waiting, red = error
