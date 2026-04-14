# Claude Code + Ollama Setup Toolkit

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using local or cloud models via [Ollama](https://ollama.com).

One script. Zero cost. Local or cloud models. Full agentic coding workflow.

## Quick Start

### macOS / Linux

```bash
git clone https://github.com/YOUR_USERNAME/claude-code-ollama.git
cd claude-code-ollama
chmod +x setup.sh
./setup.sh
```

### Windows (PowerShell)

```powershell
git clone https://github.com/YOUR_USERNAME/claude-code-ollama.git
cd claude-code-ollama
.\setup.ps1
```

## Prerequisites

- **Node.js 18+** — [nodejs.org](https://nodejs.org)
- **Git Bash** (Windows only) — [git-scm.com](https://git-scm.com/downloads/win)
- **8 GB+ RAM** (16 GB+ recommended for local models; cloud models have no RAM requirement)
- **Internet connection** for initial setup (downloading Ollama + model)

## What the Scripts Do

1. Install Ollama (if not present)
2. Detect your hardware (RAM) and recommend the best local coding model
3. Offer cloud models as an alternative (no download, runs on Ollama's servers)
4. Pull the selected model (or sign in to Ollama for cloud models)
5. Install Claude Code via npm
6. Configure environment variables
7. Verify everything works end-to-end

## Flags

| Flag | Bash | PowerShell | Description |
|------|------|------------|-------------|
| Install (default) | `./setup.sh` | `.\setup.ps1` | Full guided setup |
| Silent mode | `./setup.sh --silent` | `.\setup.ps1 -Silent` | Non-interactive, uses defaults |
| Verify only | `./setup.sh --verify` | `.\setup.ps1 -Verify` | Health check only |
| Help | `./setup.sh --help` | `.\setup.ps1 -Help` | Usage info |

## Model Recommendations

| Your RAM | Model | Download Size | Context Window |
|----------|-------|---------------|----------------|
| < 8 GB | `qwen2.5-coder:3b` | ~2 GB | 8K |
| 8-12 GB | `qwen2.5-coder:7b` | ~4.5 GB | 16K |
| 12-16 GB | `qwen2.5-coder:14b` | ~9 GB | 32K |
| 16-32 GB | `deepseek-coder-v2:16b` | ~10 GB | 48K |
| 32 GB+ | `qwen2.5-coder:32b` | ~20 GB | 64K |

The scripts auto-detect your RAM and recommend the best local model. You can override the selection during interactive setup.

## Cloud Models

During setup, type `cloud` at the model prompt to use models hosted on Ollama's servers instead of running locally. Cloud models require no download and run at full context length.

| Model | Description |
|-------|-------------|
| `kimi-k2.5:cloud` | Kimi K2.5 — fast cloud model |
| `glm-5:cloud` | GLM 5 — strong general reasoning |
| `minimax-m2.7:cloud` | MiniMax M2.7 — balanced cloud model |
| `qwen3.5:cloud` | Qwen 3.5 — versatile cloud coding model |

Cloud models require signing in with `ollama signin` (the setup script handles this automatically). Ollama offers a free tier with usage limits; see [ollama.com](https://ollama.com) for pricing.

You can also launch Claude Code directly via Ollama (no setup script needed):

```bash
# Quick start — Ollama picks a default model
ollama launch claude

# Or specify a model
ollama launch claude --model kimi-k2.5:cloud
```

**Note:** Cloud models send data to Ollama's servers. Use local models for privacy-sensitive work.

## Known Limitations

### Local models

Local models are meaningfully weaker than Anthropic's cloud models. Expect:

- **Tool-calling friction** — Local models may fail to invoke Claude Code's tools correctly, requiring retries
- **Slower responses** — 30-60+ seconds per turn on consumer hardware vs. 2-5 seconds on the cloud API
- **Weaker multi-file reasoning** — Best suited for single-file tasks, refactoring, tests, and boilerplate
- **System prompt adherence** — Models may ignore Claude Code's internal instructions

**Best for:** Learning Claude Code, building demos/MVPs, privacy-sensitive work, offline development.

### Cloud models

Cloud models are significantly more capable than local models but have their own trade-offs:

- **Data leaves your machine** — requests are processed on Ollama's servers
- **Usage limits** — free tier has rate/usage caps; higher tiers available
- **Internet required** — no offline usage
- **Not Anthropic quality** — still open-source models, better than local but below Claude API

**Best for:** Larger codebases, stronger reasoning without local hardware limits, quick prototyping.

## How to Switch Models

```bash
# 1. Pull the new model
ollama pull qwen2.5-coder:14b

# 2. Update your shell profile — change the model in the sentinel block
# Look for the # >>> claude-code-ollama >>> section

# 3. Verify
./setup.sh --verify    # or .\setup.ps1 -Verify on Windows
```

## How to Uninstall

```bash
# 1. Remove Claude Code
npm uninstall -g @anthropic-ai/claude-code

# 2. Remove env vars — delete the sentinel block from your shell profile
#    (~/.bashrc, ~/.zshrc, or PowerShell $PROFILE)
#    Delete everything between:
#    # >>> claude-code-ollama >>>
#    # <<< claude-code-ollama <<<

# 3. (Optional) Remove Ollama
#    macOS: brew uninstall ollama
#    Linux: see https://ollama.com/docs/uninstall
#    Windows: Settings > Apps > Ollama > Uninstall
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Node.js not found` | Install from [nodejs.org](https://nodejs.org) (v18+) |
| `Ollama version too old` | Upgrade: `brew upgrade ollama` or download from [ollama.com](https://ollama.com) |
| Model download fails | Check internet connection and available disk space |
| `claude` command not found | Run `npm install -g @anthropic-ai/claude-code` and restart your terminal |
| `Git Bash is not installed` (Windows) | Install from [git-scm.com](https://git-scm.com/downloads/win). Claude Code requires Git Bash on Windows. |
| Verification timeout | Model may need more RAM. Try a smaller model, or a cloud model |
| Existing API config conflict | Script backs up your config to `~/.claude-code-ollama-backup` |
| Cloud model sign-in fails | Run `ollama signin` manually and retry |

## Using with Paid API Too

If you also use the paid Anthropic API, add an alias to your shell profile instead of global env vars:

```bash
alias claude-local='ANTHROPIC_BASE_URL=http://localhost:11434 ANTHROPIC_AUTH_TOKEN=ollama ANTHROPIC_API_KEY="" claude'
```

Then use `claude-local` for Ollama and `claude` for the paid API.

## How It Works

The scripts set these environment variables to redirect Claude Code to your local Ollama instance:

```
ANTHROPIC_BASE_URL=http://localhost:11434
ANTHROPIC_AUTH_TOKEN=ollama
ANTHROPIC_API_KEY=""
OLLAMA_NUM_CTX=<ram-appropriate-value>
```

Ollama's native Anthropic Messages API compatibility (v0.15.3+) handles the translation — no proxy layer needed.

## License

[MIT](LICENSE)
