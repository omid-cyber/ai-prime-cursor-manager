# Release checklist

Do not create a stable release until every item below has been checked on a real Windows 10/11 machine.

- [ ] Confirm the owner-selected repository visibility and license.
- [ ] Review staged diff and confirm no API keys, bridge keys, local paths, logs or tunnel URLs are included.
- [ ] Run `npm test` and `npm run check`.
- [ ] Run `Start-AI-Prime-Cursor-Manager-Diagnostics.bat`; confirm WPF opens without ParserError or XamlParseException.
- [ ] Test API key submission with a rotated test key. Never save the test key in screenshots/logs.
- [ ] Fetch model catalog; test one model; confirm concurrency-limit responses remain recoverable.
- [ ] Start, test, and stop the bridge repeatedly; confirm the window stays open and does not spawn duplicate listeners.
- [ ] Test old and new `tunnel-state.json` files.
- [ ] Test Cloudflare executable download with progress, invalid/partial download cleanup, version validation, URL detection, and Stop Tunnel.
- [ ] Confirm the temporary public URL still requires the local Bridge bearer key.
- [ ] Test Cursor through a Quick Tunnel and confirm the current Cursor plan accepts the endpoint.
- [ ] Only after all Windows checks pass, build and attach the matching EXE to a GitHub Release. Keep binaries out of source history.
- [ ] Tag the verified commit and provide release notes plus known limitations.