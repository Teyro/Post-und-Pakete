import XCTest
@testable import PaketKern

/// Anbieter, der immer dasselbe antwortet (für die Kette)
struct Probe: Anbieter {
    let name: String
    let antwort: Result<Spur, AnbieterFehler>
    func kann(_ dienst: String, _ s: Schluessel) -> Bool { true }
    func abfragen(_ nummer: String, dienst: String, schluessel: Schluessel) async throws -> Spur { try antwort.get() }
}

final class AnbieterTests: XCTestCase {
    func testKetteSpringtEin() async {
        var gut = Spur()
        gut.ereignisse = [Ereignis(zeit: Date(), text: "Im Verteilzentrum", ort: "Ketzin")]
        let v = Verfolgung(schluessel: Schluessel(), anbieter: [
            Probe(name: "A", antwort: .failure(.netz)),
            Probe(name: "B", antwort: .success(Spur())),          // kennt die Nummer noch nicht
            Probe(name: "C", antwort: .success(gut)),
            Probe(name: "D", antwort: .failure(.abgelehnt)),
        ])
        let (spur, fehler) = await v.abfragen("H1", dienst: "hermes")
        XCTAssertEqual(spur?.quelle, "C")
        XCTAssertEqual(fehler["A"], .netz)
        XCTAssertEqual(fehler["B"], .unbekannt)
        XCTAssertNil(fehler["D"], "nach dem Treffer nicht weiter fragen")
    }

    func testWelcheAnbieter() {
        var s = Schluessel()
        XCTAssertEqual(Verfolgung(schluessel: s).moeglich("gls"), ["GLS (öffentlich)"])
        s.dhl = "x"; s.siebzehn = "y"; s.ship24 = "z"
        XCTAssertEqual(Verfolgung(schluessel: s).moeglich("dhl"), ["DHL", "DHL (ohne Schlüssel)", "17TRACK", "Ship24"])
        s.setzen("Ship24", false)
        XCTAssertEqual(Verfolgung(schluessel: s).moeglich("dhl"), ["DHL", "DHL (ohne Schlüssel)", "17TRACK"])
        s.setzen("Ship24", true)
        XCTAssertEqual(Verfolgung(schluessel: s).moeglich("amazon"), ["Ship24"])
        s.oeffentlich = false
        XCTAssertEqual(Verfolgung(schluessel: s).moeglich("dpd"), ["17TRACK", "Ship24"])
    }

    func testDHLVoraussichtlicheZustellung() {
        let j = JSON.lesen(#"{"sendungsdetails":{"istZugestellt":false,"zustellung":{"zustellzeitfensterVon":"2026-11-07","zustellzeitfensterBis":"2026-11-07","hasDeliveryDateMismatch":false},"sendungsverlauf":{"status":"Vorbereitung für Weitertransport","events":[{"datum":"2026-11-06T15:35:57+01:00","status":"Die Sendung wurde von DHL bearbeitet und wird für den Weitertransport in die Region des Empfängers vorbereitet."}]}}}"#)!
        let s = DHLOeffentlichAnbieter.lesen(j)
        XCTAssertEqual(s.erwartet, "2026-11-07")
        XCTAssertEqual(s.zeitfenster, "")
        let mitZeit = JSON.lesen(#"{"sendungsdetails":{"istZugestellt":false,"zustellung":{"zustellzeitfensterVon":"2026-11-07T10:00:00+01:00","zustellzeitfensterBis":"2026-11-07T12:30:00+01:00"},"sendungsverlauf":{"events":[]}}}"#)!
        XCTAssertEqual(DHLOeffentlichAnbieter.lesen(mitZeit).zeitfenster, "10:00–12:30")
    }

    func testDHLOhneSchluessel() {
        let j = JSON.lesen(#"{"id":"00340434161094015902","sendungsdetails":{"istZugestellt":true,"sendungsverlauf":{"status":"Abholung aus Packstation","events":[{"datum":"2026-10-16T17:37:10+02:00","status":"Die Sendung wurde elektronisch angekündigt."},{"datum":"2026-10-19T07:58:09+02:00","status":"Die Sendung wurde in das Zustellfahrzeug geladen. Die Zustellung  erfolgt voraussichtlich heute."},{"datum":"2026-10-19T12:53:25+02:00","status":"Die Sendung konnte nicht zugestellt werden und wird in eine Packstation gebracht."},{"datum":"2026-10-19T14:13:52+02:00","status":"Die Sendung liegt in der Packstation zur Abholung bereit."},{"datum":"2026-10-21T15:29:34+02:00","status":"Abholung aus Packstation"}]},"zustellung":{"hasDeliveryDateMismatch":false}}}"#)!
        let s = DHLOeffentlichAnbieter.lesen(j)
        XCTAssertEqual(s.stand, "zugestellt")
        XCTAssertTrue(s.ende)
        XCTAssertEqual(s.ereignisse.count, 5)
        XCTAssertEqual(s.ereignisse.first?.text, "Abholung aus Packstation")
        XCTAssertTrue(s.ereignisse[3].text.contains("Zustellung erfolgt"), "doppelte Leerzeichen raus")
        // Stand aus Texten
        XCTAssertEqual(Netz.standAusText("Die Sendung liegt in der Packstation zur Abholung bereit."), "abholbereit")
        XCTAssertEqual(Netz.standAusText("Die Sendung konnte nicht zugestellt werden und wird in eine Packstation gebracht."), "unterwegs")
        XCTAssertEqual(Netz.standAusText("Der Empfänger hat die Sendung aus der Packstation abgeholt."), "zugestellt")
        XCTAssertEqual(Netz.standAusText("Die Sendung wurde in das Zustellfahrzeug geladen."), "heute")
        // ältere gespeicherte Schlüssel ohne „aus“ lesen
        let alt = try! JSONDecoder().decode(Schluessel.self, from: Data(#"{"dhl":"k","upsId":"","upsGeheim":"","siebzehn":"","ship24":"","oeffentlich":true}"#.utf8))
        XCTAssertEqual(alt.dhl, "k")
        XCTAssertTrue(alt.an("Ship24"))
    }

    func testZusammenfuehrenEigenerStandGewinnt() {
        let ha = Sendung(id: "x", name: "Test", nummer: "00340434161094015902", dienst: "dhl", stand: "unterwegs", manuell: true)
        var d = Sendung(id: "d", nummer: "00340434161094015902", dienst: "dhl", quelle: "direkt")
        d.stand = "zugestellt"
        d.ereignisse = [Ereignis(zeit: Date(), text: "Abholung aus Packstation")]
        let m = zusammenfuehren(ha: [ha], direkt: [d])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].id, "x")
        XCTAssertEqual(m[0].stand, "zugestellt")
        XCTAssertEqual(m[0].name, "Test")
    }

    func testDHL() {
        let j = JSON.lesen(#"{"status":{"statusCode":"transit","description":"Die Sendung wurde in das Zustellfahrzeug geladen."},"estimatedTimeOfDelivery":"2026-10-21T12:00:00Z","events":[{"timestamp":"2026-10-21T07:00:00","description":"In Zustellung","location":{"address":{"addressLocality":"Hamburg"}}}]}"#)!
        let s = DHLAnbieter.lesen(j)
        XCTAssertEqual(s.stand, "heute")
        XCTAssertEqual(s.erwartet, "2026-10-21")
        XCTAssertEqual(s.ereignisse.first?.ort, "Hamburg")
    }

    func testUPS() {
        let j = JSON.lesen(#"{"currentStatus":{"type":"I","description":"Out For Delivery Today"},"deliveryDate":[{"type":"SDD","date":"20261023"}],"deliveryTime":{"startTime":"100000","endTime":"140000"},"activity":[{"date":"20261023","time":"071500","status":{"type":"I","description":"OUT FOR DELIVERY TODAY"},"location":{"address":{"city":"HAMBURG","countryCode":"DE"}}}]}"#)!
        let s = UPSAnbieter.lesen(j)
        XCTAssertEqual(s.stand, "heute")
        XCTAssertEqual(s.erwartet, "2026-10-23")
        XCTAssertEqual(s.zeitfenster, "10:00–14:00")
        XCTAssertEqual(s.ereignisse.first?.text, "Out for delivery today")
        XCTAssertEqual(s.ereignisse.first?.ort, "Hamburg, DE")
    }

    func testSiebzehnUndShip24() {
        let a = JSON.lesen(#"{"latest_status":{"status":"AvailableForPickup"},"latest_event":{"description":"Liegt im Paketshop"},"time_metrics":{"estimated_delivery_date":{"from":"2026-10-22T00:00:00+02:00"}},"tracking":{"providers":[{"events":[{"time_iso":"2026-10-21T09:00:00+02:00","description":"Liegt im Paketshop","location":"Hamburg"}]}]}}"#)!
        let s = SiebzehnAnbieter.lesen(a)
        XCTAssertEqual(s.stand, "abholbereit")
        XCTAssertEqual(s.erwartet, "2026-10-22")
        let b = JSON.lesen(#"{"shipment":{"statusMilestone":"delivered","delivery":{"estimatedDeliveryDate":"2026-10-20T00:00:00Z"}},"events":[{"occurrenceDatetime":"2026-10-20T11:00:00","status":"Delivered","location":"Hamburg"}]}"#)!
        let t = Ship24Anbieter.lesen(b)
        XCTAssertEqual(t.stand, "zugestellt")
        XCTAssertTrue(t.ende)
        XCTAssertEqual(t.text, "Delivered")
    }

    func testOeffentlich() {
        let g = JSON.lesen(#"{"progressBar":{"statusInfo":"INDELIVERY"},"history":[{"date":"2026-10-21","time":"07:30:00","evtDscr":"Das Paket ist in Zustellung.","address":{"city":"Hamburg","countryName":"Deutschland"}}]}"#)!
        let s = GLSAnbieter.lesen(g)
        XCTAssertEqual(s.stand, "heute")
        XCTAssertEqual(s.ereignisse.first?.ort, "Hamburg, Deutschland")
        let d = JSON.lesen(#"{"statusInfo":[{"status":"ACCEPTED","label":"Übernahme","statusHasBeenReached":true},{"status":"DELIVERED","label":"Zugestellt","statusHasBeenReached":true,"isCurrentStatus":true,"date":"21.10.2026, 10:15","location":"Hamburg"}],"scanInfo":{"scan":[{"date":"2026-10-21T10:15:00","scanData":{"location":"Hamburg"},"scanDescription":{"content":["Zugestellt."]}}]}}"#)!
        let t = DPDAnbieter.lesen(d)
        XCTAssertEqual(t.stand, "zugestellt")
        XCTAssertEqual(t.ereignisse.first?.text, "Zugestellt.")
    }

    func testDirektListe() async {
        var l = DirektListe()
        let s = l.hinzufuegen(nummer: "1z999aa10123456784", dienst: "ups", name: "Jacke", ruecksendung: true)
        XCTAssertEqual(s.nummer, "1Z999AA10123456784")
        XCTAssertEqual(s.quelle, "direkt")
        XCTAssertEqual(s.id.count, 20)
        XCTAssertEqual(l.hinzufuegen(nummer: "1Z999AA10123456784", dienst: "ups", name: "").id, s.id, "nicht doppelt")
        var spur = Spur()
        spur.stand = "heute"; spur.quelle = "Probe"
        spur.ereignisse = [Ereignis(zeit: Date(), text: "In Zustellung", ort: "Hamburg")]
        let v = Verfolgung(schluessel: Schluessel(), anbieter: [Probe(name: "Probe", antwort: .success(spur))])
        let geaendert = await l.aktualisieren(v)
        XCTAssertEqual(geaendert.count, 1)
        XCTAssertEqual(l.sendungen[0].stand, "heute")
        XCTAssertEqual(l.sendungen[0].anbieter, "Probe")
        // Zusammenführen: gleiche Nummer aus Home Assistant gewinnt, Verlauf kommt dazu
        let ha = Sendung(id: "x", absender: "Shop", nummer: "1Z999AA10123456784", dienst: "ups")
        let alle = zusammenfuehren(ha: [ha], direkt: l.sendungen)
        XCTAssertEqual(alle.count, 1)
        XCTAssertEqual(alle[0].id, "x")
        XCTAssertEqual(alle[0].ereignisse.count, 1)
        XCTAssertTrue(alle[0].ruecksendung)
    }

    func testStatistik() {
        let kal = Calendar(identifier: .gregorian)
        let jetzt = kal.date(from: DateComponents(year: 2026, month: 10, day: 21))!
        let a = [ArchivEintrag(datum: jetzt, absender: "OTTO", paket: true, dienst: "hermes"),
                 ArchivEintrag(datum: jetzt.addingTimeInterval(-40 * 86400), absender: "OTTO", paket: true, dienst: "hermes"),
                 ArchivEintrag(datum: jetzt, absender: "AOK", paket: false, dienst: "")]
        let st = Statistik(archiv: a, sendungen: [], jetzt: jetzt, kalender: kal)
        XCTAssertEqual(st.gesamt, 2)
        XCTAssertEqual(st.monate.count, 12)
        XCTAssertEqual(st.monate.last?.anzahl, 1)
        XCTAssertEqual(st.shops.first?.name, "OTTO")
        XCTAssertEqual(st.dienste.first?.dienst, "hermes")
    }
}
