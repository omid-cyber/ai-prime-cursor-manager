# AI Prime Cursor Manager (Windows) — Experimentell

[English](README.md) | [Eesti](README.et.md) | [Français](README.fr.md) | Deutsch | [فارسی](README.fa.md)

**Status: experimentell / Alpha.** Dieses Projekt ist ein Windows-Werkzeug zum Testen einer authentifizierten lokalen, OpenAI-kompatiblen Bridge zwischen Cursor und AI Prime Tech. Die Bridge- und statischen Tunnel-Vertragstests bestehen in der aktuellen Entwicklungsumgebung. Die vollständige WPF-Oberfläche und ein echter Cloudflare Quick Tunnel wurden jedoch noch nicht auf einem sauberen Windows-System Ende-zu-Ende validiert. Betrachte den aktuellen Quellcode daher nicht als produktionsreife Veröffentlichung.

## Funktionen

- PowerShell/WPF-Dashboard zum Testen eines AI-Prime-Tech-API-Schlüssels und zum Abrufen der für diesen Schlüssel verfügbaren Modell-IDs.
- Lokale Node.js-Bridge, die an \`127.0.0.1\` gebunden ist, Cursor einen konfigurierbaren Modellalias bereitstellt und Anfragen an AI Prime Tech weiterleitet.
- Bearer-Schlüssel-Authentifizierung zwischen Cursor und der lokalen Bridge. Cursor muss den Bridge-Schlüssel erhalten, nicht den AI-Prime-Tech-API-Schlüssel.
- Bridge-Steuerung, Protokolle, Cursor-Einrichtungswerte, Modellauswahl und experimentelle Verwaltung eines Cloudflare Quick Tunnels.
- Offline-Smoke-Tests mit einem lokalen simulierten Upstream; echte API-Zugangsdaten sind dafür nicht erforderlich.

## Sprachen der Benutzeroberfläche

Die WPF-Oberfläche bietet oben rechts eine Sprachauswahl. Unterstützt werden **Englisch (Standard), Estnisch, Französisch und Deutsch**. Beim Wechsel der Sprache werden übersetzte Beschriftungen, Registerkarten, Schaltflächen, Tooltips, der Sicherheitshinweis und Statusmeldungen aktualisiert. Die gewählte Sprache wird in den benutzerspezifischen Einstellungen gespeichert und beim nächsten Start wiederhergestellt.

Technische Bezeichner, Modell-IDs, URLs und Antworten des Anbieters bleiben im Original, damit sie exakt kopiert werden können.

## Wichtige Einschränkungen

- **Einschränkung des integrierten Cursor Explore:** Dieses Projekt kann Produktbeschränkungen von Cursor nicht umgehen. Je nach Cursor-Version und Konfiguration lässt sich ein benutzerdefiniertes BYOK-Modell möglicherweise nicht separat für den integrierten Explore Subagent auswählen.
- **Remote-Cursor und localhost:** Eine Remote- oder Cloud-Anfrage kann nicht direkt auf \`127.0.0.1\` deines Computers zugreifen. Die experimentelle Quick-Tunnel-Registerkarte bietet für Tests eine temporäre öffentliche HTTPS-Adresse. Lasse die Authentifizierung aktiviert und stoppe den Tunnel nach dem Test. Verwende keine öffentliche Bridge ohne Authentifizierung.
- **Windows-Validierung:** In dieser Entwicklungsumgebung kann WPF nicht ausgeführt werden. Vor einer stabilen Veröffentlichung muss ein Windows-Tester den tatsächlichen Start, das Starten/Stoppen der Bridge, den Download-Fortschritt und Quick Tunnel auf einem echten Windows-System prüfen.
- Die vorkompilierte EXE wird absichtlich nicht im Quellcode-Repository geführt, solange sie nicht mit dem aktuellen Quellcode abgeglichen wurde. Starte stattdessen den PowerShell-Launcher aus dem vollständig entpackten Ordner.
- Prompts und Code, die über die Bridge gesendet werden, werden von AI Prime Tech verarbeitet. Sende keinen vertraulichen Code, sofern deine Richtlinien dies nicht erlauben.

## Voraussetzungen

- Windows 10/11
- Windows PowerShell 5.1 oder neuer mit WPF
- Node.js 20 oder neuer über \`PATH\` erreichbar
- Aktiver AI-Prime-Tech-API-Schlüssel mit Zugriff auf das ausgewählte Modell

## Aus dem Quellcode starten

1. Lade dieses Repository herunter oder klone es und entpacke es in einen normalen Ordner (nicht direkt im ZIP).
2. Starte \`Start-AI-Prime-Cursor-Manager.bat\`.
3. Falls der Start fehlschlägt, starte \`Start-AI-Prime-Cursor-Manager-Diagnostics.bat\` und teile nur den Fehlertext, niemals Schlüssel oder Tunnel-URLs.
4. Gib im Dashboard den AI-Prime-Tech-API-Schlüssel ein und wähle **Refresh model catalog**.
5. Wähle ein Modell aus und führe vor einer längeren Sitzung **Test selected model** aus.
6. Starte die lokale Bridge. Richte in einem separaten Cursor-Profil **Use OpenAI API Key** und **Override OpenAI Base URL** anhand der in Cursor Setup angezeigten Werte ein. Verwende den *lokalen Bridge-Schlüssel*, nicht den AI-Prime-Tech-Schlüssel.

### Offline-Tests ausführen

Mit Node.js 20 oder neuer:

\`\`\`powershell
npm test
npm run check
\`\`\`

Alternativ kannst du unter Windows auf \`Run-Bridge-Smoke-Tests.bat\` doppelklicken. Die Tests verwenden einen simulierten Upstream und rufen AI Prime Tech nicht auf.

## Sicherheit

- Committe niemals API-Schlüssel, Bridge-Schlüssel, Zugriffstoken, Protokolle, Einstellungsdateien oder Cloudflare-Tunnel-URLs.
- Die Bridge muss an \`127.0.0.1\` gebunden sein und für API-Endpunkte muss der zufällige lokale Bearer-Schlüssel erforderlich sein.
- Stelle die Bridge weder im LAN noch direkt im Internet bereit. Der temporäre öffentliche Tunnel ist nur für kontrollierte Tests gedacht; der Schlüssel bleibt erforderlich.
- Widerrufe und ersetze jeden Schlüssel, der jemals in einen Chat, Screenshot, ein Issue oder ein Protokoll eingefügt wurde.

## Validiertes Quellcodepaket herunterladen (Alpha)

Ein manuell gestarteter GitHub-Actions-Workflow erstellt eine ZIP-Datei nur mit Quellcode und validiert das entpackte Archiv vor dem Hochladen:

1. Öffne [Actions](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/workflows/package-alpha-source.yml).
2. Wähle **Package Alpha Source Bundle**, klicke im Branch \`main\` auf **Run workflow** und warte, bis der Lauf abgeschlossen ist.
3. Lade das Artefakt \`ai-prime-cursor-manager-source-<commit>\` aus einem erfolgreichen Lauf herunter. Das Artefakt läuft nach 14 Tagen ab.
4. Entpacke die ZIP-Datei vollständig in einen normalen Ordner und starte \`Start-AI-Prime-Cursor-Manager.bat\`.

Der Workflow wiederholt die Node-Syntaxprüfungen, Offline-Smoke-Tests für Bridge/Tunnel und die PowerShell/XAML-Vorprüfung. Außerdem entpackt er die ZIP-Datei in ein neues Verzeichnis und führt die Prüfungen erneut auf dieser Kopie aus.

**Dies ist ein validiertes Quellcodepaket, keine kompilierte EXE und keine stabile Veröffentlichung.** Die tatsächliche WPF-Oberfläche und ein echter Cloudflare Quick Tunnel müssen weiterhin manuell unter Windows 10/11 getestet werden. Eine Weiterverteilungslizenz wurde noch nicht festgelegt; siehe \`LICENSE-DECISION.md\`.

## Aktueller Reifegrad des Projekts

Der Code enthält frühere Korrekturen nach Windows-Laufzeitfehlern. Quellcode-Tests ersetzen deshalb keinen vollständigen GUI-Smoke-Test unter Windows. Siehe [TEST-REPORT.md](TEST-REPORT.md) und [docs/RELEASING.md](docs/RELEASING.md). Melde Fehler mit dem genauen Fehlertext, nachdem du Geheimnisse entfernt hast.

## Lizenz

Der Projekteigentümer hat noch keine Lizenz ausgewählt. Bis eine Lizenz hinzugefügt wird, gilt: Alle Rechte vorbehalten. Verbreite den Code nicht weiter und erstelle keine abgeleiteten Werke. Wähle eine Lizenz, bevor du das Projekt als Open Source ankündigst.