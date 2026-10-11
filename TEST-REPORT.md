# Test report — GitHub-ready source snapshot

Tested in the packaging environment on 2026-10-11.

## Results

- `npm run check`: passed (Node syntax checks for the bridge and JavaScript test files).
- `npm test`: passed on 5 consecutive runs.
  - Bridge integration suite: 12 checks per run; local mock upstream only.
  - Tunnel contract suite: 14 static checks per run; no live Cloudflare tunnel is launched.
  - Total: 130 successful assertions across the five runs.
- Source/package scan: no literal AI Prime Tech API key or GitHub token pattern found in source files.
- Prebuilt EXE intentionally excluded from source tree pending Windows runtime validation.

## Not tested in this environment

- WPF GUI runtime on Windows.
- Live AI Prime Tech calls from the packaged desktop UI.
- Actual download of cloudflared, creation of a live Cloudflare Quick Tunnel, or reachability from a Cursor provider.
- Whether a particular Cursor build permits a BYOK model to be assigned independently to built-in Explore Subagent.

The tests establish behavior of the bridge against a mock upstream and static contracts of the tunnel helper. They are not a substitute for following `docs/RELEASING.md` on a real Windows 10/11 machine.