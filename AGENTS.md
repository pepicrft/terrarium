# AGENTS.md

## Workflow

- After every change, create a git commit and push it to the current branch.

## Testing

- Never modify global state in tests (e.g. `Application.put_env`, `Application.delete_env`). All tests must be safe to run with `async: true`.
- For running bash commands from Elixir, use `MuonTrap` instead of `System`. Prefer `MuonTrap` because it propagates process shutdowns to child processes. Reference: https://hexdocs.pm/muontrap/readme.html
