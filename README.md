# Shellwave

Eigener SSH-Client für iPhone und iPad (iOS 26, Liquid Glass) als Termius-Ersatz.
Anmeldung über kurzlebige Zertifikate aus der eigenen UCM-SSH-CA, später Mosh,
Live Activity und Claude Code als Assistent. Spezifikation: siehe Claude-Doc
„SSH-Client für iOS – Spezifikation“.

## Funktionen (M1–M5)

- **Hosts** als Glas-Karten mit Suche, Tags, Farben; Transport SSH oder Mosh
- **UCM-SSH-CA**: Ed25519-Geräteschlüssel, Zertifikat per API (12 h), stille Erneuerung, manueller Import
- **Server einrichten**: TrustedUserCAKeys, AuthorizedPrincipalsFile mit Principals pro Benutzer,
  `sshd -t`, Reload, Test-Login mit Zertifikat, Rollback bei Fehler; Unraid-Persistenz über `/boot/config/go`;
  optional Mosh und Claude Code installieren
- **SSH** mit Zertifikat, Geräte-Key oder Passwort (Citadel), Host-Key-Prüfung (TOFU)
- **Mosh** über Blinks mosh.xcframework (Bootstrap per SSH, Roaming), automatischer Rückfall auf SSH
- **Keep-alive** im Hintergrund über grobe Standort-Updates, **tmux-Auto-Attach**
- **Live Activity** im Dynamic Island: Host, Status, Dauer; Claude-Freigaben mit Sprung in die App
- **Snippets** mit `{{variablen}}`, im Terminal einfügen oder auf mehreren Hosts parallel ausführen
- **Claude**: Claude Code headless auf dem Server (stream-json, Freigaben über `--permission-prompt-tool stdio`)
  oder Claude-API aus der App mit `run_command`; lesende Befehle automatisch, Rest mit Face ID
- **SFTP**-Browser mit Up-/Download, Ordner anlegen, Umbenennen, Löschen
- **Session-Reiter**, Farbschemata (Shellwave, Solarized, Nord, Dracula), Export/Import von Hosts und Snippets

## Bauen

GitHub Actions baut bei jedem Push auf `main` eine unsigned IPA
(`Shellwave-unsigned.ipa` als Artefakt, bei Tags `v*` zusätzlich als Release-Asset).
Die IPA wird über das Feather-Repo signiert und installiert.

Lokal (macOS, Xcode 26):

```sh
brew install xcodegen
xcodegen generate
open Shellwave.xcodeproj
```

## Server vorbereiten (bis zum Auto-Install in M2 manuell)

```sh
# CA-Public-Key aus UCM
echo "ssh-ed25519 AAAA… ucm-user-ca" > /etc/ssh/ucm_user_ca.pub
mkdir -p /etc/ssh/auth_principals
echo "marc" > /etc/ssh/auth_principals/root

cat >> /etc/ssh/sshd_config <<'CFG'
TrustedUserCAKeys /etc/ssh/ucm_user_ca.pub
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
CFG
sshd -t && systemctl reload ssh   # Unraid: /etc/rc.d/rc.sshd reload
```

## Bibliotheken

| Zweck | Paket |
| --- | --- |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) 0.12.x, [swift-nio-ssh (Fork)](https://github.com/Wellz26/swift-nio-ssh) 0.3.x |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0 |
| Mosh | [mosh-apple](https://github.com/blinksh/mosh-apple) xcframework (GPLv3), Locale-Daten aus [Blink](https://github.com/blinksh/blink) |
| UCM-API | aus [ucm-remote](https://github.com/kernelguru/ucm-remote) übernommen (`Shellwave/UCM`) |

## Lizenz-Hinweis

Der Mosh-Client und die Locale-Daten stammen aus Blink/mosh und stehen unter GPLv3.
Wer die App weitergibt, muss den Quellcode ebenfalls unter GPLv3 bereitstellen.
