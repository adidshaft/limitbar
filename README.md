# LimitBar

A minimal macOS menu bar app that shows your remaining **Claude Code** and **Codex** rate limits — each with its logo, right in the menu bar.

- **Claude** (spark icon) and **Codex** (knot icon), each showing the remaining % of your most-constrained limit window
- Click either icon for the full breakdown: session (5h) and weekly windows, model-specific limits, reset times
- Turns red below 10% remaining
- Auto-refreshes every 5 minutes, on wake, and when you open the menu
- Template icons adapt to light/dark menu bars

## Install

Grab `LimitBar.dmg` from [Releases](../../releases), drag LimitBar to Applications, and launch it.

> The app is ad-hoc signed (no Apple Developer ID), so on first launch macOS may block it: right-click **LimitBar.app → Open → Open**, or allow it under System Settings → Privacy & Security.

Enable **Launch at Login** from the dropdown menu if you want it always on.

## How it works — everything stays local

No logins, no accounts, no third-party services, no analytics. LimitBar reuses the credentials the CLIs already store on your Mac and calls the same usage endpoints the CLIs themselves use:

| | Credential source | Usage endpoint |
|---|---|---|
| Claude | macOS Keychain item `Claude Code-credentials` (what Claude Code uses) | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` (what the Codex CLI uses) | `chatgpt.com/backend-api/wham/usage` |

Access tokens expire (Claude's every 8 hours). LimitBar refreshes them locally with the refresh token already on your machine — the same flow the CLIs use — and writes the new token back to the same storage so the CLIs and the app share one valid token chain.

### Credential safety

The write-back logic is deliberately conservative, so LimitBar can never break your CLI logins:

- Writes are gated on **exact token ancestry**: the store is only overwritten if it provably still holds the token LimitBar consumed (or its recorded ancestor). A `claude /login`, `codex login`, API-key switch, or logout mid-flight is never clobbered.
- `auth.json` is written atomically, splicing in only the token fields — anything else the CLI wrote meanwhile survives.
- If a write-back fails (locked keychain, etc.), the fresh token is kept in memory and the write retried each cycle, so the rotation chain is never stranded.
- Logout is detected and respected; subprocess calls have deadlines so a keychain prompt can never freeze the app.

## Build from source

```bash
./build.sh
cp -R build/LimitBar.app /Applications/
open /Applications/LimitBar.app
```

Single Swift file, no dependencies, no Xcode project — just `swiftc`. Requires macOS 13+.

Debug modes: `LimitBar --test-fetch` prints current limits to stdout; `LimitBar --dump-icons <dir>` renders the icons to PNG.

## License

MIT
