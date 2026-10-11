# AI Prime Cursor Manager (Windows) — Experimental

English | [فارسی](README.fa.md)

**Status: experimental / alpha.** This project is a Windows utility for testing an authenticated local OpenAI-compatible bridge from Cursor to AI Prime Tech. The bridge and static tunnel-contract tests pass in the current development environment, but the complete WPF GUI and live Cloudflare Quick Tunnel have not been end-to-end validated on a clean Windows machine. Do not treat the current source as a production-ready release.

## What it does

- Windows PowerShell/WPF dashboard for testing an AI Prime Tech key and fetching model IDs available to that key.
- Local Node.js bridge bound to `127.0.0.1`, exposing one configurable model alias to Cursor and forwarding requests to AI Prime Tech.
- Bearer-key authentication between Cursor and the local bridge; Cursor should receive the bridge key, not the upstream AI Prime Tech key.
- Bridge controls, logs, cursor setup values, model selection and experimental Cloudflare Quick Tunnel management.
- Offline smoke tests that use a local mock upstream and do not require real API credentials.

## Important limitations

- **Built-in Cursor Explore limitation:** this project cannot override Cursor product restrictions. Depending on Cursor version/configuration, a BYOK custom model may not be independently selectable for the built-in Explore Subagent.
- **Remote Cursor and localhost:** a remote/cloud request cannot directly reach your computer's `127.0.0.1`. The experimental Quick Tunnel tab offers a temporary public HTTPS route for testing. Keep authentication enabled and stop the tunnel after use. Do not use an unauthenticated public bridge.
- **Windows validation:** this development environment cannot run WPF. Real startup, Start/Stop Bridge, download progress, and Quick Tunnel must be verified by a Windows tester before making a stable release.
- The prebuilt EXE is intentionally not tracked in the source repository until it can be verified against the current source. Run the PowerShell launcher from the full extracted folder instead.
- Prompts and code sent through the bridge are processed by AI Prime Tech. Do not send confidential code unless permitted by your policies.

## Requirements

- Windows 10/11
- Windows PowerShell 5.1+ with WPF
- Node.js 20+ on `PATH`
- Active AI Prime Tech API key with access to the chosen model

## Run from source

1. Download or clone this repository and extract it to a normal folder (not directly inside the ZIP).
2. Run `Start-AI-Prime-Cursor-Manager.bat`.
3. If startup fails, run `Start-AI-Prime-Cursor-Manager-Diagnostics.bat` and share only the error text, never keys or tunnel URLs.
4. In Dashboard, enter the AI Prime Tech API key and use **Refresh model catalog**.
5. Select a model and run **Test selected model** before a longer session.
6. Start the local Bridge. In a separate Cursor profile, configure **Use OpenAI API Key** and **Override OpenAI Base URL** with values shown in Cursor Setup. Use the *local bridge key*, not the AI Prime Tech key.

### Run offline tests

With Node.js 20+ installed:

```powershell
npm test
npm run check
```

Or double-click `Run-Bridge-Smoke-Tests.bat` on Windows. Tests use a mock upstream and do not call AI Prime Tech.

## Security

- Never commit API keys, bridge keys, access tokens, logs, settings or Cloudflare tunnel URLs.
- The bridge must bind to `127.0.0.1`, and API endpoints must require the random local bearer key.
- Do not expose the bridge directly to a LAN or internet. The temporary public tunnel is only for controlled testing; the key remains required.
- Rotate any key that has ever been pasted into chat, screenshots, issues or logs.

## Current project maturity

The code includes historical fixes after Windows runtime errors, so source-level tests are not a substitute for a full GUI smoke test on Windows. See [TEST-REPORT.md](TEST-REPORT.md) and [docs/RELEASING.md](docs/RELEASING.md). Please report failures with the exact error text after removing secrets.

## License

No license has been selected by the project owner yet. Until a license is added, assume all rights are reserved and do not redistribute or create derivative works. Choose a license before announcing this as an open-source project.