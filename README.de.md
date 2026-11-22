# Post & Pakete

**Angekündigte Briefe und Pakete – auf iPhone, iPad, Apple Watch, Mac und Linux. DHL, Deutsche Post, Hermes, DPD, GLS, UPS und Amazon.**
Eine App für die ganze Post – wie *Parcel*, nur ohne fremden Server und dazu mit den Briefen, die die Deutsche Post per Mail ankündigt (mit Bild des Umschlags): Die Zentrale ist dein Home Assistant mit der Integration
[Briefankündigung](https://github.com/Teyro/Briefankuendigung-HA) (ab 1.5). Sie liest die Versandmails der
Dienste, fragt auf Wunsch DHL und 17TRACK nach dem aktuellen Stand und hält alle Geräte auf demselben Stand.

*English: see [README.md](README.md)*

## Was Post & Pakete kann

- **Alle Sendungen auf einen Blick:** Heute · Unterwegs · Zugestellt – sortiert nach voraussichtlicher Zustellung
  („kommt morgen, 10:00–13:00“, „voraussichtlich Fr 30.10.“, „zur Abholung bereit“, „überfällig seit …“)
- **Verlauf jeder Sendung** mit Stationen und – auf iPhone und Mac – einer **Karte** der Orte
- **Logos in den Farben der Dienste**, Fortschritt in vier Schritten (angekündigt → unterwegs → in Zustellung → zugestellt)
- **Sendung hinzufügen** per Nummer (auch aus der Zwischenablage), der Dienst wird meist erkannt; **umbenennen**,
  „Angekommen“ abhaken (gilt auf allen Geräten), eigene Sendungen entfernen, beim Dienst verfolgen
- **Mehrere Amazon-Konten:** an jedem Paket steht, für wen es ist (Kundenkonten in der Integration)
- **Mitteilungen** bei „kommt heute“, „zur Abholung bereit“, „zugestellt“ und Problemen
- **Widgets:** iPhone (Home- und Sperrbildschirm), Mac (Schreibtisch), Plasma (Panel und Kachel)
- **Siri & Kurzbefehle:** „Welche Pakete kommen heute mit Post & Pakete?“, „Sendung mit Post & Pakete verfolgen“
- Deutsch und Englisch, hell und dunkel, Updates (Mac und Linux mit einem Klick)

## Neu in 2.0: Post & Pakete – eine App für Briefe und Pakete

Aus *Post & Pakete*, *Briefankündigung Desktop* und dem Scriptable-Widget wird eine App: **Briefe** (Umschlagbild,
„Wichtig“, Angekommen, Erinnern, Notiz) und **Pakete** in einer gemeinsamen Liste – Heute · Unterwegs · Angekommen –
mit der Auswahl „Alles | Briefe | Pakete“. Widgets, Siri („Was kommt heute?“), Menüleiste, Plasma-Widget und KRunner
zeigen beides. Neues Symbol. Liquid Glass auf iPhone, iPad und Mac (ab iOS/macOS 26), KDE-Design (Kirigami/Breeze) unter Linux.

## Direkt verfolgen – auch ohne Home Assistant

Sendungsnummer eintippen, einfügen oder den Paketschein **scannen** – Post & Pakete holt Stand, Verlauf und Karte selbst.
Mehrere Anbieter werden der Reihe nach gefragt; antwortet einer nicht, springt der nächste ein. In den Einstellungen
lässt sich jeder einzeln an- und abschalten:

| Anbieter | Dienste | Schlüssel |
|---|---|---|
| DHL (offiziell) | DHL, Deutsche Post | kostenlos (developer.dhl.com) |
| **DHL ohne Schlüssel** | DHL, Deutsche Post | keiner – dhl.de, ersatzweise deutschepost.de |
| UPS (offiziell) | UPS | kostenlos (developer.ups.com) |
| 17TRACK | fast alle | 200 Sendungen frei |
| Ship24 | fast alle | Schlüssel |
| GLS, DPD öffentlich | GLS, DPD | keiner (inoffiziell, kann ausfallen) |

Sendungen aus Home Assistant ohne Verlauf verfolgt die App automatisch mit. Dazu: **Live-Aktivität** und Dynamic Island,
**Teilen-Menü** („Teilen → Post & Pakete“ aus Mail oder Safari), **Statistik**, **Notiz und Foto** je Sendung,
**Rücksendungen**, **Apple Watch** (eigene IPA), auf dem Mac **Ziehen & Ablegen**, **⌥⌘P** von überall und **Drucken**,
unter Linux **KRunner** („pb 0034…“), **Karte**, **Mitteilungen** und **Flatpak**.

**Widgets auf dem iPhone mit Signulous:** Signulous übernimmt die App-Gruppe nicht. Deshalb das Widget lange drücken →
„Widget bearbeiten“ → Home-Assistant-Adresse und Token eintragen; dann lädt es selbst.

## Bestandteile

| | |
|---|---|
| **iPhone / iPad** | SwiftUI-App mit Widgets, Hintergrundabruf und Siri – als IPA zum Installieren über **Signulous** (oder eine eigene Signatur) |
| **Mac** | gleiche App für macOS 14+: Fenster mit Liste und Sendung, Symbol in der Menüleiste, Schreibtisch-Widgets |
| **Linux** | Kirigami-App (Startmenü) und **Plasma-6-Widget** mit Zahl im Panel – beide teilen sich die Einstellungen |

## Voraussetzung: Home Assistant

1. Integration **Briefankündigung** über HACS installieren (ab **1.5**) und dein Postfach eintragen.
2. Unter *Konfigurieren*: die **Paketdienste** wählen; optional
   - **17TRACK-Schlüssel** (api.17track.net, kostenlos: einmalig 200 Sendungen) für den Live-Stand von Hermes, DPD, GLS, UPS,
   - **DHL-API-Schlüssel** (developer.dhl.com, kostenlos) für DHL live,
   - **Mitteilungen an** die Home-Assistant-App deines iPhones – die zuverlässigsten Push-Mitteilungen.
3. Ein **langlebiges Zugriffstoken** anlegen (unten links auf deinen Namen → Sicherheit).

**Pakete mit „Paket Tracker“ (empfohlen):** Ist die Integration [Paket Tracker](https://github.com/SoerenKaiser99/parcel_tracker)
(HACS) eingerichtet, holt die App alle Pakete von dort – DHL, DPD, GLS, Hermes, UPS, Amazon, eBay, AliExpress – und
legt neue Sendungen dort an (umbenennen, „Erhalten“, entfernen inklusive). **Briefankündigung** liefert dann nur noch die
Briefe der Deutschen Post; ohne Briefankündigung zeigt die App eben nur Pakete.

Amazon, Hermes und DPD haben keine offene Schnittstelle für Privatkunden. Post & Pakete meldet sich dort
bewusst **nicht** mit deinem Konto an – die Versandmails und 17TRACK genügen.

## Installieren

**iPhone/iPad:** `PostUndPakete-iOS-x.y.z.ipa` aus den [Releases](https://github.com/Teyro/Post-und-Pakete/releases) in Signulous
hochladen und installieren. Beim ersten Start Adresse und Token eintragen; Widgets wie gewohnt hinzufügen.
Neue Versionen zeigt die App oben als Hinweis.

**Mac:** `PostUndPakete-macOS-x.y.z.zip` laden, `Post & Pakete.app` in „Programme“ ziehen. Beim ersten Start mit
Rechtsklick → Öffnen (die App ist nicht notariell beglaubigt). Updates: Menü *Post & Pakete → Nach Updates suchen*.

**Apple Watch:** statt der normalen IPA `PostUndPakete-iOS-mit-Uhr-x.y.z.ipa` installieren.

**Linux (Flatpak):** `PostUndPakete-x.y.z.flatpak` laden und `flatpak install --user PostUndPakete-x.y.z.flatpak` (Einstellungen getrennt vom Plasma-Widget).

**Linux:** `post-und-pakete-linux-x.y.z.tar.gz` entpacken und `sh post-und-pakete/installieren.sh` ausführen (ohne Root).
Danach steht *Post & Pakete* im Startmenü und – unter Plasma 6 – in der Widget-Auswahl. Braucht Qt 6 und Kirigami
(bei KDE Plasma schon dabei). Updates installiert das Plasma-Widget auf Knopfdruck.

## Entwickeln

- `apple/`: `swift test` prüft den Kern; `apple/scripts/baue.sh` baut Mac-App und IPA (Xcode + XcodeGen)
- `linux/`: `node linux/test/logik-test.mjs`; Start ohne Installation: `qml6 -a widget linux/app/main.qml`
- `test/ha-mock.mjs`: nachgebautes Home Assistant für Tests und Bildschirmfotos
- Texte: deutsche Schlüssel, englisch in `i18n/en.json` (`node werkzeuge/texte.mjs`, dann `node werkzeuge/baue-uebersetzungen.mjs`)

Lizenz: GPL-3.0-or-later
