# Contributing

Thanks for considering a contribution.

## Before submitting

- Open an issue for major behavior changes first.
- Never submit API keys, local bridge tokens, account information, tunnel URLs, log files containing request data, or production source code from a private project.
- Keep the bridge loopback-only by default and retain bearer-key authentication.
- Avoid logging prompt bodies, response bodies, credentials, or environment variables.

## Local checks

Requires Node.js 20+.

```powershell
npm run check
npm test
```

On Windows, also run `Test-XamlResources.ps1` and test the WPF UI manually using the diagnostic launcher. The UI and Cloudflare Quick Tunnel are not fully validated by Node smoke tests alone.

## Pull requests

Describe the problem, changes, security implications, and tests run. Be explicit about checks that could not be performed on Windows.