import WidgetKit
import SwiftUI
import AppIntents
import PaketKern

/// Widgets von Post & Pakete für Home-Bildschirm, Sperrbildschirm (iPhone) und Schreibtisch (Mac).
@main
struct PaketboteWidgets: WidgetBundle {
    init() { Sprache.laden() }
    var body: some Widget {
        PaketeWidget()
        EinfachesWidget()
        #if os(iOS)
        PaketAktivitaetWidget()
        #endif
    }
}

/// Einstellungen des Widgets (lange drücken → „Widget bearbeiten“): eigener Zugang zu Home Assistant.
/// Nötig, wenn die App ihn nicht teilen kann (keine App-Gruppe nach dem Neu-Signieren, z. B. mit Signulous).
/// Was das Widget zeigt
enum WidgetInhaltWahl: String, AppEnum {
    case alle, briefe, pakete
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Inhalt"
    static let caseDisplayRepresentations: [WidgetInhaltWahl: DisplayRepresentation] = [
        .alle: "Briefe und Pakete", .briefe: "Nur Briefe", .pakete: "Nur Pakete",
    ]
}

struct WidgetZugang: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Post & Pakete"
    static let description = IntentDescription("Home Assistant für dieses Widget – nur nötig, wenn das Widget sonst nichts zeigt.")

    @Parameter(title: "Zeigen", default: .alle) var inhalt: WidgetInhaltWahl
    @Parameter(title: "Home-Assistant-Adresse") var adresse: String?
    @Parameter(title: "Zugriffstoken") var token: String?
    @Parameter(title: "Postfach (leer = alle)") var konto: String?

    init() {}
}

struct Eintrag: TimelineEntry {
    let date: Date
    var daten: WidgetDaten
}

struct Zeitleiste: AppIntentTimelineProvider {
    private func gespeichert() -> Eintrag {
        // nur die eigene Ablage des Widgets (bzw. die App-Gruppe) – nichts, was blockieren könnte
        let u = Ablage.lesen()
        return Eintrag(date: Date(), daten: WidgetDaten(uebersicht: u, eingerichtet: u != nil || Ablage.zugang.eingerichtet))
    }

    func placeholder(in context: Context) -> Eintrag {
        Eintrag(date: Date(), daten: WidgetDaten(uebersicht: Uebersicht(sendungen: [
            Sendung(id: "a", absender: "Laufschuhe", dienst: "hermes", stand: "heute"),
            Sendung(id: "b", absender: "Kindle", dienst: "amazon", erwartet: Texte.isoTag(Date().addingTimeInterval(86400))),
        ]), eingerichtet: true))
    }

    func snapshot(for configuration: WidgetZugang, in context: Context) async -> Eintrag {
        // in der Widget-Auswahl reicht der gespeicherte Stand; sonst gleich frisch laden
        if context.isPreview {
            var e = gespeichert()
            e.daten.inhalt = configuration.inhalt.rawValue
            return e
        }
        return await aktuell(configuration)
    }

    func timeline(for configuration: WidgetZugang, in context: Context) async -> Timeline<Eintrag> {
        let e = await aktuell(configuration)
        // um Mitternacht neu (für „kommt heute“), sonst alle 30 Minuten (nach einem Fehler schon nach 10)
        let mitternacht = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        let naechstes = Date().addingTimeInterval(e.daten.fehler.isEmpty ? 1800 : 600)
        return Timeline(entries: [e], policy: .after(min(naechstes, mitternacht)))
    }

    private func aktuell(_ configuration: WidgetZugang) async -> Eintrag {
        var e = gespeichert()
        // Zugang: aus den Einstellungen des Widgets (ohne App-Gruppe, z. B. nach Signulous) oder aus der App
        var ha = Ablage.zugang
        if let a = configuration.adresse?.trimmingCharacters(in: .whitespacesAndNewlines),
           let t = configuration.token?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty, !t.isEmpty {
            ha = HomeAssistant(adresse: a, token: t, konto: configuration.konto ?? "")
        }
        if ha.eingerichtet {
            do {
                // harte Grenze: WidgetKit beendet Widgets, die zu lange brauchen – dann bliebe nur der Platzhalter
                let h = ha
                var u = try await mitFrist(9) { try await h.laden(zeit: 8) }
                // direkt verfolgte Sendungen aus dem letzten Stand der App behalten
                let direkt = (e.daten.uebersicht?.sendungen ?? []).filter { $0.quelle == "direkt" }
                u.sendungen = zusammenfuehren(ha: u.sendungen, direkt: direkt)
                e = Eintrag(date: Date(), daten: WidgetDaten(uebersicht: u, eingerichtet: true))
                e.daten.knoepfe = true
                WidgetZugangSpeicher.merken(ha)
                Ablage.schreiben(u)
            } catch let f as HAFehler {
                e.daten.eingerichtet = true
                e.daten.fehler = f.text
            } catch {
                e.daten.eingerichtet = true
                e.daten.fehler = error.localizedDescription
            }
        }
        e.daten.inhalt = configuration.inhalt.rawValue
        return e
    }
}

/// Höchstens [sekunden] warten, sonst Fehler „nicht erreichbar“ (statt hängen zu bleiben)
func mitFrist<T: Sendable>(_ sekunden: Double, _ arbeit: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await arbeit() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(sekunden * 1_000_000_000))
            throw HAFehler(status: 0, adresse: "")
        }
        defer { g.cancelAll() }
        guard let erstes = try await g.next() else { throw HAFehler(status: 0, adresse: "") }
        return erstes
    }
}

/// Einfaches Widget ohne Einstellungen (falls das Widget mit Einstellungen auf einem neu signierten Gerät
/// nur den Platzhalter zeigt): nimmt den Zugang, den die App teilt oder den das andere Widget zuletzt benutzt hat.
struct EinfacheZeitleiste: TimelineProvider {
    func placeholder(in context: Context) -> Eintrag { Zeitleiste().placeholder(in: context) }

    func getSnapshot(in context: Context, completion: @escaping (Eintrag) -> Void) {
        let u = Ablage.lesen()
        completion(Eintrag(date: Date(), daten: WidgetDaten(uebersicht: u, eingerichtet: u != nil || Ablage.zugang.eingerichtet || WidgetZugangSpeicher.zugang.eingerichtet)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Eintrag>) -> Void) {
        Task {
            let u0 = Ablage.lesen()
            var e = Eintrag(date: Date(), daten: WidgetDaten(uebersicht: u0, eingerichtet: u0 != nil))
            let ha = Ablage.zugang.eingerichtet ? Ablage.zugang : WidgetZugangSpeicher.zugang
            if ha.eingerichtet {
                e.daten.eingerichtet = true
                do {
                    var u = try await mitFrist(9) { try await ha.laden(zeit: 8) }
                    u.sendungen = zusammenfuehren(ha: u.sendungen, direkt: (u0?.sendungen ?? []).filter { $0.quelle == "direkt" })
                    e = Eintrag(date: Date(), daten: WidgetDaten(uebersicht: u, eingerichtet: true))
                    e.daten.knoepfe = true
                    Ablage.schreiben(u)
                } catch let f as HAFehler {
                    e.daten.fehler = f.text
                } catch {
                    e.daten.fehler = error.localizedDescription
                }
            }
            let mitternacht = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
            completion(Timeline(entries: [e], policy: .after(min(Date().addingTimeInterval(e.daten.fehler.isEmpty ? 1800 : 600), mitternacht))))
        }
    }
}

struct EinfachesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "pakete-einfach", provider: EinfacheZeitleiste()) { e in
            WidgetInhalt(e: e)
        }
        .configurationDisplayName(T("Post & Pakete (einfach)"))
        .description(T("Ohne eigene Einstellungen – nutzt den Zugang der App bzw. des anderen Widgets."))
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

struct PaketeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "pakete", intent: WidgetZugang.self, provider: Zeitleiste()) { e in
            WidgetInhalt(e: e)
        }
        .configurationDisplayName(T("Post & Pakete"))
        .description(T("Angekündigte Briefe und Pakete mit voraussichtlicher Zustellung."))
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #endif
    }
}

struct WidgetInhalt: View {
    let e: Eintrag
    @Environment(\.widgetFamily) private var familie
    var body: some View {
        Group {
            switch familie {
            case .systemSmall: KleinesWidget(daten: e.daten)
            case .systemLarge, .systemExtraLarge: GrossesWidget(daten: e.daten)
            #if os(iOS)
            case .accessoryRectangular: RechteckWidget(daten: e.daten)
            case .accessoryCircular: RundWidget(daten: e.daten)
            case .accessoryInline: ZeilenWidget(daten: e.daten)
            #endif
            default: MittleresWidget(daten: e.daten)
            }
        }
        .containerBackground(for: .widget) { Color.clear.background(.background) }
    }
}
