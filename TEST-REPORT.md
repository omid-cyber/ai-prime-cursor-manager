# Test report — GitHub Actions acceptance

Latest validated source/package workflow run on 2026-10-11:

- Source commit: `45376acbbcd5d82d22db623f711add7889c43f76`.
- [Regular Tests workflow](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/runs/38115346643): **success**.
- [Package Alpha Source Bundle workflow](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/runs/38115346608): **success**.
- The workflow staged the required source, created a ZIP, extracted it to a clean directory, reran Node and PowerShell/XAML checks against the extracted copy, and uploaded the artifact.
- Artifact: `ai-prime-cursor-manager-source-45376acbbcd5d82d22db623f711add7889c43f76`, 51,327 bytes (GitHub artifact container), SHA-256 digest `148562f11e7317fc712cb43ff06f08270129db08ab0e78e435ff66b10165b633`.
- Artifact expiry: 2026-10-25. It can be downloaded from the Artifacts section of the [successful packaging run](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/runs/38115346608).

This proves source packaging and extracted-archive validation pass for that commit. It does **not** prove live WPF startup, real upstream API calls from the desktop UI, or a live Cloudflare tunnel. Documentation-only updates may be newer than the packaged artifact; run the packaging workflow again from `main` to package the latest revision.

---

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