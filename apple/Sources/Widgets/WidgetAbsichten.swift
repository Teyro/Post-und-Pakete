import AppIntents
import WidgetKit
import PaketKern

/// Zugang, den das Widget zuletzt benutzt hat (eigene Einstellungen des Widgets; für den Knopf „Angekommen“)
enum WidgetZugangSpeicher {
    static func merken(_ ha: HomeAssistant) {
        let d = UserDefaults.standard
        d.set(ha.basis, forKey: "w.adresse"); d.set(ha.token, forKey: "w.token"); d.set(ha.konto, forKey: "w.konto")
    }
    /** Zugang aus der Live-Aktivität „Widget verbinden“ übernehmen; bei Änderung die Widgets neu laden. */
    @discardableResult
    static func uebernehmen(adresse: String, token: String, konto: String) -> Bool {
        let neu = HomeAssistant(adresse: adresse, token: token, konto: konto)
        guard neu.eingerichtet else { return false }
        let alt = zugang
        guard alt.basis != neu.basis || alt.token != neu.token || alt.konto != neu.konto else { return false }
        merken(neu)
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
    static var zugang: HomeAssistant {
        let d = UserDefaults.standard
        return HomeAssistant(adresse: d.string(forKey: "w.adresse") ?? "", token: d.string(forKey: "w.token") ?? "", konto: d.string(forKey: "w.konto") ?? "")
    }
}

/// „Angekommen“ im Widget: in Home Assistant abhaken (gilt dann überall), danach zeichnet sich das Widget neu
struct WidgetAngekommen: AppIntent {
    static let title: LocalizedStringResource = "Angekommen"
    static let isDiscoverable = false

    @Parameter(title: "Sendung") var id: String

    init() {}
    init(id: String) { self.id = id }

    func perform() async throws -> some IntentResult {
        let ha = WidgetZugangSpeicher.zugang.eingerichtet ? WidgetZugangSpeicher.zugang : Ablage.zugang
        guard ha.eingerichtet else { return .result() }
        try? await ha.erledigt(id, true)
        // gleich im gespeicherten Stand vermerken, damit das Widget nicht auf die nächste Abfrage warten muss
        if var u = Ablage.lesen() {
            for i in u.sendungen.indices where u.sendungen[i].id == id { u.sendungen[i].erledigt = true }
            for i in u.briefe.indices where u.briefe[i].id == id { u.briefe[i].erledigt = true }
            Ablage.schreiben(u)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
