import XCTest
@testable import PaketKern

final class KernTests: XCTestCase {
    let kal: Calendar = {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }()
    lazy var jetzt = kal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!

    func beispiel() -> Uebersicht {
        let ms = { (d: Date) -> JSON in .zahl(d.timeIntervalSince1970 * 1000) }
        let j: JSON = ["version": 4, "stand": ms(jetzt), "konten": [["id": "e1", "name": "Kim", "siebzehn": true, "siebzehn_rest": 198]],
                       "briefe": [
            ["id": "p1", "datum": ms(jetzt), "art": "paket", "absender": "OTTO", "sendung": "H1002345678901234567", "dienst": "hermes",
             "erwartet": "2026-10-23", "zeitfenster": "10:00–13:00", "verfolgen": "https://www.myhermes.de/x", "konto": "e1", "konto_name": "Kim",
             "ereignisse": [["zeit": "2026-10-20T18:00:00+02:00", "text": "Im Verteilzentrum", "ort": "Ketzin"]]],
            ["id": "p2", "datum": ms(jetzt), "art": "paket", "absender": "Zalando", "dienst": "dpd", "stand": "heute", "konto": "e1"],
            ["id": "p3", "datum": ms(jetzt), "art": "paket", "absender": "Kindle", "name": "Geschenk Oma", "dienst": "amazon", "erwartet": "2026-10-22",
             "kundenkonto": "Johanna", "manuell": true, "konto": "e1"],
            ["id": "p4", "datum": ms(jetzt), "art": "paket", "absender": "Alt", "stand": "zugestellt", "konto": "e1"],
            ["id": "p5", "datum": ms(jetzt), "art": "paket", "absender": "Kaffee", "stand": "abholbereit", "dienst": "gls", "konto": "e1",
             "abholcode": "482913", "abholort": "Packstation 123", "abholadresse": "Hachmannplatz 16, 20099 Hamburg", "abholfrist": "2026-10-28"],
            ["id": "b1", "datum": ms(jetzt), "art": "brief", "absender": "AOK"],
        ]]
        return Uebersicht.aus(j)!
    }

    func testLesenUndGruppen() {
        let u = beispiel()
        XCTAssertEqual(u.sendungen.count, 5, "Briefe zählen nicht")
        XCTAssertEqual(u.konten.first?.siebzehnRest, 198)
        let g = Gruppen(u.sendungen, jetzt: jetzt, kalender: kal)
        XCTAssertEqual(g.heute.map(\.id), ["p2", "p5"], "abholbereit hinten")
        XCTAssertEqual(g.unterwegs.map(\.id), ["p3", "p1"], "nach Termin")
        XCTAssertEqual(g.zugestellt.map(\.id), ["p4"])
        let otto = u.sendungen[0]
        XCTAssertEqual(otto.ereignisse.first?.ort, "Ketzin")
        XCTAssertNotNil(otto.ereignisse.first?.zeit)
        XCTAssertEqual(otto.stufe, 2)
        XCTAssertEqual(u.sendungen[2].titel, "Geschenk Oma")
        XCTAssertEqual(u.sendungen[4].dienstName, "GLS")
    }

    func testTexte() {
        let u = beispiel()
        XCTAssertEqual(Texte.stand(u.sendungen[0], jetzt: jetzt, kalender: kal), "voraussichtlich Fr 23.10., 10:00–13:00")
        XCTAssertEqual(Texte.zeile(u.sendungen[2], jetzt: jetzt, kalender: kal), "kommt morgen · Johanna")
        XCTAssertEqual(Texte.stand(u.sendungen[4], jetzt: jetzt, kalender: kal), "zur Abholung bereit")
        XCTAssertEqual(Texte.titel(Gruppen(u.sendungen, jetzt: jetzt, kalender: kal).aktiv), "4 Pakete unterwegs")
        let satz = Texte.heuteSatz(Gruppen(u.sendungen, jetzt: jetzt, kalender: kal))
        XCTAssertEqual(satz, "Heute kommt ein Paket: Zalando (DPD). Zur Abholung bereit: Kaffee (GLS).")
        var spaet = u.sendungen[0]
        spaet.erwartet = "2026-10-19"
        XCTAssertEqual(Texte.stand(spaet, jetzt: jetzt, kalender: kal), "überfällig seit 19.10.")
    }

    func testDiensteUndMitteilungen() {
        XCTAssertEqual(Dienst.vonNummer("1Z999AA10123456784"), "ups")
        XCTAssertEqual(Dienst.vonNummer("TBA301234567890"), "amazon")
        XCTAssertEqual(Dienst.vonNummer("01234567890123"), "")
        XCTAssertEqual(Dienst.nummerIn("Ihre Sendungsnummer: 00340434161094015902 – danke"), "00340434161094015902")
        XCTAssertEqual(Dienst.verfolgen("gls", "123")?.host, "gls-group.com")
        let u = beispiel()
        var neu = u.sendungen[0]
        neu.stand = "heute"
        XCTAssertEqual(Texte.mitteilung(alt: u.sendungen[0], neu: neu)?.titel, "📦 Kommt heute")
        XCTAssertNil(Texte.mitteilung(alt: neu, neu: neu))
        XCTAssertEqual(u.nur(konto: "e1").sendungen.count, 5)
        XCTAssertEqual(u.nur(konto: "johanna").sendungen.count, 0)
        XCTAssertEqual(Texte.adresse("homeassistant.local:8123/"), "http://homeassistant.local:8123")
    }

    func testAblageRundreise() throws {
        let u = beispiel()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        let zurueck = try dec.decode(Uebersicht.self, from: enc.encode(u))
        XCTAssertEqual(zurueck.sendungen.map(\.id), u.sendungen.map(\.id))
        XCTAssertEqual(zurueck.sendungen[0].ereignisse, u.sendungen[0].ereignisse)
    }

    func testAbholenUndRueckgabe() throws {
        let u = beispiel()
        let kaffee = u.sendungen[4]
        XCTAssertTrue(kaffee.zumAbholen)
        XCTAssertEqual(kaffee.abholcode, "482913")
        XCTAssertEqual(kaffee.abholort, "Packstation 123")
        XCTAssertFalse(u.sendungen[0].zumAbholen)
        XCTAssertNil(kaffee.rueckgabeBis, "erst nach der Zustellung")
        // Shop-Regel: Zalando 100 Tage, unbekannter Shop keine Frist
        let zu = kal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 16))!
        XCTAssertEqual(Rueckgabe.frist(shop: "Zalando SE", dienst: "dpd", zugestellt: zu, kalender: kal),
                       kal.date(from: DateComponents(year: 2027, month: 2, day: 4)))
        XCTAssertNil(Rueckgabe.frist(shop: "Fahrradladen Nord", dienst: "ups", zugestellt: zu, kalender: kal))
        XCTAssertNotNil(Rueckgabe.frist(shop: "", dienst: "amazon", zugestellt: zu, kalender: kal))
        // ältere gespeicherte Sendungen ohne die neuen Felder bleiben lesbar
        let daten = try JSONEncoder().encode(kaffee)
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: daten) as? [String: Any])
        for k in ["abholcode", "abholort", "abholadresse", "abholfrist", "ruecksendefrist"] { j.removeValue(forKey: k) }
        let alt = try JSONDecoder().decode(Sendung.self, from: JSONSerialization.data(withJSONObject: j))
        XCTAssertEqual(alt.id, "p5")
        XCTAssertEqual(alt.abholcode, "")
    }

    func testAbgleich() throws {
        let ha = beispiel().sendungen
        var otto = ha[0]            // in Home Assistant unterwegs
        otto.nummer = otto.nummer.uppercased()
        otto.stand = "zugestellt"
        var neu = otto
        neu.nummer = "00340434161094015902"
        let offen = Abgleich.offen(ha: ha, direkt: [otto, neu], gesendet: [:])
        XCTAssertEqual(offen.map(\.nummer), [otto.nummer, neu.nummer])
        XCTAssertTrue(Abgleich.offen(ha: ha, direkt: [otto], gesendet: [otto.nummer: otto.signatur]).isEmpty, "nicht zweimal")
        var gleich = ha[0]
        gleich.nummer = gleich.nummer.uppercased()
        XCTAssertTrue(Abgleich.offen(ha: ha, direkt: [gleich], gesendet: [:]).isEmpty, "Home Assistant weiß schon alles")
        let info = otto.standInfo
        XCTAssertEqual(info["stand"] as? String, "zugestellt")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(info))
    }
}

final class BriefTests: XCTestCase {
    func testBriefeUndSatz() {
        var kal = Calendar(identifier: .gregorian)
        kal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let jetzt = kal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!
        let ms = { (d: Date) -> JSON in .zahl(d.timeIntervalSince1970 * 1000) }
        let j: JSON = ["version": 4, "konten": [], "briefe": [
            ["id": "b1", "datum": ms(jetzt.addingTimeInterval(-3600)), "art": "brief", "absender": "AOK", "bild": true],
            ["id": "b2", "datum": ms(jetzt.addingTimeInterval(-1800)), "art": "brief", "absender": "Finanzamt", "wichtig": true],
            ["id": "b3", "datum": ms(jetzt.addingTimeInterval(-30 * 3600)), "art": "brief", "absender": ""],
            ["id": "p1", "datum": ms(jetzt), "art": "paket", "absender": "OTTO", "dienst": "hermes", "stand": "heute"],
        ]]
        let u = Uebersicht.aus(j)!
        XCTAssertEqual(u.briefe.map(\.id), ["b2", "b1", "b3"])
        XCTAssertEqual(u.sendungen.count, 1)
        let b = BriefGruppen(u.briefe, jetzt: jetzt, kalender: kal)
        XCTAssertEqual(b.heute.map(\.id), ["b2", "b1"], "wichtige zuerst")
        XCTAssertEqual(b.unterwegs.map(\.id), ["b3"])
        XCTAssertEqual(u.briefe[2].titel, "Absender unbekannt")
        XCTAssertEqual(Texte.brief(u.briefe[1], jetzt: jetzt, kalender: kal), "angekündigt heute")
        let satz = Texte.postSatz(b, Gruppen(u.sendungen, jetzt: jetzt, kalender: kal))
        XCTAssertTrue(satz.hasPrefix("Heute kommt ein Paket: OTTO (Hermes)."), satz)
        XCTAssertTrue(satz.contains("Dazu kommen 2 Briefe: Finanzamt und AOK. Wichtig: Finanzamt."), satz)
        // ältere gespeicherte Stände ohne Briefe lesen
        let alt = #"{"sendungen":[],"konten":[],"fehler":"","version":4,"geholt":0}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        XCTAssertEqual(try dec.decode(Uebersicht.self, from: Data(alt.utf8)).briefe.count, 0)
    }

}

final class PaketTrackerTests: XCTestCase {
    func testZustaendeZuSendungen() {
        let z: [[String: Any]] = [
            ["entity_id": "sensor.paket_00340434", "state": "out_for_delivery", "last_changed": "2026-11-22T08:00:00+00:00",
             "attributes": ["carrier": "dhl", "carrier_name": "DHL", "number": "00340434", "name": "Druckerpatronen", "eta_date": "2026-11-22", "eta_from": "10:00", "eta_to": "12:00",
                            "days_until": 0, "status_text": "In Zustellung", "events": [["timestamp": "2026-11-22T07:00:00+00:00", "text": "Im Zustellfahrzeug", "location": "Hamburg"]]]],
            ["entity_id": "sensor.paket_tracker_17track_kontingent", "state": "90", "attributes": ["unit_of_measurement": "Nummern"]],
            ["entity_id": "sensor.paket_amz123", "state": "awaiting_pickup", "attributes": ["carrier": "amazon", "number": "amz123", "pickup_point": "Packstation 101"]],
        ]
        let s = PaketTracker.sendungen(z)
        XCTAssertEqual(s.count, 2)
        let dhl = s.first { $0.dienst == "dhl" }!
        XCTAssertEqual(dhl.id, "pt:00340434")
        XCTAssertEqual(dhl.stand, "heute")
        XCTAssertEqual(dhl.zeitfenster, "10:00–12:00")
        XCTAssertEqual(dhl.ereignisse.first?.ort, "Hamburg")
        XCTAssertEqual(s.first { $0.dienst == "amazon" }?.stand, "abholbereit")
        XCTAssertEqual(PaketTracker.nummer("pt:00340434"), "00340434")
        XCTAssertNil(PaketTracker.nummer("abc"))
    }
}
