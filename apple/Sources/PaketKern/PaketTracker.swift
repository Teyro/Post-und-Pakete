import Foundation

/// Pakete aus der Home-Assistant-Integration „Paket Tracker“ (parcel_tracker, HACS) – ersetzt die Pakete aus
/// „Briefankündigung“, die dann nur noch Briefe liefert. Gelesen wird über die normalen Zustände
/// (sensor.paket_<nummer>), geändert über die Dienste parcel_tracker.*.
public enum PaketTracker {
    /// Zustand → Stand der App
    static func stand(_ zustand: String, tageBis: Int?) -> String {
        switch zustand {
        case "out_for_delivery": return "heute"
        case "awaiting_pickup": return "abholbereit"
        case "delivered": return "zugestellt"
        default: return tageBis == 0 ? "heute" : "unterwegs"
        }
    }

    static func datum(_ t: Any?) -> Date? {
        guard let s = t as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Antwort von GET /api/states → Sendungen
    public static func sendungen(_ zustaende: [[String: Any]]) -> [Sendung] {
        zustaende.compactMap { z -> Sendung? in
            guard let id = z["entity_id"] as? String, id.hasPrefix("sensor.paket_"), let a = z["attributes"] as? [String: Any],
                  let nummer = a["number"] as? String, !nummer.isEmpty, let dienst = a["carrier"] as? String else { return nil }
            let zustand = z["state"] as? String ?? ""
            let tage = (a["days_until"] as? NSNumber)?.intValue
            let von = a["eta_from"] as? String ?? "", bis = a["eta_to"] as? String ?? ""
            var s = Sendung(id: "pt:" + nummer, datum: datum(a["last_update"]) ?? datum(z["last_changed"]) ?? Date(),
                            absender: a["name"] as? String ?? "", nummer: (a["tracking_ref"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? nummer, dienst: dienst)
            s.dienstName = (a["carrier_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Dienst.name(dienst)
            s.stand = stand(zustand, tageBis: tage)
            s.erwartet = a["eta_date"] as? String ?? ""
            s.zeitfenster = von.isEmpty ? "" : (bis.isEmpty ? von : "\(von)–\(bis)")
            s.verfolgen = a["tracking_url"] as? String ?? ""
            s.statusText = a["status_text"] as? String ?? ""
            s.problem = zustand == "exception"
            s.abholort = a["pickup_point"] as? String ?? ""
            s.abholfrist = a["pickup_until"] as? String ?? ""
            s.anbieter = "Paket Tracker"
            s.ereignisse = (a["events"] as? [[String: Any]] ?? []).map { e in
                Ereignis(zeit: datum(e["timestamp"]), text: e["text"] as? String ?? "", ort: e["location"] as? String ?? "")
            }
            return s
        }
        .sorted { $0.datum > $1.datum }
    }

    /// Nummer aus der App-Kennung („pt:<nummer>“) oder nil, wenn die Sendung nicht vom Paket Tracker kommt
    public static func nummer(_ id: String) -> String? { id.hasPrefix("pt:") ? String(id.dropFirst(3)) : nil }

    /// Paketdienst der App → parcel_tracker (unbekannt = an der Nummer erkennen)
    static func carrier(_ dienst: String) -> String { ["dhl", "dpd", "gls", "hermes", "ups"].contains(dienst) ? dienst : "auto" }
}

public extension HomeAssistant {
    /// Ist „Paket Tracker“ in Home Assistant eingerichtet? (dann kommen die Pakete von dort)
    func paketTrackerDa(zeit: TimeInterval = 8) async -> Bool {
        (try? await anfrage("/api/states/sensor.pakete_heute", zeit: zeit)) != nil
    }

    func paketTrackerSendungen(zeit: TimeInterval = 20) async throws -> [Sendung] {
        let d = try await anfrage("/api/states", zeit: zeit)
        guard let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw HAFehler(status: -2) }
        return PaketTracker.sendungen(l)
    }

    func paketTrackerDienst(_ name: String, _ daten: [String: Any]) async throws {
        _ = try await anfrage("/api/services/parcel_tracker/" + name, methode: "POST", koerper: daten)
    }
}
