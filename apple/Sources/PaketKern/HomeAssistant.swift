import Foundation

/// Fehler beim Gespräch mit Home Assistant – mit Text für die Anzeige
public struct HAFehler: Error, Equatable, Sendable {
    public let status: Int
    public let text: String

    public init(status: Int, adresse: String = "") {
        self.status = status
        switch status {
        case 401, 403: text = T("Zugriff verweigert – bitte den Token prüfen.")
        case 404: text = T("Die Integration „Briefankündigung“ fehlt in Home Assistant (HACS, ab Version 1.4).")
        case 400: text = T("Sendungsnummer oder Paketdienst nicht erkannt.")
        case 405: text = T("Dafür die Integration in Home Assistant aktualisieren.")
        case 0: text = T("Home Assistant ist nicht erreichbar (%1).", adresse)
        case -1: text = T("Noch nicht eingerichtet.")
        case -2: text = T("Unerwartete Antwort von Home Assistant.")
        default: text = T("Fehler %1 von Home Assistant.", "\(status)")
        }
    }
}

/// Zugang zur Integration „Briefankündigung“ in Home Assistant (nur mit langlebigem Zugriffstoken).
public struct HomeAssistant: Sendable {
    public let basis: String
    public let token: String
    public var konto: String

    public init(adresse: String, token: String, konto: String = "") {
        basis = Texte.adresse(adresse)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.konto = konto
    }

    public var eingerichtet: Bool { !basis.isEmpty && !token.isEmpty }

    func anfrage(_ pfad: String, methode: String = "GET", koerper: [String: Any]? = nil, zeit: TimeInterval = 20) async throws -> Data {
        guard eingerichtet, let url = URL(string: basis + pfad) else { throw HAFehler(status: -1) }
        var r = URLRequest(url: url)
        r.httpMethod = methode
        r.timeoutInterval = zeit
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let koerper { r.httpBody = try? JSONSerialization.data(withJSONObject: koerper) }
        let (d, a): (Data, URLResponse)
        do { (d, a) = try await URLSession.shared.data(for: r) } catch { throw HAFehler(status: 0, adresse: basis) }
        let status = (a as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HAFehler(status: status, adresse: basis) }
        return d
    }

    /// Alle Sendungen (des gewählten Postfachs)
    /// zeit: höchstens so lange warten (Widgets haben nur wenige Sekunden)
    public func laden(zeit: TimeInterval = 20) async throws -> Uebersicht {
        let d = try await anfrage("/api/briefankuendigung/briefe", zeit: zeit)
        guard let j = JSON.lesen(d), let u = Uebersicht.aus(j) else { throw HAFehler(status: -2) }
        return u.nur(konto: konto)
    }

    /// Sendung von Hand verfolgen; dienst "" = an der Nummer erkennen
    @discardableResult
    /// standInfo (ab Integration 1.8): Stand, den dieses Gerät kennt – siehe Abgleich
    public func hinzufuegen(nummer: String, dienst: String, name: String, standInfo: [String: Any]? = nil) async throws -> String {
        var k: [String: Any] = ["nummer": nummer, "dienst": dienst, "name": name, "konto": konto]
        if let standInfo { k["stand_info"] = standInfo }
        let d = try await anfrage("/api/briefankuendigung/sendung", methode: "POST", koerper: k)
        return JSON.lesen(d)?["id"]?.text ?? ""
    }

    public func entfernen(_ id: String) async throws {
        _ = try await anfrage("/api/briefankuendigung/sendung/entfernen", methode: "POST", koerper: ["id": id])
    }

    public func umbenennen(_ id: String, _ name: String) async throws {
        _ = try await anfrage("/api/briefankuendigung/sendung/name", methode: "POST", koerper: ["id": id, "name": name])
    }

    /// Gemeinsame Notiz zu einer Sendung ("" = löschen; ab Integration 1.9)
    public func notiz(_ id: String, _ text: String) async throws {
        _ = try await anfrage("/api/briefankuendigung/notiz", methode: "POST", koerper: ["id": id, "notiz": text])
    }

    /// Bericht eines Widgets an Home Assistant (ab Integration 1.9) – wirft nie, wartet höchstens [zeit] Sekunden
    public func diagnose(quelle: String, bericht: String, zeit: TimeInterval = 4) async {
        _ = try? await anfrage("/api/briefankuendigung/diagnose", methode: "POST", koerper: ["quelle": quelle, "bericht": bericht], zeit: zeit)
    }

    /// Berichte der Widgets (neueste zuerst)
    public func diagnoseBerichte() async throws -> [(zeit: Date?, quelle: String, bericht: String)] {
        let d = try await anfrage("/api/briefankuendigung/diagnose")
        return (JSON.lesen(d)?["berichte"]?.liste ?? []).map { b in
            (b["zeit"]?.zahl.map { Date(timeIntervalSince1970: $0 / 1000) }, b["quelle"]?.text ?? "", b["bericht"]?.text ?? "")
        }
    }

    public func erledigt(_ id: String, _ erledigt: Bool) async throws {
        _ = try await anfrage("/api/briefankuendigung/erledigt", methode: "POST", koerper: ["id": id, "erledigt": erledigt])
    }

    /// Home Assistant jetzt ins Postfach schauen lassen
    public func abrufen() async throws {
        let k = konto.isEmpty ? "" : "?konto=" + (konto.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        _ = try await anfrage("/api/briefankuendigung/abrufen" + k, methode: "POST", koerper: [:])
    }
}

/// Gemeinsame Ablage von App und Widgets: Zugang und letzter Stand.
/// iPhone: App-Gruppe; Mac: Ordner unter „Application Support“ (die Widgets lesen ihn über eine Ausnahme in ihrer Sandbox).
public enum Ablage {
    public static let gruppe = "group.de.teyro.paketbote"

    public static var ordner: URL {
        #if os(iOS)
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gruppe) { return g }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #elseif os(macOS)
        // in der Sandbox der Widgets zeigt das Benutzerverzeichnis in den Container – dort den echten Pfad nehmen
        let echt = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Application Support/Paketbote", isDirectory: true)
        return echt
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }

    /// Funktioniert die App-Gruppe? (ohne sie sehen die iPhone-Widgets nichts)
    public static var gruppeDa: Bool {
        #if os(iOS)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gruppe) != nil
        #else
        true
        #endif
    }

    /// Einstellungen, die auch die Widgets brauchen
    public static var einstellungen: UserDefaults { UserDefaults(suiteName: gruppe) ?? .standard }

    static var datei: URL { ordner.appendingPathComponent("sendungen.json") }

    public static func lesen() -> Uebersicht? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: datei), let u = try? dec.decode(Uebersicht.self, from: d) { return u }
        return nil
    }

    public static func schreiben(_ u: Uebersicht) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(u) else { return }
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        try? d.write(to: datei, options: .atomic)
    }

    /// Zugang für Widgets und Kurzbefehle auf dem iPhone (in der App-Gruppe; auf dem Mac im Schlüsselbund der App)
    public static var zugang: HomeAssistant {
        let e = einstellungen
        return HomeAssistant(adresse: e.string(forKey: "adresse") ?? "", token: e.string(forKey: "token") ?? "", konto: e.string(forKey: "konto") ?? "")
    }
}
