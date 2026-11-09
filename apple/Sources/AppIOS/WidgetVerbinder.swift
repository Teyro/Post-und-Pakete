import ActivityKit
import Foundation
import PaketKern

/// Gibt den Widgets den Home-Assistant-Zugang, wenn es keine App-Gruppe gibt (neu signiert, z. B. Signulous):
/// kurz eine Live-Aktivität zeigen – die Widget-Erweiterung merkt sich beim Zeichnen den Zugang (WidgetVerbindung).
@MainActor
enum WidgetVerbinder {
    private static let merker = "widgetVerbundenMit"

    private static func signatur(_ e: Einstellungen) -> String { "\(e.adresse)|\(e.konto)|\(e.token.count)|\(e.token.suffix(6))" }

    /// Beim Öffnen der App: einmal je Zugang von selbst verbinden (nur ohne App-Gruppe)
    static func beiBedarf(_ kern: Kern) async {
        let e = kern.einstellungen
        guard !Ablage.gruppeDa, e.eingerichtet, UserDefaults.standard.string(forKey: merker) != signatur(e) else { return }
        await verbinden(kern, still: true)
    }

    @discardableResult
    static func verbinden(_ kern: Kern, still: Bool = false) async -> Bool {
        let e = kern.einstellungen
        guard e.eingerichtet else {
            if !still { kern.meldung = T("Zuerst Home Assistant eintragen.") }
            return false
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !still { kern.meldung = T("Live-Aktivitäten sind aus – iPhone-Einstellungen → Post & Pakete → Live-Aktivitäten erlauben.") }
            return false
        }
        do {
            let a = WidgetVerbindung(adresse: e.adresse, token: e.token, konto: e.konto)
            let aktivitaet = try Activity.request(attributes: a, content: ActivityContent(state: .init(fertig: true), staleDate: nil))
            // kurz stehen lassen, damit iOS sie sicher einmal zeichnet
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await aktivitaet.end(nil, dismissalPolicy: .immediate)
            UserDefaults.standard.set(signatur(e), forKey: merker)
            if !still { kern.meldung = T("Widget verbunden – es lädt gleich neu.") }
            return true
        } catch {
            if !still { kern.meldung = T("Verbinden hat nicht geklappt: %1", error.localizedDescription) }
            return false
        }
    }
}
