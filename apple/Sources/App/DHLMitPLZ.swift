import Foundation
import WebKit
import PaketKern

/// Mehr von DHL mit der Postleitzahl des Empfängers (wie auf dhl.de nach „PLZ eingeben“): Absender, Empfänger,
/// Orte im Verlauf, Zustellung. dhl.de lässt diese Abfrage nur aus einem echten Browser zu (Bot-Schutz) –
/// darum läuft sie in einer unsichtbaren Web-Ansicht auf dhl.de selbst.
/// shortcut: hängt an der internen Schnittstelle von dhl.de (/int-verfolgen/data/shipment) – ändert DHL sie, bleibt es still beim Stand ohne PLZ.
@MainActor
final class DHLMitPLZ: NSObject, WKNavigationDelegate {
    struct Mehr: Codable, Hashable {
        var absender = ""
        var empfaenger = ""
        var erwartet = ""
        var zeitfenster = ""
        var ereignisse: [Ereignis] = []
        var stand = ""
        /// Live-Verfolgung am Zustelltag: „Nur noch 4 Zustellstopps“ (leer = keine)
        var live = ""
        var liveZeit: Date?
    }

    private var ansicht: WKWebView?
    private var geladen: CheckedContinuation<Bool, Never>?

    /// Gemerkte Ergebnisse (Sendungsnummer → Mehr), damit die Ansicht sofort etwas zeigt
    static func gemerkt(_ nummer: String) -> Mehr? {
        guard let d = UserDefaults.standard.data(forKey: "dhlMehr." + nummer) else { return nil }
        return try? JSONDecoder().decode(Mehr.self, from: d)
    }
    private static func merken(_ m: Mehr, _ nummer: String) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: "dhlMehr." + nummer) }
    }

    func abfragen(nummer: String, plz: String) async -> Mehr? {
        guard nummer.count >= 8, plz.count == 5, plz.allSatisfy(\.isNumber) else { return nil }
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), configuration: WKWebViewConfiguration())
        w.navigationDelegate = self
        ansicht = w
        defer { ansicht = nil }
        guard let start = URL(string: "https://www.dhl.de/de/privatkunden/dhl-sendungsverfolgung.html") else { return nil }
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            geladen = c
            w.load(URLRequest(url: start, timeoutInterval: 20))
        }
        guard ok else { return nil }
        // dem Bot-Schutz der Seite kurz Zeit lassen
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let skript = """
        const opt = { credentials: 'same-origin' };
        const c = await (await fetch('/int-verfolgen/data/config?domain=de&language=de', opt)).json();
        const t = c.verfolgenCsrfToken || '';
        const k = { 'verfolgen-CSRF-token': t };
        await fetch('/int-verfolgen/data/search?piececode=' + encodeURIComponent(nummer) + '&noRedirect=true&language=de', { ...opt, headers: k });
        const r = await fetch('/int-verfolgen/data/shipment?language=de', { ...opt, method: 'POST',
            headers: { ...k, 'Content-Type': 'application/json' }, body: JSON.stringify({ piececode: nummer, zip: plz, international: false }) });
        return await r.text();
        """
        guard let text = try? await w.callAsyncJavaScript(skript, arguments: ["nummer": nummer, "plz": plz], contentWorld: .page) as? String,
              let j = JSON.lesen(Data(text.utf8)), let s = j["sendungen"]?[0], s["sendungsdetails"] != nil else { return nil }
        let m = Self.auswerten(s)
        Self.merken(m, nummer)
        return m
    }

    /// Aus der Antwort: Verlauf und Termin wie ohne PLZ, dazu Absender/Empfänger (Namen schwanken – darum suchen)
    static func auswerten(_ s: JSON) -> Mehr {
        let spur = DHLOeffentlichAnbieter.lesen(s)
        var m = Mehr(erwartet: spur.erwartet, zeitfenster: spur.zeitfenster, ereignisse: spur.ereignisse, stand: spur.stand)
        let d = s["sendungsdetails"]
        // feste Namen (wie dhl.de sie liest), sonst suchen
        m.absender = d?["versender"]?["name"]?.text ?? suche(s, schluessel: ["absender", "versender", "shipper", "sender"])
        if let e = d?["zustellung"]?["empfaenger"] {
            m.empfaenger = e.text ?? suche(JSON.objekt(["empfaenger": e]), schluessel: ["empfaenger"])
        }
        if m.empfaenger.isEmpty { m.empfaenger = suche(s, schluessel: ["empfaenger", "empfänger", "recipient", "zustelladresse", "adressiertan"]) }
        if let l = d?["liveTracking"] { m.live = liveText(l); m.liveZeit = m.live.isEmpty ? nil : Date() }
        return m
    }

    /// liveTracking {state, authorized, countdownTextKey "CD01"…"CD50", countdown} → Text wie auf dhl.de
    static func liveText(_ l: JSON) -> String {
        let zustand = (l["state"]?.text ?? "").lowercased()
        guard zustand == "ok" || zustand == "reduced", l["authorized"]?.bool != false else { return "" }
        let n = l["countdown"]?.zahl.map { Int($0) } ?? l["countdown"]?.text.flatMap { Int($0) }
        switch l["countdownTextKey"]?.text ?? "" {
        case "CD01": return T("Nur noch 1 Zustellstopp")
        case "CD02": return n.map { T("Nur noch %1 Zustellstopps", "\($0)") } ?? T("Nur noch wenige Zustellstopps")
        case "CD10": return T("Noch etwas mehr als %1 Zustellstopps", "10")
        case "CD20": return T("Noch etwas mehr als %1 Zustellstopps", "20")
        case "CD30": return T("Noch etwas mehr als %1 Zustellstopps", "30")
        case "CD40": return T("Noch etwas mehr als %1 Zustellstopps", "40")
        case "CD50": return T("Noch etwas mehr als %1 Zustellstopps", "50")
        default: return n.map { T("Nur noch %1 Zustellstopps", "\($0)") } ?? ""
        }
    }

    /// Erstes Objekt/Textfeld, dessen Name einen der Schlüssel enthält → „Name, PLZ Ort“
    static func suche(_ j: JSON, schluessel: [String], tiefe: Int = 0) -> String {
        guard tiefe < 6, let o = j.objekt else {
            if tiefe < 6, let l = j.liste { for x in l { let t = suche(x, schluessel: schluessel, tiefe: tiefe + 1); if !t.isEmpty { return t } } }
            return ""
        }
        for (k, w) in o.sorted(by: { $0.key < $1.key }) where schluessel.contains(where: { k.lowercased().contains($0) }) {
            if let t = w.text, !t.isEmpty, t.count < 120, !t.contains("http") { return t }
            if let u = w.objekt {
                let teile = ["name", "name1", "name2", "firma", "strasse", "plz", "postleitzahl", "ort", "stadt", "city"].compactMap { u[$0]?.text }.filter { !$0.isEmpty }
                if !teile.isEmpty { return teile.joined(separator: " ") }
            }
        }
        for (_, w) in o.sorted(by: { $0.key < $1.key }) {
            let t = suche(w, schluessel: schluessel, tiefe: tiefe + 1)
            if !t.isEmpty { return t }
        }
        return ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { geladen?.resume(returning: true); geladen = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { geladen?.resume(returning: false); geladen = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { geladen?.resume(returning: false); geladen = nil }
}
