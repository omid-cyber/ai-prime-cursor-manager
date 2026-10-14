# Changelog

All entries below reflect the code history provided with this repository; this is not a claim that every UI feature has passed Windows end-to-end testing.

## Unreleased

- Clearer dark-theme tabs and buttons: the selected tab is obvious, and hover no longer washes out the label.
- The header status color now includes a matching dot.
- Copyright notice for secocyber is shown in the window and documented in the READMEs.
## 1.7.0-alpha.1 — initial GitHub-ready snapshot

- WPF/PowerShell desktop manager for AI Prime Tech key/model management.
- Node.js OpenAI-compatible local bridge with bearer authentication, model alias rewriting, bounded queue and concurrency limit.
- Experimental Cloudflare Quick Tunnel helper with download validation and progress-state support.
- Offline bridge and tunnel contract smoke tests.
- Explicit experimental status; prebuilt EXE excluded pending Windows runtime validation.
- Added an in-app language selector and saved preference for English, Estonian, French and German.
- Added CI assertions for all four language choices, translation dictionary coverage and language persistence.
- Windows GitHub Actions validation includes PowerShell 5.1 parsing and XAML/control-name checks; PowerShell files retain a UTF-8 BOM for compatibility.
- Manual source-bundle workflow creates a ZIP, tests the extracted copy and uploads a short-lived Actions artifact. This is not an automatic public release.
