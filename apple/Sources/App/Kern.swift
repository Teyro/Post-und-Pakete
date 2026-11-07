import Foundation
import Observation
import SwiftUI
import UserNotifications
import WidgetKit
import Security
import EventKit
import PaketKern
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Zustand der App: Zugang, Sendungen (aus Home Assistant und direkt verfolgt), Aktionen. Gemeinsam für iPhone und Mac.
@MainActor
@Observable
final class Kern {
    static let shared = Kern()

    /// Testlauf für die Bildschirmfotos (GitHub Actions): `--vorschau` mit PB_ADRESSE, PB_TOKEN
    let vorschau = CommandLine.arguments.contains("--vorschau")
    let einstellungen: Einstellungen
    /// Stand aus Home Assistant
    private(set) var daten: Uebersicht?
    /// Direkt verfolgte Sendungen, Notizen
    private(set) var direkt = DirektListe.laden()
    private(set) var laedt = false
    private(set) var fehler = ""
    /// Fehler der Anbieter beim letzten direkten Abruf (Anbieter → Text)
    private(set) var anbieterFehler: [String: String] = [:]
    /// Mehr von DHL mit der Postleitzahl (Sendungsnummer → Absender, Empfänger, Orte)
    private(set) var mehr: [String: DHLMitPLZ.Mehr] = [:]
    @ObservationIgnored private var mehrZeit: [String: Date] = [:]
    /// Kurze Meldung (z. B. „Hinzugefügt“ oder ein Fehler bei einer Aktion)
    var meldung = ""
    /// Gewählte Sendung (Liste → Detail; auch aus Widgets und Mitteilungen)
    var auswahl: String?
    var hinzufuegenOffen = false
    /// Vorgabe fürs Hinzufügen (aus Teilen-Menü, Scanner, Ziehen auf den Mac)
    var hinzufuegenNummer = ""
    var einstellungenOffen = false
    var statistikOffen = false
    /// Wird nach jedem Laden aufgerufen (iPhone: Live-Aktivitäten, Uhr)
    @ObservationIgnored var nachLaden: (Kern) -> Void = { _ in }

    var ha: HomeAssistant { HomeAssistant(adresse: einstellungen.adresse, token: einstellungen.token, konto: einstellungen.konto) }
    var verfolgung: Verfolgung { Verfolgung(schluessel: einstellungen.schluessel) }
    /// Alle Sendungen: aus Home Assistant und direkt verfolgt (gleiche Nummer nur einmal)
    var alle: [Sendung] { zusammenfuehren(ha: daten?.sendungen ?? [], direkt: direkt.sendungen) }
    var gruppen: Gruppen { Gruppen(alle, tage: einstellungen.tageZugestellt) }
    /// Angekündigte Briefe (nur mit Home Assistant)
    var briefe: [Brief] { daten?.briefe ?? [] }
    var briefGruppen: BriefGruppen { BriefGruppen(briefe) }
    func brief(_ id: String?) -> Brief? { briefe.first { $0.id == id } }
    var mehrereKonten: Bool { daten?.mehrereKonten ?? false }
    /// Ist überhaupt etwas eingerichtet (Home Assistant oder direkt verfolgen)?
    var bereit: Bool { einstellungen.eingerichtet || !direkt.sendungen.isEmpty || einstellungen.direktModus }

    func sendung(_ id: String?) -> Sendung? { alle.first { $0.id == id } }
    func notiz(_ id: String) -> String { direkt.notizen[id] ?? "" }

    private init() {
        Sprache.laden()
        einstellungen = Einstellungen(vorschau: vorschau)
        if vorschau {
            let env = ProcessInfo.processInfo.environment
            einstellungen.adresse = env["PB_ADRESSE"] ?? "http://127.0.0.1:8123"
            einstellungen.token = env["PB_TOKEN"] ?? "test-token"
            direkt = DirektListe()
            var d = DirektListe()
            var s = d.hinzufuegen(nummer: "1Z999AA10123456784", dienst: "ups", name: "Rücksendung Jacke", ruecksendung: true)
            var spur = Spur()
            spur.stand = "unterwegs"; spur.quelle = "UPS"; spur.erwartet = Texte.isoTag(Date().addingTimeInterval(3 * 86400))
            spur.ereignisse = [Ereignis(zeit: Date().addingTimeInterval(-7200), text: "Abholung erfolgt", ort: "Hamburg")]
            s.uebernehmen(spur)
            d.sendungen[0] = s
            d.notizen[s.id] = "Etikett liegt im Flur"
            direkt = d
        } else {
            daten = Ablage.lesen()
        }
    }

    /// Neu laden (Home Assistant und direkt verfolgte); meldet neue Stände und schreibt den Stand für die Widgets
    func laden(still: Bool = false) async {
        if !still { laedt = true }
        defer { laedt = false }
        let vorher = alle
        let vorherBriefe = Set(briefe.map(\.id))
        let ersterAbruf = daten == nil
        if einstellungen.eingerichtet {
            do {
                daten = try await ha.laden()
                fehler = ""
            } catch let e as HAFehler {
                fehler = e.text
            } catch {
                fehler = error.localizedDescription
            }
        } else {
            fehler = ""
        }
        if !vorschau {
            // ohne await auf die Eigenschaft: Kopie bearbeiten, dann zurückschreiben
            var liste = direkt
            // Sendungen aus Home Assistant ohne Verlauf selbst mitverfolgen (z. B. DHL ohne Schlüssel in Home Assistant)
            for s in (daten?.sendungen ?? []).prefix(30) where s.ereignisse.isEmpty && !s.fertig && !s.nummer.isEmpty
                && !liste.sendungen.contains(where: { $0.nummer == s.nummer.uppercased() }) && !verfolgung.moeglich(s.dienst).isEmpty {
                liste.hinzufuegen(nummer: s.nummer, dienst: s.dienst, name: s.name.isEmpty ? s.absender : s.name, ruecksendung: s.ruecksendung)
            }
            if !liste.sendungen.isEmpty {
                _ = await liste.aktualisieren(verfolgung)
            }
            direkt = liste
            liste.speichern()
            await abgleichen()
        }
        if einstellungen.mitteilungen && !vorher.isEmpty { await melden(alt: vorher, neu: alle) }
        if einstellungen.mitteilungen && !ersterAbruf { await briefeMelden(neu: briefGruppen.heute.filter { !vorherBriefe.contains($0.id) }) }
        Umschlaege.aufraeumen(behalten: Set(briefe.map(\.id)))
        if einstellungen.rueckgabeErinnern && !vorschau { await rueckgabenErinnern() }
        widgetsSchreiben()
        nachLaden(self)
    }

    /// Eigene Sendungen samt Stand an Home Assistant geben – so tauchen sie auf den anderen Geräten (Linux, Mac, iPhone) auf
    private func abgleichen() async {
        guard einstellungen.eingerichtet, einstellungen.auchInHA, let ha = daten?.sendungen else { return }
        var gesendet = UserDefaults.standard.dictionary(forKey: "abgleichGesendet") as? [String: String] ?? [:]
        let offen = Abgleich.offen(ha: ha, direkt: direkt.sendungen, gesendet: gesendet)
        guard !offen.isEmpty else { return }
        let verbindung = self.ha
        for d in offen.prefix(20) {
            gesendet[d.nummer] = d.signatur
            _ = try? await verbindung.hinzufuegen(nummer: d.nummer, dienst: d.dienst, name: d.name.isEmpty ? d.absender : d.name, standInfo: d.standInfo)
        }
        // nur Nummern behalten, die es noch gibt
        let nummern = Set(direkt.sendungen.map(\.nummer))
        UserDefaults.standard.set(gesendet.filter { nummern.contains($0.key) }, forKey: "abgleichGesendet")
        if let neu = try? await verbindung.laden() { daten = neu }
    }

    /// Stand für Widgets (App-Gruppe bzw. Ersatzweg) und Neuzeichnen
    func widgetsSchreiben() {
        var u = daten ?? Uebersicht()
        u.sendungen = alle
        u.geholt = Date()
        Ablage.schreiben(u)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Eine Aktion ausführen, danach neu laden; Fehler als Meldung
    private func aktion(erfolg: String = "", _ arbeit: @escaping () async throws -> Void) async -> Bool {
        do {
            try await arbeit()
            if !erfolg.isEmpty { meldung = erfolg }
            await laden(still: true)
            return true
        } catch let e as HAFehler {
            meldung = e.text
        } catch {
            meldung = error.localizedDescription
        }
        return false
    }

    /// Sendung verfolgen: auf dem Gerät (direkt) und – wenn eingerichtet – auch in Home Assistant
    func hinzufuegen(nummer: String, dienst: String, name: String, ruecksendung: Bool = false) async -> Bool {
        var liste = direkt
        let neu = liste.hinzufuegen(nummer: nummer, dienst: dienst, name: name, ruecksendung: ruecksendung)
        direkt = liste
        liste.speichern()
        auswahl = neu.id
        if einstellungen.eingerichtet && einstellungen.auchInHA {
            let ha = ha
            // Home Assistant kennt die Nummer dann auch (Widgets, andere Geräte, Mitteilungen)
            _ = await aktion(erfolg: T("Hinzugefügt")) { try await ha.hinzufuegen(nummer: nummer, dienst: dienst, name: name) }
        } else {
            meldung = T("Hinzugefügt")
            await laden(still: true)
        }
        return true
    }

    /// Sofort einmal abfragen (beim Öffnen einer direkt verfolgten Sendung)
    func jetztAbfragen(_ s: Sendung) async {
        guard s.quelle == "direkt" || s.ereignisse.isEmpty, !s.nummer.isEmpty else { return }
        let (spur, f) = await verfolgung.abfragen(s.nummer, dienst: s.dienst)
        anbieterFehler = f.mapValues(Self.fehlerText)
        guard let spur, var liste = Optional(direkt) else {
            if f.isEmpty && verfolgung.moeglich(s.dienst).isEmpty { anbieterFehler["–"] = T("Kein Anbieter für %1 eingerichtet.", s.dienstName) }
            return
        }
        if let i = liste.sendungen.firstIndex(where: { $0.nummer == s.nummer }) {
            liste.sendungen[i].uebernehmen(spur)
        } else {
            // Sendung aus Home Assistant ohne Verlauf: direkt mitverfolgen
            var n = liste.hinzufuegen(nummer: s.nummer, dienst: s.dienst, name: s.name)
            n.uebernehmen(spur)
            liste.sendungen[0] = n
        }
        direkt = liste
        liste.speichern()
        widgetsSchreiben()
    }

    /// Notiz merken und – bei Sendungen aus Home Assistant – mit allen Geräten im Haushalt teilen (Integration ≥ 1.9)
    func notizTeilen(_ s: Sendung, _ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notizSetzen(s.id, t)
        guard s.quelle == "ha", einstellungen.eingerichtet, t != s.notiz, !vorschau else { return }
        do {
            try await ha.notiz(s.id, t)
            await laden()
        } catch {
            meldung = T("Notiz nur auf diesem Gerät – zum Teilen die Integration auf 1.9 aktualisieren.")
        }
    }

    /// DHL mit Postleitzahl fragen (höchstens alle 10 Minuten je Sendung); Gemerktes gleich zeigen
    func mehrLaden(_ s: Sendung) async {
        guard s.dienst == "dhl", !s.nummer.isEmpty, !vorschau else { return }
        if mehr[s.nummer] == nil, let g = DHLMitPLZ.gemerkt(s.nummer) { mehr[s.nummer] = g }
        let plz = einstellungen.plz
        // am Zustelltag mit Live-Verfolgung alle 2 Minuten, sonst höchstens alle 10
        let abstand: TimeInterval = (mehr[s.nummer]?.live.isEmpty == false || s.stand == "heute") ? 110 : 600
        guard plz.count == 5, Date().timeIntervalSince(mehrZeit[s.nummer] ?? .distantPast) > abstand else { return }
        mehrZeit[s.nummer] = Date()
        let dhl = DHLMitPLZ()
        if let m = await dhl.abfragen(nummer: s.nummer, plz: plz) { mehr[s.nummer] = m }
    }

    static func fehlerText(_ f: AnbieterFehler) -> String {
        switch f {
        case .keinSchluessel: T("kein Schlüssel")
        case .unbekannt: T("kennt die Nummer (noch) nicht")
        case .abgelehnt: T("Schlüssel abgelehnt")
        case .kontingent: T("Kontingent aufgebraucht")
        case .netz: T("nicht erreichbar")
        case .antwort(let t): T("unerwartete Antwort (%1)", t)
        }
    }

    func entfernen(_ s: Sendung) async {
        if auswahl == s.id { auswahl = nil }
        var liste = direkt
        let nummer = s.nummer
        liste.sendungen.removeAll { $0.id == s.id || (!nummer.isEmpty && $0.nummer == nummer) }
        direkt = liste
        liste.speichern()
        if s.quelle == "ha" || daten?.sendungen.contains(where: { $0.nummer == nummer && $0.manuell }) == true {
            let ha = ha
            let id = daten?.sendungen.first(where: { $0.id == s.id || $0.nummer == nummer })?.id ?? s.id
            _ = await aktion { try await ha.entfernen(id) }
        } else {
            widgetsSchreiben()
        }
    }

    func umbenennen(_ s: Sendung, _ name: String) async {
        var liste = direkt
        for i in liste.sendungen.indices where liste.sendungen[i].id == s.id || liste.sendungen[i].nummer == s.nummer {
            liste.sendungen[i].name = name
        }
        direkt = liste
        liste.speichern()
        if s.quelle == "ha" {
            let ha = ha
            _ = await aktion { try await ha.umbenennen(s.id, name) }
        } else {
            widgetsSchreiben()
        }
    }

    func erledigt(_ s: Sendung, _ ja: Bool) async {
        if s.quelle == "direkt" {
            var liste = direkt
            if let i = liste.sendungen.firstIndex(where: { $0.id == s.id }) { liste.sendungen[i].erledigt = ja }
            direkt = liste
            liste.speichern()
            widgetsSchreiben()
            return
        }
        // sofort zeigen, dann speichern
        if var d = daten, let i = d.sendungen.firstIndex(where: { $0.id == s.id }) {
            d.sendungen[i].erledigt = ja
            daten = d
        }
        let ha = ha
        _ = await aktion { try await ha.erledigt(s.id, ja) }
    }

    func notizSetzen(_ id: String, _ text: String) {
        var liste = direkt
        liste.notizen[id] = text.isEmpty ? nil : String(text.prefix(500))
        direkt = liste
        liste.speichern()
    }

    /// Home Assistant jetzt ins Postfach schauen lassen, ein paar Mal nachladen
    func jetztNachsehen() async {
        let ha = ha
        guard await aktion({ try await ha.abrufen() }) else { return }
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(5))
            await laden(still: true)
        }
    }

    // MARK: Mitteilungen (lokal, wenn die App bzw. ihr Hintergrundabruf etwas Neues sieht)

    func mitteilungenErlauben() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Neue Briefe von heute (eine Mitteilung; wichtige zuerst)
    private func briefeMelden(neu: [Brief]) async {
        guard !neu.isEmpty else { return }
        let inhalt = UNMutableNotificationContent()
        let wichtig = neu.contains(where: \.wichtig)
        inhalt.title = (wichtig ? "⚠️ " : "✉️ ") + (neu.count == 1 ? T("Brief angekündigt") : T("%1 angekündigt", Texte.briefe(neu.count)))
        inhalt.body = neu.map { ($0.wichtig ? "⚠️ " : "") + $0.titel }.joined(separator: ", ")
        inhalt.threadIdentifier = "briefe"
        inhalt.userInfo = ["sendung": neu[0].id]
        inhalt.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "briefe-" + neu.map(\.id).joined(), content: inhalt, trigger: nil))
    }

    /// Brief als angekommen markieren (gilt über Home Assistant auf allen Geräten)
    func briefErledigt(_ b: Brief, _ ja: Bool) async {
        if var d = daten, let i = d.briefe.firstIndex(where: { $0.id == b.id }) {
            d.briefe[i].erledigt = ja
            daten = d
        }
        let ha = ha
        _ = await aktion { try await ha.erledigt(b.id, ja) }
    }

    /// Link öffnen (Route, Paketsteuerung)
    func oeffnen(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Erinnerung an die Rücksendefrist (zwei Tage vorher, morgens)
    func rueckgabeErinnern(_ s: Sendung, bis: Date) async {
        let vorher = Calendar.current.date(byAdding: .day, value: -2, to: bis) ?? bis
        let tage = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: vorher).day ?? 0)
        await erinnern(titel: T("Rückgabe: %1", s.titel), notiz: T("Rücksendefrist bis %1 (laut Shop, ohne Gewähr).", Texte.kurzTag(bis))
                       + (s.nummer.isEmpty ? "" : "\n" + T("Sendung %1", s.nummer)), in: tage)
    }

    /// Frisch zugestellte Pakete mit bekannter Rücksendefrist: einmal automatisch erinnern
    private func rueckgabenErinnern() async {
        let d = UserDefaults.standard
        var erledigt = Set(d.stringArray(forKey: "rueckgabeErinnert") ?? [])
        let erstesMal = d.object(forKey: "rueckgabeErinnert") == nil
        for s in alle where s.stand == "zugestellt" && Date().timeIntervalSince(s.datum) < 3 * 86400 && !erledigt.contains(s.id) {
            guard let bis = s.rueckgabeBis, bis > Date() else { continue }
            erledigt.insert(s.id)
            // beim ersten Start nicht für alle alten Pakete auf einmal
            if !erstesMal { await rueckgabeErinnern(s, bis: bis) }
        }
        d.set(Array(erledigt.suffix(300)), forKey: "rueckgabeErinnert")
    }

    /// Erinnerung in der Erinnerungen-App (z. B. „Brief vom Finanzamt beantworten“)
    func erinnern(titel: String, notiz: String, in tage: Int) async {
        let ek = EKEventStore()
        do {
            guard try await ek.requestFullAccessToReminders() else {
                meldung = T("Kein Zugriff auf die Erinnerungen – in den Systemeinstellungen erlauben.")
                return
            }
            let r = EKReminder(eventStore: ek)
            r.title = titel
            r.notes = notiz
            r.calendar = ek.defaultCalendarForNewReminders()
            let tag = Calendar.current.date(byAdding: .day, value: tage, to: Date()) ?? Date()
            var k = Calendar.current.dateComponents([.year, .month, .day], from: tag)
            k.hour = tage == 0 ? 18 : 9
            r.dueDateComponents = k
            r.addAlarm(EKAlarm(absoluteDate: Calendar.current.date(from: k) ?? tag))
            try ek.save(r, commit: true)
            meldung = T("Erinnerung angelegt")
        } catch {
            meldung = T("Erinnerung nicht möglich: %1", error.localizedDescription)
        }
    }

    private func melden(alt: [Sendung], neu: [Sendung]) async {
        let vorher = Dictionary(alt.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in neu {
            guard let m = Texte.mitteilung(alt: vorher[s.id], neu: s) else { continue }
            let inhalt = UNMutableNotificationContent()
            inhalt.title = m.titel
            inhalt.body = m.text
            inhalt.threadIdentifier = "pakete"
            inhalt.userInfo = ["sendung": s.id]
            inhalt.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(s.id)-\(s.stand)", content: inhalt, trigger: nil))
        }
    }
}

/// Einstellungen: Adresse, Postfach, Anzeige in den Benutzereinstellungen; Token und Schlüssel im Schlüsselbund
@MainActor
@Observable
final class Einstellungen {
    @ObservationIgnored private let d = Ablage.einstellungen
    @ObservationIgnored private let vorschau: Bool

    var adresse: String { didSet { if !vorschau { d.set(adresse, forKey: "adresse") } } }
    var konto: String { didSet { if !vorschau { d.set(konto, forKey: "konto") } } }
    var mitteilungen: Bool { didSet { d.set(mitteilungen, forKey: "mitteilungen") } }
    var tageZugestellt: Int { didSet { d.set(tageZugestellt, forKey: "tageZugestellt") } }
    /// Direkt verfolgte Sendungen auch in Home Assistant eintragen
    var auchInHA: Bool { didSet { d.set(auchInHA, forKey: "auchInHA") } }
    /// Ohne Home Assistant benutzen (nur direkt verfolgen)
    var direktModus: Bool { didSet { d.set(direktModus, forKey: "direktModus") } }
    /// Live-Aktivität für Pakete, die heute kommen (iPhone)
    var liveAktivitaet: Bool { didSet { d.set(liveAktivitaet, forKey: "liveAktivitaet") } }
    /// Was die Liste zeigt: "alle" | "briefe" | "pakete"
    var bereich: String { didSet { d.set(bereich, forKey: "bereich") } }
    /// Nach der Zustellung automatisch an die Rücksendefrist erinnern
    var rueckgabeErinnern: Bool { didSet { d.set(rueckgabeErinnern, forKey: "rueckgabeErinnern") } }
    /// Neue Versionen selbst suchen (Mac: auch installieren; iPhone: Bescheid geben)
    var autoUpdate: Bool { didSet { d.set(autoUpdate, forKey: "autoUpdate") } }
    /// Eigene Postleitzahl: DHL zeigt damit mehr (Absender, Empfänger, Orte im Verlauf)
    var plz: String { didSet { if !vorschau { d.set(plz, forKey: "plz") } } }
    var token: String {
        didSet {
            guard !vorschau else { return }
            Schluesselbund.speichern(token, konto: "token")
            #if os(iOS)
            // klappt die App-Gruppe, dürfen die Widgets selbst bei Home Assistant nachfragen
            if Ablage.gruppeDa { d.set(token, forKey: "token") }
            #endif
        }
    }
    var schluessel: Schluessel {
        didSet { if !vorschau, let j = try? JSONEncoder().encode(schluessel) { Schluesselbund.speichern(String(decoding: j, as: UTF8.self), konto: "schluessel") } }
    }

    init(vorschau: Bool) {
        self.vorschau = vorschau
        d.register(defaults: ["mitteilungen": true, "tageZugestellt": 14, "auchInHA": true, "direktModus": false, "liveAktivitaet": true, "rueckgabeErinnern": true, "autoUpdate": true])
        adresse = vorschau ? "" : d.string(forKey: "adresse") ?? ""
        konto = vorschau ? "" : d.string(forKey: "konto") ?? ""
        mitteilungen = d.bool(forKey: "mitteilungen")
        tageZugestellt = d.integer(forKey: "tageZugestellt")
        auchInHA = d.bool(forKey: "auchInHA")
        direktModus = d.bool(forKey: "direktModus")
        liveAktivitaet = d.bool(forKey: "liveAktivitaet")
        bereich = d.string(forKey: "bereich") ?? "alle"
        rueckgabeErinnern = d.bool(forKey: "rueckgabeErinnern")
        autoUpdate = d.bool(forKey: "autoUpdate")
        plz = vorschau ? "" : d.string(forKey: "plz") ?? ""
        // bis 1.0 lag der Token auf dem iPhone in den Einstellungen
        let alt = d.string(forKey: "token") ?? ""
        token = vorschau ? "" : Schluesselbund.lesen(konto: "token") ?? alt
        schluessel = vorschau ? Schluessel() : Schluesselbund.lesen(konto: "schluessel").flatMap { try? JSONDecoder().decode(Schluessel.self, from: Data($0.utf8)) } ?? Schluessel()
        if !vorschau && !alt.isEmpty && Schluesselbund.lesen(konto: "token") == nil { Schluesselbund.speichern(alt, konto: "token") }
    }

    var eingerichtet: Bool { !adresse.isEmpty && !token.isEmpty }
}

/// Token und Schlüssel im Schlüsselbund (iPhone und Mac)
enum Schluesselbund {
    static let dienst = "de.teyro.paketbote"

    static func basis(_ konto: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: dienst, kSecAttrAccount as String: konto]
    }

    static func lesen(konto: String) -> String? {
        var q = basis(konto)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var e: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &e) == errSecSuccess, let d = e as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func speichern(_ wert: String, konto: String) {
        guard !wert.isEmpty else { SecItemDelete(basis(konto) as CFDictionary); return }
        let daten = Data(wert.utf8)
        if SecItemUpdate(basis(konto) as CFDictionary, [kSecValueData as String: daten] as CFDictionary) == errSecItemNotFound {
            var neu = basis(konto)
            neu[kSecValueData as String] = daten
            neu[kSecAttrLabel as String] = "Post & Pakete – " + konto
            #if os(iOS)
            neu[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #endif
            SecItemAdd(neu as CFDictionary, nil)
        }
    }
}
