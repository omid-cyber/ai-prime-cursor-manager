# Security policy

## Scope

This project handles third-party API credentials and can expose a local API bridge through an optional temporary public tunnel. Treat security issues seriously.

## Reporting

Do not report vulnerabilities in a public issue. Use GitHub's private vulnerability reporting feature if enabled for this repository, or contact the repository owner privately through their GitHub profile.

## Credential hygiene

- Never share AI Prime Tech keys or local Bridge keys in issues, logs, screenshots, or commits.
- Revoke any credential that has been exposed.
- The bridge should bind to `127.0.0.1` and require a random bearer key on model/chat endpoints.
- Quick Tunnel hostnames are public; the URL is not a secret substitute for authentication.
- Do not log prompts, source code, bearer keys, environment variables, or upstream response bodies unless carefully redacted.