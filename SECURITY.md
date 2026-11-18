# Security

`capturist` runs entirely on your Mac. It never contacts a server of its own.

## What it can read

- **Direct mode** (Capturist closed, or Capturist 1.0): it opens the Capturist library in your user account read-only. It never writes to the app's library; it keeps its own text index in `~/.capturist/`.
- **Relay mode** (Capturist 1.1+ open with Settings › AI Agents on): it forwards MCP messages to the app's server on `127.0.0.1`. The app decides what is allowed (saving to your library is a separate switch, off by default).

## The local connection

- The app's server listens on `127.0.0.1` only, so it can't be reached from other machines.
- Every request needs a random bearer token. The app writes it to `agents.json` in its own library folder, readable only by your user (mode 0600), and removes it when the server stops.
- Requests with a non-local `Origin` header are refused, so web pages can't call it.

## What `setup` changes

`capturist setup …` only edits the configuration file of the app you name (for example `~/Library/Application Support/Claude/claude_desktop_config.json` or `~/.codex/config.toml`), keeps a `.capturist-backup` copy, and asks before changing anything unless you pass `--yes`. `setup shortcut` sets a keyboard shortcut for Capturist's macOS Service in the `pbs` preferences.

## Reporting a problem

Please report security issues privately through https://capturist.nodetools.org/support/ rather than in a public issue.
