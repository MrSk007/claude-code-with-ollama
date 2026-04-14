# CLAUDE.md — Project Conventions

## Project

Cross-platform setup toolkit for running Claude Code with Ollama's native Anthropic-compatible API. Two scripts: `setup.sh` (macOS/Linux) and `setup.ps1` (Windows). Supports both local models (auto-detected by RAM) and cloud models (run on Ollama's servers via `ollama launch claude`).

## Script Architecture

Both scripts use a **function-based dispatcher pattern**. All logic lives in named functions; `main()` parses args and dispatches.

## Coding Conventions

### Bash (`setup.sh`)
- Function naming: `snake_case` (e.g., `check_prerequisites`)
- Constants: `UPPER_SNAKE` (e.g., `MIN_NODE_VERSION`)
- Locals: `lower_snake` (e.g., `detected_ram`)
- Output prefixes: `[INFO]`, `[WARN]`, `[ERROR]` with ANSI colors
- Error handling: `set -eu -o pipefail` + `trap cleanup EXIT`
- Always double-quote variables: `"$model"`

### PowerShell (`setup.ps1`)
- Function naming: `Verb-Noun` PascalCase (e.g., `Test-Prerequisites`)
- Variables: `$PascalCase` (e.g., `$DetectedRam`)
- Output: `Write-Host` with `-ForegroundColor`
- Error handling: `$ErrorActionPreference = 'Stop'` + `try/catch/finally`
- Use `${VarName}` (braces) when followed by `?` or other characters that PS7+ treats as part of the variable name

## Key Data Locations

- **Model recommendation table**: `$Script:MODEL_TABLE` / `MODEL_TABLE` at the TOP of each script
- **Cloud model table**: `$Script:CLOUD_MODELS` / `CLOUD_MODELS` at the TOP of each script
- **Sentinel markers**: `# >>> claude-code-ollama >>>` / `# <<< claude-code-ollama <<<`
- **Environment variables**: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `OLLAMA_NUM_CTX`, `CLAUDE_CODE_GIT_BASH_PATH` (Windows only)

## Cloud Model Support

- Cloud models have `:cloud` suffix (e.g., `kimi-k2.5:cloud`) and run on Ollama's servers
- Cloud models skip local pull and Phase 1 warm-up during verification
- Cloud models require `ollama signin` (handled automatically by scripts)
- Quick launch: `ollama launch claude --model <name>:cloud`

## Security Rules

- NEVER use `--dangerously-skip-permissions` anywhere
- NEVER use pipe-to-shell (`curl | sh`, `irm | iex`)
- Always validate model name input: `^[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+$`
- Always quote shell variables
- Back up shell profiles before modification

## Windows-Specific Notes

- Claude Code requires Git Bash — scripts auto-detect and set `CLAUDE_CODE_GIT_BASH_PATH`
- `claude` is a `.ps1` wrapper, not an `.exe` — must run through `powershell.exe` in `Start-Process`
- Ollama installer uses `/VERYSILENT` + `WaitForExit(120000)` via `-PassThru` (not `-Wait`, which blocks on tray app child processes)
- Set `$ProgressPreference = 'SilentlyContinue'` before `Invoke-WebRequest` to avoid slow downloads
- Installer cleanup uses `-ErrorAction SilentlyContinue` (exe may be locked by spawned tray app)

## Testing

Run `./setup.sh --verify` or `.\setup.ps1 -Verify` to test the pipeline without reinstalling.
