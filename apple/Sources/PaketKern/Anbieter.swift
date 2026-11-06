import Foundation

// Direkt verfolgen – ohne Home Assistant: Die App fragt selbst nach. Mehrere Anbieter hintereinander:
// fällt einer aus (Fehler, Kontingent leer, kennt die Nummer nicht), springt der nächste ein.
//   1. DHL (offizielle Schnittstelle, eigener kostenloser Schlüssel)       – DHL, Deutsche Post
//   2. UPS (offizielle Schnittstelle, eigenes Entwicklerkonto)            – UPS
//   3. 17TRACK (Schlüssel)                                                 – fast alle Dienste
//   4. Ship24 (Schlüssel)                                                  – fast alle Dienste
//   5. Öffentliche Verfolgungsseiten von GLS und DPD (ohne Schlüssel, inoffiziell – Notnagel)

/// Ergebnis einer Abfrage, gleich für alle Anbieter
public struct Spur: Codable, Hashable, Sendable {
    public var stand: String = "unterwegs"
    public var erwartet: String = ""
    public var zeitfenster: String = ""
    public var text: String = ""
    public var ereignisse: [Ereignis] = []
    public var problem = false
    /// zugestellt oder abgelaufen – nicht mehr abfragen
    public var ende = false
    /// Wer geantwortet hat (z. B. "17TRACK")
    public var quelle: String = ""

    public init() {}

    /// Leere Antwort (Anbieter kennt die Nummer noch nicht)
    public var leer: Bool { ereignisse.isEmpty && text.isEmpty && erwartet.isEmpty }
}

/// Schlüssel der Anbieter (in den Einstellungen der App)
public struct Schluessel: Codable, Hashable, Sendable {
    public var dhl = ""
    public var upsId = ""
    public var upsGeheim = ""
    public var siebzehn = ""
    public var ship24 = ""
    /// Öffentliche Seiten (DHL/Deutsche Post ohne Schlüssel, GLS, DPD) fragen
    public var oeffentlich = true
    /// Abgeschaltete Anbieter (Namen, z. B. "Ship24")
    public var aus: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case dhl, upsId, upsGeheim, siebzehn, ship24, oeffentlich, aus }

    // ältere Stände kennen nicht alle Felder – fehlende bleiben beim Standard
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dhl = try c.decodeIfPresent(String.self, forKey: .dhl) ?? ""
        upsId = try c.decodeIfPresent(String.self, forKey: .upsId) ?? ""
        upsGeheim = try c.decodeIfPresent(String.self, forKey: .upsGeheim) ?? ""
        siebzehn = try c.decodeIfPresent(String.self, forKey: .siebzehn) ?? ""
        ship24 = try c.decodeIfPresent(String.self, forKey: .ship24) ?? ""
        oeffentlich = try c.decodeIfPresent(Bool.self, forKey: .oeffentlich) ?? true
        aus = try c.decodeIfPresent([String].self, forKey: .aus) ?? []
    }

    public func an(_ name: String) -> Bool { !aus.contains(name) }
    public mutating func setzen(_ name: String, _ an: Bool) {
        aus.removeAll { $0 == name }
        if !an { aus.append(name) }
    }
}

public enum AnbieterFehler: Error, Equatable, Sendable {
    case keinSchluessel, unbekannt, abgelehnt, kontingent, netz, antwort(String)
}

/// Ein Anbieter für Sendungsverfolgung
public protocol Anbieter: Sendable {
    var name: String { get }
    func kann(_ dienst: String, _ s: Schluessel) -> Bool
    func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur
}

/// Kette mehrerer Anbieter – der erste mit brauchbarer Antwort gewinnt
public struct Verfolgung: Sendable {
    public var anbieter: [any Anbieter]
    public var schluessel: Schluessel

    public init(schluessel: Schluessel, anbieter: [any Anbieter] = Verfolgung.standard) {
        self.schluessel = schluessel
        self.anbieter = anbieter
    }

    public static let standard: [any Anbieter] = [DHLAnbieter(), DHLOeffentlichAnbieter(), UPSAnbieter(), SiebzehnAnbieter(), Ship24Anbieter(),
                                                  GLSAnbieter(), DPDAnbieter()]

    /// Alle Anbieter mit Beschreibung (für die Auswahl in den Einstellungen)
    public static let beschreibung: [(name: String, text: String)] = [
        ("DHL", T("Offizielle DHL-Schnittstelle – eigener kostenloser Schlüssel")),
        ("DHL (ohne Schlüssel)", T("DHL und Deutsche Post über die öffentliche Sendungsverfolgung – zwei Adressen als Ersatz")),
        ("UPS", T("Offizielle UPS-Schnittstelle – eigener kostenloser Zugang")),
        ("17TRACK", T("Fast alle Dienste – Schlüssel, 200 Sendungen frei")),
        ("Ship24", T("Fast alle Dienste – Schlüssel")),
        ("GLS (öffentlich)", T("Öffentliche GLS-Seite – inoffiziell")),
        ("DPD (öffentlich)", T("Öffentliche DPD-Seite – inoffiziell")),
    ]

    /// Welche Anbieter kämen für diesen Dienst in Frage (für die Anzeige „über DHL, Ersatz: 17TRACK“)
    public func moeglich(_ dienst: String) -> [String] { anbieter.filter { schluessel.an($0.name) && $0.kann(dienst, schluessel) }.map(\.name) }

    /// Abfragen; gibt die Spur und die Fehler der übersprungenen Anbieter zurück
    public func abfragen(_ nummer: String, dienst: String) async -> (spur: Spur?, fehler: [String: AnbieterFehler]) {
        var fehler: [String: AnbieterFehler] = [:]
        var leer: Spur?
        for a in anbieter where schluessel.an(a.name) && a.kann(dienst, schluessel) {
            do {
                var s = try await a.abfragen(nummer, dienst: dienst, schluessel: schluessel)
                s.quelle = a.name
                if !s.leer { return (s, fehler) }
                leer = leer ?? s
                fehler[a.name] = .unbekannt
            } catch let f as AnbieterFehler {
                fehler[a.name] = f
            } catch {
                fehler[a.name] = .netz
            }
        }
        return (leer, fehler)
    }
}

// MARK: - Hilfen

enum Netz {
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) PostUndPakete/2.0"

    static func json(_ url: URL, methode: String = "GET", kopf: [String: String] = [:], koerper: Data? = nil) async throws -> JSON {
        var r = URLRequest(url: url)
        r.httpMethod = methode
        r.timeoutInterval = 20
        r.setValue(agent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in kopf { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = koerper
        let (d, a): (Data, URLResponse)
        do { (d, a) = try await URLSession.shared.data(for: r) } catch { throw AnbieterFehler.netz }
        switch (a as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: break
        case 401, 403: throw AnbieterFehler.abgelehnt
        case 404: throw AnbieterFehler.unbekannt
        case 429: throw AnbieterFehler.kontingent
        case let s: throw AnbieterFehler.antwort("HTTP \(s)")
        }
        guard let j = JSON.lesen(d) else { throw AnbieterFehler.antwort(String(decoding: d.prefix(80), as: UTF8.self)) }
        return j
    }

    static func iso(_ d: Date?) -> String {
        guard let d else { return "" }
        return Texte.isoTag(d, kalender: Calendar(identifier: .gregorian))
    }

    /// "2026-10-23T…" bzw. "20261023" → "2026-10-23"
    static func tag(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.count == 8, s.allSatisfy(\.isNumber) { return "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.suffix(2))" }
        return s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(s[$0]) } ?? ""
    }

    static func sortiert(_ e: [Ereignis]) -> [Ereignis] {
        var gesehen = Set<String>()
        return e.filter { gesehen.insert($0.id).inserted }.sorted { ($0.zeit ?? .distantPast) > ($1.zeit ?? .distantPast) }
    }

    /// Stand aus einem Freitext erraten (für Anbieter ohne feste Codes)
    static func standAusText(_ t: String) -> String {
        let s = t.lowercased()
        let nicht = s.contains("nicht zugestellt") || s.contains("konnte nicht") || s.contains("not delivered")
        if !nicht && (s.contains("zugestellt") || s.contains("delivered") || s.contains("ausgeliefert") || s.contains("abgeholt") || s.contains("abholung aus")) {
            return "zugestellt"
        }
        if s.contains("zur abholung") || s.contains("abholbereit") || s.contains("liegt in der packstation") || s.contains("liegt in der filiale")
            || s.contains("pickup") || s.contains("paketshop") { return "abholbereit" }
        if nicht { return "unterwegs" }
        if s.contains("in zustellung") || s.contains("zustellfahrzeug") || s.contains("out for delivery") || s.contains("wird heute") { return "heute" }
        return "unterwegs"
    }
}

// MARK: - DHL (Shipment Tracking – Unified)

public struct DHLAnbieter: Anbieter {
    public init() {}
    public var name: String { "DHL" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { !s.dhl.isEmpty && (dienst == "dhl" || dienst.isEmpty) }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        var u = URLComponents(string: "https://api-eu.dhl.com/track/shipments")!
        u.queryItems = [URLQueryItem(name: "trackingNumber", value: nummer), URLQueryItem(name: "language", value: Sprache.code == "de" ? "de" : "en")]
        let j = try await Netz.json(u.url!, kopf: ["DHL-API-Key": schluessel.dhl])
        guard let s = j["shipments"]?[0] else { throw AnbieterFehler.unbekannt }
        return Self.lesen(s)
    }

    static func lesen(_ s: JSON) -> Spur {
        var spur = Spur()
        let code = s["status"]?["statusCode"]?.text?.lowercased() ?? ""
        spur.text = s["status"]?["description"]?.text ?? s["status"]?["status"]?.text ?? ""
        spur.stand = code == "delivered" ? "zugestellt" : Netz.standAusText(spur.text)
        spur.problem = code == "failure"
        spur.ende = code == "delivered"
        spur.erwartet = Netz.tag(s["estimatedTimeOfDelivery"]?.text)
        if let von = s["estimatedTimeFrame"]?["estimatedFrom"]?.text, let bis = s["estimatedTimeFrame"]?["estimatedThrough"]?.text,
           let a = Uebersicht.isoZeit(von), let b = Uebersicht.isoZeit(bis) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            spur.zeitfenster = f.string(from: a) + "–" + f.string(from: b)
        }
        spur.ereignisse = Netz.sortiert((s["events"]?.liste ?? []).compactMap { e in
            guard let t = e["description"]?.text ?? e["status"]?.text, !t.isEmpty else { return nil }
            return Ereignis(zeit: e["timestamp"]?.text.flatMap(Uebersicht.isoZeit), text: t,
                            ort: e["location"]?["address"]?["addressLocality"]?.text ?? "")
        })
        return spur
    }
}

// MARK: - DHL ohne Schlüssel (öffentliche Sendungsverfolgung; dhl.de, ersatzweise deutschepost.de)

public struct DHLOeffentlichAnbieter: Anbieter {
    public init() {}
    public var name: String { "DHL (ohne Schlüssel)" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { s.oeffentlich && (dienst == "dhl" || dienst.isEmpty) }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        let n = nummer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nummer
        let sprache = Sprache.code == "de" ? "de" : "en"
        var letzter: Error = AnbieterFehler.netz
        for host in ["www.dhl.de", "www.deutschepost.de"] {
            do {
                let j = try await Netz.json(URL(string: "https://\(host)/int-verfolgen/data/search?piececode=\(n)&language=\(sprache)")!)
                guard let s = j["sendungen"]?[0], s["sendungsdetails"] != nil else { throw AnbieterFehler.unbekannt }
                return Self.lesen(s)
            } catch {
                letzter = error
            }
        }
        throw letzter
    }

    public static func lesen(_ s: JSON) -> Spur {
        var spur = Spur()
        let d = s["sendungsdetails"], v = d?["sendungsverlauf"]
        spur.ereignisse = Netz.sortiert((v?["events"]?.liste ?? []).compactMap { e in
            guard let t = e["status"]?.text, !t.isEmpty else { return nil }
            return Ereignis(zeit: e["datum"]?.text.flatMap(Uebersicht.isoZeit), text: t.replacingOccurrences(of: "  ", with: " "), ort: e["ort"]?.text ?? "")
        })
        spur.text = v?["status"]?.text ?? spur.ereignisse.first?.text ?? ""
        let zugestellt = d?["istZugestellt"]?.bool ?? false
        spur.stand = zugestellt ? "zugestellt" : Netz.standAusText(spur.ereignisse.first?.text ?? spur.text)
        if !zugestellt && spur.stand == "zugestellt" { spur.stand = Netz.standAusText(spur.text) }
        spur.ende = zugestellt
        // Voraussichtliche Zustellung: zustellung.zustellzeitfensterVon/Bis ("2026-11-07" oder mit Uhrzeit)
        if !zugestellt, let von = d?["zustellung"]?["zustellzeitfensterVon"]?.text, von.count >= 10, von.prefix(10).filter({ $0 == "-" }).count == 2 {
            spur.erwartet = String(von.prefix(10))
            if let bis = d?["zustellung"]?["zustellzeitfensterBis"]?.text, von.contains("T"), bis.contains("T"), bis.prefix(10) == von.prefix(10), von.count >= 16, bis.count >= 16 {
                spur.zeitfenster = "\(von.dropFirst(11).prefix(5))–\(bis.dropFirst(11).prefix(5))"
            }
        }
        // sonst: andere Felder unter "zustellung" – Namen schwanken, darum suchen
        if spur.erwartet.isEmpty, !zugestellt, let z = d?["zustellung"]?.objekt {
            for (k, w) in z {
                let k2 = k.lowercased()
                if spur.erwartet.isEmpty, k2.contains("datum") || k2.contains("tag"), let t = w.text { spur.erwartet = Netz.tag(t) }
                if k2.contains("zeitfenster"), let o = w.objekt, let von = o["von"]?.text ?? o["start"]?.text, let bis = o["bis"]?.text ?? o["ende"]?.text {
                    spur.zeitfenster = "\(von.suffix(5))–\(bis.suffix(5))"
                }
            }
        }
        return spur
    }
}

// MARK: - UPS (Tracking API, OAuth)

public struct UPSAnbieter: Anbieter {
    public init() {}
    public var name: String { "UPS" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { !s.upsId.isEmpty && !s.upsGeheim.isEmpty && dienst == "ups" }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        // Zugang holen (Client-Credentials)
        let anmeldung = Data("\(schluessel.upsId):\(schluessel.upsGeheim)".utf8).base64EncodedString()
        let t = try await Netz.json(URL(string: "https://onlinetools.ups.com/security/v1/oauth/token")!, methode: "POST",
                                    kopf: ["Authorization": "Basic " + anmeldung, "Content-Type": "application/x-www-form-urlencoded"],
                                    koerper: Data("grant_type=client_credentials".utf8))
        guard let token = t["access_token"]?.text else { throw AnbieterFehler.abgelehnt }
        let n = nummer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nummer
        let j = try await Netz.json(URL(string: "https://onlinetools.ups.com/api/track/v1/details/\(n)?locale=\(Sprache.code == "de" ? "de_DE" : "en_US")")!,
                                    kopf: ["Authorization": "Bearer " + token, "transId": UUID().uuidString, "transactionSrc": "PostUndPakete"])
        guard let p = j["trackResponse"]?["shipment"]?[0]?["package"]?[0] else { throw AnbieterFehler.unbekannt }
        return Self.lesen(p)
    }

    static func lesen(_ p: JSON) -> Spur {
        var spur = Spur()
        let typ = p["currentStatus"]?["type"]?.text ?? p["activity"]?[0]?["status"]?["type"]?.text ?? ""
        spur.text = p["currentStatus"]?["description"]?.text ?? p["activity"]?[0]?["status"]?["description"]?.text ?? ""
        switch typ {
        case "D": spur.stand = "zugestellt"; spur.ende = true
        case "X": spur.problem = true; spur.stand = Netz.standAusText(spur.text)
        default: spur.stand = Netz.standAusText(spur.text)
        }
        let termin = (p["deliveryDate"]?.liste ?? []).first { ["SDD", "RDD", "DEL"].contains($0["type"]?.text ?? "") } ?? p["deliveryDate"]?[0]
        spur.erwartet = Netz.tag(termin?["date"]?.text)
        if let von = p["deliveryTime"]?["startTime"]?.text, let bis = p["deliveryTime"]?["endTime"]?.text, von.count >= 4, bis.count >= 4 {
            spur.zeitfenster = "\(von.prefix(2)):\(von.dropFirst(2).prefix(2))–\(bis.prefix(2)):\(bis.dropFirst(2).prefix(2))"
        }
        spur.ereignisse = Netz.sortiert((p["activity"]?.liste ?? []).compactMap { a in
            guard let t = a["status"]?["description"]?.text, !t.isEmpty else { return nil }
            let tag = a["date"]?.text ?? "", zeit = a["time"]?.text ?? "000000"
            let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let adr = a["location"]?["address"]
            let ort = [adr?["city"]?.text?.capitalized, adr?["countryCode"]?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return Ereignis(zeit: f.date(from: tag + zeit.padding(toLength: 6, withPad: "0", startingAt: 0)), text: t.capitalizedErsterBuchstabe, ort: ort)
        })
        return spur
    }
}

extension String {
    /// „IN ZUSTELLUNG“ → „In zustellung“ (UPS schreibt oft alles groß)
    var capitalizedErsterBuchstabe: String {
        guard self == uppercased(), count > 3 else { return self }
        return prefix(1) + dropFirst().lowercased()
    }
}

// MARK: - 17TRACK

public struct SiebzehnAnbieter: Anbieter {
    public init() {}
    public var name: String { "17TRACK" }
    public static let kennung: [String: Int] = ["dhl": 7041, "hermes": 100031, "dpd": 100007, "gls": 101070, "ups": 100002]
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { !s.siebzehn.isEmpty && dienst != "amazon" }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        let kopf = ["17token": schluessel.siebzehn, "Content-Type": "application/json"]
        var eintrag: [String: Any] = ["number": nummer]
        if let k = Self.kennung[dienst] { eintrag["carrier"] = k }
        let koerper = try JSONSerialization.data(withJSONObject: [eintrag])
        let basis = "https://api.17track.net/track/v2.2/"
        // erst anmelden (schon angemeldet ist kein Fehler), dann abfragen
        let r = try await Netz.json(URL(string: basis + "register")!, methode: "POST", kopf: kopf, koerper: koerper)
        if let fehler = r["data"]?["rejected"]?[0]?["error"]?["code"]?.zahl, Int(fehler) != -18019901 {
            throw Int(fehler) == -18019904 ? AnbieterFehler.kontingent : AnbieterFehler.unbekannt
        }
        let j = try await Netz.json(URL(string: basis + "gettrackinfo")!, methode: "POST", kopf: kopf, koerper: koerper)
        guard let info = j["data"]?["accepted"]?[0]?["track_info"] else { throw AnbieterFehler.unbekannt }
        return Self.lesen(info)
    }

    static func lesen(_ info: JSON) -> Spur {
        var spur = Spur()
        let status = info["latest_status"]?["status"]?.text ?? ""
        spur.stand = ["Delivered": "zugestellt", "AvailableForPickup": "abholbereit", "OutForDelivery": "heute"][status] ?? "unterwegs"
        spur.ende = status == "Delivered" || status == "Expired"
        spur.problem = status == "DeliveryFailure" || status == "Exception"
        let letztes = info["latest_event"]
        spur.text = letztes?["description_translation"]?["description"]?.text ?? letztes?["description"]?.text ?? ""
        let s = info["time_metrics"]?["estimated_delivery_date"]
        spur.erwartet = Netz.tag(s?["from"]?.text ?? s?["to"]?.text)
        var alle: [Ereignis] = []
        for p in info["tracking"]?["providers"]?.liste ?? [] {
            for e in p["events"]?.liste ?? [] {
                guard let t = e["description_translation"]?["description"]?.text ?? e["description"]?.text, !t.isEmpty else { continue }
                alle.append(Ereignis(zeit: (e["time_iso"]?.text ?? e["time_utc"]?.text).flatMap(Uebersicht.isoZeit), text: t, ort: e["location"]?.text ?? ""))
            }
        }
        spur.ereignisse = Netz.sortiert(alle)
        return spur
    }
}

// MARK: - Ship24

public struct Ship24Anbieter: Anbieter {
    public init() {}
    public var name: String { "Ship24" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { !s.ship24.isEmpty }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        let koerper = try JSONSerialization.data(withJSONObject: ["trackingNumber": nummer])
        let j = try await Netz.json(URL(string: "https://api.ship24.com/public/v1/trackers/track")!, methode: "POST",
                                    kopf: ["Authorization": "Bearer " + schluessel.ship24, "Content-Type": "application/json; charset=utf-8"], koerper: koerper)
        guard let t = j["data"]?["trackings"]?[0] else { throw AnbieterFehler.unbekannt }
        return Self.lesen(t)
    }

    static func lesen(_ t: JSON) -> Spur {
        var spur = Spur()
        let m = t["shipment"]?["statusMilestone"]?.text ?? ""
        spur.stand = ["delivered": "zugestellt", "available_for_pickup": "abholbereit", "out_for_delivery": "heute"][m] ?? "unterwegs"
        spur.ende = m == "delivered"
        spur.problem = m == "exception" || m == "failed_attempt"
        spur.erwartet = Netz.tag(t["shipment"]?["delivery"]?["estimatedDeliveryDate"]?.text)
        spur.ereignisse = Netz.sortiert((t["events"]?.liste ?? []).compactMap { e in
            guard let s = e["status"]?.text, !s.isEmpty else { return nil }
            return Ereignis(zeit: e["occurrenceDatetime"]?.text.flatMap(Uebersicht.isoZeit), text: s, ort: e["location"]?.text ?? "")
        })
        spur.text = spur.ereignisse.first?.text ?? ""
        return spur
    }
}

// MARK: - Öffentliche Seiten (inoffiziell, ohne Schlüssel)

public struct GLSAnbieter: Anbieter {
    public init() {}
    public var name: String { "GLS (öffentlich)" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { s.oeffentlich && dienst == "gls" }
    static let hosts = ["gls-group.com", "gls-group.eu"]

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        let n = nummer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nummer
        var letzter: Error = AnbieterFehler.netz
        for h in Self.hosts {
            do {
                let j = try await Netz.json(URL(string: "https://\(h)/app/service/open/rest/DE/de/rstt001?match=\(n)")!)
                guard let tu = j["tuStatus"]?[0] else { throw AnbieterFehler.unbekannt }
                return Self.lesen(tu)
            } catch { letzter = error }
        }
        throw letzter
    }

    static func lesen(_ tu: JSON) -> Spur {
        var spur = Spur()
        let info = tu["progressBar"]?["statusInfo"]?.text?.uppercased() ?? ""
        spur.ereignisse = Netz.sortiert((tu["history"]?.liste ?? []).compactMap { h in
            guard let t = h["evtDscr"]?.text, !t.isEmpty else { return nil }
            let zeit = Uebersicht.isoZeit("\(h["date"]?.text ?? "")T\(h["time"]?.text ?? "00:00:00")")
            let ort = [h["address"]?["city"]?.text, h["address"]?["countryName"]?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return Ereignis(zeit: zeit, text: t, ort: ort)
        })
        spur.text = spur.ereignisse.first?.text ?? ""
        spur.stand = info == "DELIVERED" ? "zugestellt" : info == "INDELIVERY" ? "heute" : Netz.standAusText(spur.text)
        spur.ende = info == "DELIVERED"
        return spur
    }
}

public struct DPDAnbieter: Anbieter {
    public init() {}
    public var name: String { "DPD (öffentlich)" }
    public func kann(_ dienst: String, _ s: Schluessel) -> Bool { s.oeffentlich && dienst == "dpd" }

    public func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur {
        let n = nummer.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? nummer
        let j = try await Netz.json(URL(string: "https://tracking.dpd.de/rest/plc/\(Sprache.code == "de" ? "de_DE" : "en_US")/\(n)")!)
        guard let d = j["parcellifecycleResponse"]?["parcelLifeCycleData"] else { throw AnbieterFehler.unbekannt }
        return Self.lesen(d)
    }

    static func lesen(_ d: JSON) -> Spur {
        var spur = Spur()
        let infos = d["statusInfo"]?.liste ?? []
        let aktuell = infos.last { $0["isCurrentStatus"]?.bool == true } ?? infos.last { $0["statusHasBeenReached"]?.bool == true }
        let status = aktuell?["status"]?.text ?? ""
        spur.text = aktuell?["label"]?.text ?? ""
        spur.stand = status == "DELIVERED" ? "zugestellt" : status == "COURIER" || status == "OUT_FOR_DELIVERY" ? "heute"
            : status == "PICKUP" ? "abholbereit" : Netz.standAusText(spur.text)
        spur.ende = status == "DELIVERED"
        spur.ereignisse = Netz.sortiert((d["scanInfo"]?["scan"]?.liste ?? []).compactMap { s in
            let t = (s["scanDescription"]?["content"]?.liste ?? []).compactMap(\.text).joined(separator: " ")
            guard !t.isEmpty else { return nil }
            return Ereignis(zeit: s["date"]?.text.flatMap(Uebersicht.isoZeit), text: t, ort: s["scanData"]?["location"]?.text ?? "")
        })
        if spur.ereignisse.isEmpty {
            spur.ereignisse = Netz.sortiert(infos.filter { $0["statusHasBeenReached"]?.bool == true }.compactMap { i in
                guard let t = i["label"]?.text else { return nil }
                return Ereignis(zeit: i["date"]?.text.flatMap(Uebersicht.isoZeit), text: t, ort: i["location"]?.text ?? "")
            })
        }
        return spur
    }
}
