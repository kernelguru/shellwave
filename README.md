# Shellwave

Eigener SSH-Client für iPhone und iPad (iOS 26, Liquid Glass) als Termius-Ersatz.
Anmeldung über kurzlebige Zertifikate aus der eigenen UCM-SSH-CA, später Mosh,
Live Activity und Claude Code als Assistent. Spezifikation: siehe Claude-Doc
„SSH-Client für iOS – Spezifikation“.

## Stand: Meilenstein 1 (Verbinden)

- Host-Liste als Glas-Karten, Suche, Tags, Farben
- Ed25519-Geräteschlüssel, privat nur im Schlüsselbund
- UCM-Anbindung (API aus ucm-remote): CA laden, Zertifikat signieren lassen,
  automatische Erneuerung vor dem Verbinden, TLS-Pinning
- Manueller Import von `-cert.pub` (Datei, Zwischenablage, Einfügen)
- SSH mit Zertifikat, Geräte-Key oder Passwort (Citadel / swift-nio-ssh)
- Host-Key-Prüfung nach Trust-on-first-use
- Terminal mit SwiftTerm (xterm-256color, Zubehörleiste mit Esc/Ctrl/Tab/Pfeilen),
  bleibt beim Zuklappen der Session erhalten

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
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99.x |
| UCM-API | aus [ucm-remote](https://github.com/kernelguru/ucm-remote) übernommen (`Shellwave/UCM`) |
