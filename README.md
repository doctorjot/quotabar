# QuotaBar

macOS-Menüleisten-App, die zeigt, wie viel deiner AI-Abo-Kontingente verbraucht ist —
Claude Code (5-Stunden-Fenster, Woche, modellgebundene Wochenlimits) und Grok
(gemeinsamer Wochen-Pool mit Aufschlüsselung nach Produkt).

Swift 6, SwiftUI, keine Abhängigkeiten. Kein Dock-Icon.

![Menüleiste](https://img.shields.io/badge/macOS-14%2B-black)

## Voraussetzungen

- macOS 14 oder neuer, Xcode 16+
- **Claude**: Claude Code muss angemeldet sein (`claude login`). Der OAuth-Token
  wird aus dem Keychain-Eintrag `Claude Code-credentials` gelesen.
- **Grok**: Die Grok-Build-CLI muss angemeldet sein. Der Token kommt aus
  `~/.grok/auth.json`.

Fehlt eine der beiden Anmeldungen, zeigt nur die betroffene Zeile einen Hinweis;
die andere läuft weiter.

## Bauen

```sh
xcodebuild -scheme QuotaBar -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/QuotaBar-*/Build/Products/Debug/QuotaBar.app
```

In `project.pbxproj` stehen `DEVELOPMENT_TEAM` und `CODE_SIGN_IDENTITY` des
ursprünglichen Autors — für eigene Builds durch die eigene Team-ID ersetzen oder
auf ad-hoc-Signierung zurückfallen (`CODE_SIGN_IDENTITY = "-"`).

## Wie es an die Daten kommt

| | Endpoint | Auth |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` | Bearer aus dem Keychain, Header `anthropic-beta: oauth-2025-04-20` |
| Grok | `GET cli-chat-proxy.grok.com/v1/billing?format=credits` | Bearer aus `~/.grok/auth.json`, Header `x-grok-client-mode: build` |

Beide Endpoints sind **inoffiziell und undokumentiert**. Sie können sich jederzeit
ändern; dann zeigt die betroffene Zeile einen Fehler statt einer Zahl.

Die lokalen Logs unter `~/.claude/projects/*/*.jsonl` taugen dafür übrigens nicht:
sie enthalten den Token-Verbrauch pro Anfrage, aber nirgends das Limit. Ein
Prozentwert daraus wäre eine Schätzung gegen einen geratenen Grenzwert.

## Eigenheiten, die Zeit kosten können

- **Der Anthropic-Endpoint drosselt hart.** Schon ein einzelner Aufruf nach einer
  Ruhephase kann ein `Retry-After` von einer Stunde auslösen. Deshalb wird nur alle
  15 Minuten abgefragt, `Retry-After` respektiert und der Aktualisieren-Knopf
  während einer Sperre übergangen. Nicht auf ein kürzeres Intervall stellen.
- **Der Keychain fragt bei jedem Start nach.** Claude Codes Eintrag nimmt fremde
  Apps nicht dauerhaft in seine Zugriffsliste auf, auch nicht über „Immer erlauben".
  Der Token wird deshalb nach dem ersten Lesen im Speicher behalten — ein Dialog pro
  Start statt einer pro Aktualisierung.
- **Kein Token-Refresh.** Das Einlösen des Refresh-Tokens könnte ihn rotieren und
  Claude Code beziehungsweise die Grok-CLI abmelden. Läuft ein Token ab, zeigt die
  Zeile einen Hinweis, und man meldet sich im jeweiligen Werkzeug neu an.
- **`MenuBarExtra` taugt auf Notch-Displays nicht.** SwiftUI gibt keinen Zugriff auf
  die Position, und macOS parkte das Item mittig hinter der Notch — vorhanden und
  klickbar, aber nie gezeichnet. Deshalb ein eigenes `NSStatusItem` mit
  `autosaveName`, dessen Startposition beim ersten Start gesetzt wird.

## Aufbau

```
Providers/UsageProvider.swift    Protokoll: ein Provider, mehrere Fenster
Providers/Claude…, Grok…         die beiden Implementierungen
Models/UsageSnapshot.swift       Fenster, Prozent, Reset, Erfassungszeit
UsageStore.swift                 paralleles Abrufen, Drosselung, 15-Minuten-Takt
AppDelegate.swift                NSStatusItem und Popover
Views/                           Popover und Zeilendarstellung
```

Ein weiterer Dienst braucht nur einen neuen Typ, der `UsageProvider` erfüllt, plus
einen Eintrag in der Provider-Liste im `AppDelegate`.

## Verwandte Projekte

[ClaudeBar](https://github.com/tddworks/ClaudeBar) kann dasselbe für zwölf Anbieter
und ist deutlich ausgereifter. QuotaBar ist bewusst klein gehalten.
