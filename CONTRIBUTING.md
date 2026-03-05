# Contributing to ClawRig

Thanks for your interest in contributing!

## Development setup

```bash
# Install dependencies and build assets
mix setup

# Start the dev server
mix phx.server
```

Visit http://localhost:4090. On macOS/Linux, ClawRig uses mock system commands — no Pi required for development.

## Before submitting a PR

```bash
mix precommit
```

This runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, and `test`.

## Architecture overview

ClawRig is a Phoenix LiveView app targeting Raspberry Pi. Key modules:

| Module | Purpose |
|---|---|
| `Clawrig.Node.Client` | WebSocket client connecting to local OpenClaw Gateway as a node |
| `Clawrig.Node.Capabilities` | Dispatches `node.invoke` RPC calls to device capabilities |
| `Clawrig.Wizard` | OOBE setup wizard (Wi-Fi, OpenAI auth, provider config) |
| `Clawrig.System.Commands` | Behaviour for system commands with Pi/Mac/Mock implementations |
| `Clawrig.Updater` | OTA update checker with signature verification |
| `Clawrig.Wifi.Manager` | Wi-Fi scanning, connecting, hotspot management |

The `Commands` behaviour pattern (`PiCommands`, `MacCommands`, `MockCommands`) lets you develop and test without a Pi.

## Code style

- Follow the conventions in `AGENTS.md` (Phoenix/Elixir guidelines)
- Use `Req` for HTTP requests (not HTTPoison, Tesla, or httpc)
- Use `start_supervised!/1` in tests for process cleanup
- Avoid `Process.sleep/1` in tests — use monitors and message assertions

## Reporting issues

Please open an issue on GitHub with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Pi model and ClawRig version (if running on hardware)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
