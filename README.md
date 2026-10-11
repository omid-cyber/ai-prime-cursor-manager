# AI Prime Cursor Manager

Windows utility for routing Cursor-compatible OpenAI API requests through a local authenticated bridge to AI Prime Tech.

> **Status: Experimental / alpha.** The WPF GUI and Cloudflare Quick Tunnel have not yet been validated end-to-end on a clean Windows machine. Do not treat this as a stable release.

## Features

- Windows WPF manager for API configuration and model selection.
- Local OpenAI-compatible bridge with a separate key for Cursor.
- Optional Cloudflare Quick Tunnel helper for testing remote-hosted model clients.
- Logs and diagnostic launchers.
- Automated Node.js tests and GitHub Actions checks.

## Important limitations

- Cursor may reject local/private network endpoints. The optional Quick Tunnel exposes the bridge over the public internet and is for testing only.
- Cursor's built-in Explore Subagent may not accept an independently configured BYOK model; this manager cannot bypass Cursor product limitations.
- Do not expose the bridge without authentication. Never commit API keys, local settings, runtime logs, `node_modules`, or downloaded `cloudflared` binaries.
- The app forwards prompts and selected code to AI Prime Tech when used.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1+
- Node.js 20+ and npm
- Internet access for the AI Prime Tech API; Quick Tunnel additionally needs access to Cloudflare

## Run from source

1. Download or clone this repository.
2. In PowerShell, enter the `AIPrimeCursorManager` directory.
3. Install dependencies only if the repository's `package.json` lists them: `npm install`.
4. Run automated checks: `npm test` (or see `TEST-REPORT.md` for available test scripts).
5. Start with `Start-AI-Prime-Cursor-Manager-Diagnostics.bat` first. Keep the console open while diagnosing startup errors.

Do not add real API keys to source files. The app's API key field should be used locally; if a key was shared publicly, revoke and rotate it.

## Repository contents

- `AIPrimeCursorManager/`: application sources, bridge, tests, helper scripts and docs.
- `TEST-REPORT.md`: scope and limits of automated checks.

## Security

See [SECURITY.md](SECURITY.md) before exposing the bridge through a tunnel.

## License

No license has been selected yet. See [LICENSE-DECISION.md](LICENSE-DECISION.md). Until a license is added, do not assume the code is open source or available for redistribution.
