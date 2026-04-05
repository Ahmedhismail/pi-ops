# Rules: Ops Scripts

## Shell Script Standards

- Always start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Quote all variable expansions: `"$var"` not `$var`
- Use `local` for function-scoped variables
- Prefer `$(command)` over backticks
- Use `[[ ]]` for conditionals where possible, `[ ]` for POSIX compat in bootstrap scripts
- Exit with meaningful error messages via a `die()` helper

## Prime CLI Integration

- Always use `--plain` flag for machine-readable output
- Always use `--output json` for parseable data and pipe through `jq`
- Use `--yes` / `-y` to skip interactive confirmation prompts
- Never hardcode pod IDs, GPU types, or prices -- always query dynamically
- Handle the case where `prime` is not installed or not authenticated

## Idempotency

- Check before creating (don't fail if resource already exists)
- Check before deleting (don't fail if resource already gone)
- Bootstrap scripts must be safe to run multiple times
- Use `command -v` to check if tools are installed before installing

## Error Handling

- Always check return codes of external commands
- Provide fallback parsing when JSON parsing fails (CLI output format may change)
- Set timeouts on polling loops -- never poll forever
- Log clearly what's happening at each step

## Testing

- Syntax check scripts with `bash -n <script>` before committing
- Test flag parsing locally even without prime auth
