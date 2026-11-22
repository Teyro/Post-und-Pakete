# Post & Pakete

**Announced letters and parcels – on iPhone, iPad, Apple Watch, Mac and Linux. DHL, Deutsche Post, Hermes, DPD, GLS, UPS and Amazon.**
Like the app *Parcel*, but without someone else’s server: the hub is your Home Assistant with the integration
[Briefankündigung](https://github.com/Teyro/Briefankuendigung-HA) (1.5 or later). It reads the carriers’ shipping
mails, optionally asks DHL and 17TRACK for the live status, and keeps all your devices in sync.

*Deutsch: siehe [README.de.md](README.de.md)*

## Features

- **All shipments at a glance:** Today · On the way · Delivered – sorted by expected delivery
  (“arrives tomorrow, 10:00–13:00”, “expected Fri 30.10.”, “ready for pickup”, “overdue since …”)
- **History of each shipment** with its stops and – on iPhone and Mac – a **map**
- **Carrier logos in their colours**, progress in four steps (announced → on the way → out for delivery → delivered)
- **Add a shipment** by number (also from the clipboard) – the carrier is usually detected; **rename**, mark as
  arrived (synced to all devices), remove your own shipments, open the carrier’s tracking page
- **Several Amazon accounts:** each parcel shows whose it is (customer accounts in the integration)
- **Notifications** for “arriving today”, “ready for pickup”, “delivered” and problems
- **Widgets:** iPhone (home and lock screen), Mac (desktop), Plasma (panel and desktop tile)
- **Siri & Shortcuts:** “Which parcels arrive today with Post & Pakete?”, “Track a shipment with Post & Pakete”
- German and English, light and dark, updates (one click on Mac and Linux)

## New in 2.0: Post & Pakete – one app for letters and parcels

*Post & Pakete*, *Briefankündigung Desktop* and the Scriptable widget become one app: **letters** (envelope picture,
“important”, arrived, reminders, notes) and **parcels** in one list – Today · On the way · Arrived – with
“All | Letters | Parcels”. Widgets, Siri, menu bar, Plasma widget and KRunner show both. New icon.

## Track directly – even without Home Assistant

Type, paste or **scan** a tracking number – Post & Pakete fetches status, history and map itself. Several providers are asked in
turn; if one fails, the next one steps in. Each can be switched on or off in the settings: DHL (official key),
**DHL without key** (dhl.de, fallback deutschepost.de), UPS (official), 17TRACK, Ship24, public GLS/DPD pages.

Shipments from Home Assistant without history are tracked along automatically. Plus: **Live Activity** and Dynamic Island,
**Share sheet**, **statistics**, **note and photo** per shipment, **returns**, **Apple Watch** (separate IPA), on the Mac
**drag & drop**, **⌥⌘P** from anywhere and **printing**, on Linux **KRunner**, **map**, **notifications** and **Flatpak**.

**iPhone widgets with Signulous:** Signulous drops the app group, so long-press the widget → “Edit Widget” → enter the
Home Assistant address and token; it then loads by itself.

## Parts

| | |
|---|---|
| **iPhone / iPad** | SwiftUI app with widgets, background refresh and Siri – as an IPA to install via **Signulous** (or your own signing) |
| **Mac** | the same app for macOS 14+: window with list and details, menu bar icon, desktop widgets |
| **Linux** | Kirigami app (application menu) and a **Plasma 6 widget** with a count in the panel – both share their settings |

## Requirement: Home Assistant

1. Install the **Briefankündigung** integration via HACS (**1.5** or later) and add your mailbox.
2. Under *Configure*: choose the **carriers**; optionally
   - a **17TRACK key** (api.17track.net, free: a one-time 200 shipments) for live status of Hermes, DPD, GLS, UPS,
   - a **DHL API key** (developer.dhl.com, free) for DHL live,
   - **Send notifications to** the Home Assistant app on your iPhone – the most reliable push notifications.
3. Create a **long-lived access token** (your name at the bottom left → Security).

**Parcels via “Paket Tracker” (recommended):** if the [Paket Tracker](https://github.com/SoerenKaiser99/parcel_tracker) integration (HACS) is set up, the app takes all parcels from there and adds new ones there; **Briefankündigung** then only supplies Deutsche Post letters.

Amazon, Hermes and DPD have no open API for consumers. Post & Pakete deliberately does **not** log in with your
account there – the shipping mails and 17TRACK are enough.

## Installation

**iPhone/iPad:** upload `Post & Pakete-iOS-x.y.z.ipa` from the [releases](https://github.com/Teyro/Post-und-Pakete/releases) to
Signulous and install it. Enter address and token on first start; add widgets as usual. The app shows new versions at the top.

**Mac:** download `Post & Pakete-macOS-x.y.z.zip` and move `Post & Pakete.app` to Applications. First start: right-click → Open
(the app is not notarised). Updates: menu *Post & Pakete → Check for updates*.

**Linux:** extract `paketbote-linux-x.y.z.tar.gz` and run `sh paketbote/installieren.sh` (no root needed). Then
*Post & Pakete* is in the application menu and – on Plasma 6 – in the widget list. Needs Qt 6 and Kirigami
(included with KDE Plasma). The Plasma widget installs updates with one click.

## Development

- `apple/`: `swift test` checks the core; `apple/scripts/baue.sh` builds the Mac app and the IPA (Xcode + XcodeGen)
- `linux/`: `node linux/test/logik-test.mjs`; run without installing: `qml6 -a widget linux/app/main.qml`
- `test/ha-mock.mjs`: a fake Home Assistant for tests and screenshots
- Texts: German keys, English in `i18n/en.json` (`node werkzeuge/texte.mjs`, then `node werkzeuge/baue-uebersetzungen.mjs`)

License: GPL-3.0-or-later
