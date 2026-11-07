import SwiftUI
import MapKit
import CoreLocation
import PhotosUI
import PaketKern
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Eine Sendung: Kopf mit Logo und Stand, Karte der Stationen, Verlauf, Aktionen
struct DetailAnsicht: View {
    let kern: Kern
    let sendung: Sendung
    @State private var umbenennen = false
    @State private var neuerName = ""
    @State private var notiz = ""
    @State private var fotoWahl: PhotosPickerItem?
    @State private var foto: Image?
    @State private var fragt = false
    @State private var vorzeigen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kopf
                if let live = kern.mehr[sendung.nummer]?.live, !live.isEmpty, !sendung.fertig, sendung.stand != "abholbereit" { LiveKarte(text: live, zeit: kern.mehr[sendung.nummer]?.liveZeit) }
                if sendung.zumAbholen { AbholKarte(kern: kern, sendung: sendung) }
                if let bis = sendung.rueckgabeBis, bis >= Calendar.current.startOfDay(for: Date()) { RueckgabeKarte(kern: kern, sendung: sendung, bis: bis) }
                if !sendung.zumAbholen && !anzeige.ereignisse.filter({ !$0.ort.isEmpty }).isEmpty {
                    StationenKarte(ereignisse: anzeige.ereignisse)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                knoepfe
                verlauf
                notizUndFoto
                angaben
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(sendung.titel)
        .task(id: sendung.id) {
            notiz = sendung.notiz.isEmpty ? kern.notiz(sendung.id) : sendung.notiz
            fotoLaden()
            fragt = true
            await kern.jetztAbfragen(sendung)
            await kern.mehrLaden(sendung)
            fragt = false
            // am Zustelltag: Live-Stopps nachladen, solange die Sendung offen ist
            while !Task.isCancelled && sendung.stand == "heute" && !kern.einstellungen.plz.isEmpty {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                await kern.mehrLaden(sendung)
            }
        }
        .onChange(of: fotoWahl) { _, neu in
            Task {
                guard let d = try? await neu?.loadTransferable(type: Data.self) else { return }
                try? FotoAblage.speichern(d, sendung.id)
                fotoLaden()
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                ShareLink(item: teilenText) { Label(T("Teilen"), systemImage: "square.and.arrow.up") }
            }
        }
        .sheet(isPresented: $vorzeigen) { VorzeigenAnsicht(sendung: sendung, foto: foto) }
        .alert(T("Umbenennen"), isPresented: $umbenennen) {
            TextField(T("Name"), text: $neuerName)
            Button(T("Sichern")) { Task { await kern.umbenennen(sendung, neuerName) } }
            Button(T("Abbrechen"), role: .cancel) {}
        } message: {
            Text(T("Leer lassen, um wieder den Absender zu zeigen."))
        }
    }

    private var teilenText: String {
        [sendung.titel + " (\(sendung.dienstName))", sendung.nummer.isEmpty ? "" : T("Sendung %1", sendung.nummer), sendung.verfolgenURL?.absoluteString ?? ""]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Sendung mit dem, was DHL mit der Postleitzahl zusätzlich weiß (Termin, Orte)
    private var anzeige: Sendung {
        var s = sendung
        if let m = kern.mehr[sendung.nummer] {
            if !s.fertig && !m.erwartet.isEmpty && s.erwartet.isEmpty { s.erwartet = m.erwartet; s.zeitfenster = m.zeitfenster }
            if m.ereignisse.count >= s.ereignisse.count && m.ereignisse.contains(where: { !$0.ort.isEmpty }) { s.ereignisse = m.ereignisse }
        }
        s.ereignisse = Self.ohneDoppelte(s.ereignisse)
        return s
    }

    /// Gleiche Meldung zur gleichen Minute nur einmal (kommt doppelt, wenn zwei Quellen sie liefern)
    static func ohneDoppelte(_ e: [Ereignis]) -> [Ereignis] {
        var gesehen = Set<String>()
        return e.filter { x in
            let minute = x.zeit.map { Int($0.timeIntervalSince1970 / 60) } ?? -1
            return gesehen.insert("\(minute)|\(x.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))").inserted
        }
    }

    private var kopf: some View {
        let s = anzeige
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                DienstLogo(dienst: s.dienst, groesse: 58)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if s.ruecksendung { Etikett(text: T("Rücksendung"), farbe: .purple) }
                        Text(s.dienstName).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        if fragt { ProgressView().controlSize(.mini) }
                    }
                    Text(s.titel).font(.title2.weight(.bold)).lineLimit(2)
                    if let a = absenderZeile { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            TerminZeile(sendung: s)
            VStack(alignment: .leading, spacing: 5) {
                Fortschritt(sendung: s, hoehe: 6)
                HStack {
                    Text(T("angekündigt")); Spacer(); Text(T("unterwegs")); Spacer(); Text(T("in Zustellung")); Spacer(); Text(T("zugestellt"))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
            if !s.statusText.isEmpty {
                Text(s.statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Abholcode, oder ein Foto (z. B. QR-Code fürs Rücksendeetikett) bei Rücksendungen und zum Abholen
    private var kannVorzeigen: Bool {
        (sendung.zumAbholen && !sendung.abholcode.isEmpty) || (foto != nil && (sendung.ruecksendung || sendung.zumAbholen || !sendung.fertig))
    }

    /// Absender unter dem Namen: aus der Mail oder von DHL (mit PLZ)
    private var absenderZeile: String? {
        if !sendung.name.isEmpty && !sendung.absender.isEmpty && sendung.name != sendung.absender { return sendung.absender }
        if let a = kern.mehr[sendung.nummer]?.absender, !a.isEmpty, a != sendung.titel { return a }
        return nil
    }

    private var knoepfe: some View {
        HStack(spacing: 10) {
            if let u = sendung.verfolgenURL {
                Link(destination: u) { AktionsInhalt(titel: T("Beim Dienst"), symbol: "safari") }
            }
            if kannVorzeigen {
                Button { vorzeigen = true } label: { AktionsInhalt(titel: T("Vorzeigen"), symbol: "qrcode") }
            }
            if sendung.erledigt {
                Button { Task { await kern.erledigt(sendung, false) } } label: { AktionsInhalt(titel: T("Doch nicht da"), symbol: "arrow.uturn.backward") }
            } else if !sendung.fertig {
                Button { Task { await kern.erledigt(sendung, true) } } label: { AktionsInhalt(titel: T("Angekommen"), symbol: "checkmark", hervorgehoben: true) }
            }
            Menu {
                Button { neuerName = sendung.name; umbenennen = true } label: { Label(T("Umbenennen"), systemImage: "pencil") }
                if !sendung.nummer.isEmpty {
                    Button { Zwischenablage.kopieren(sendung.nummer); kern.meldung = T("Nummer kopiert") } label: {
                        Label(T("Nummer kopieren"), systemImage: "doc.on.doc")
                    }
                }
                if !sendung.fertig, let u = Dienst.paketsteuerung(sendung.dienst, sendung.nummer) {
                    Link(destination: u) { Label(T("Zustellung umleiten (Nachbar, Ablageort) …"), systemImage: "arrow.triangle.branch") }
                }
                if sendung.manuell {
                    Button(role: .destructive) { Task { await kern.entfernen(sendung) } } label: { Label(T("Entfernen"), systemImage: "trash") }
                }
            } label: {
                AktionsInhalt(titel: T("Mehr"), symbol: "ellipsis")
            }
            .menuIndicator(.hidden)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var verlauf: some View {
        let ereignisse = anzeige.ereignisse
        VStack(alignment: .leading, spacing: 0) {
            Text(T("Verlauf")).font(.headline).padding(.bottom, 8)
            if ereignisse.isEmpty {
                Text(sendung.verfolgenURL == nil ? T("Noch keine Stationen bekannt.")
                     : T("Noch keine Stationen bekannt. Den genauen Verlauf zeigt die Seite des Dienstes – oder unter Einstellungen → Direkt verfolgen einen Anbieter eintragen."))
                    .font(.callout).foregroundStyle(.secondary)
                if !kern.anbieterFehler.isEmpty && !fragt {
                    ForEach(kern.anbieterFehler.sorted(by: { $0.key < $1.key }), id: \.key) { e in
                        Label("\(e.key): \(e.value)", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(ereignisse.enumerated()), id: \.offset) { i, e in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(i == 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 11, height: 11)
                            .padding(.top, 4)
                        if i < ereignisse.count - 1 {
                            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                        }
                    }
                    .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.text).font(i == 0 ? .body.weight(.semibold) : .body)
                        Text([Texte.ereigniszeit(e.zeit), e.ort].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 14)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Notiz und Foto (bleiben auf diesem Gerät)
    private var notizUndFoto: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sendung.quelle == "ha" && kern.einstellungen.eingerichtet ? T("Notiz für den Haushalt und Foto") : T("Notiz und Foto")).font(.headline)
            TextField(T("z. B. „Beim Nachbarn Nr. 12“ oder „Hab ich angenommen“"), text: $notiz, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await kern.notizTeilen(sendung, notiz) } }
                .onChange(of: notiz) { _, t in kern.notizSetzen(sendung.id, t) }
                .onDisappear { Task { await kern.notizTeilen(sendung, notiz) } }
            if !sendung.notiz.isEmpty && !sendung.notizVon.isEmpty {
                Text(T("von %1", sendung.notizVon) + (sendung.notizZeit.map { " · " + Texte.ereigniszeit($0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                PhotosPicker(selection: $fotoWahl, matching: .images) {
                    Label(foto == nil ? T("Foto hinzufügen (z. B. Rücksende-QR)") : T("Foto ersetzen"), systemImage: "photo")
                }
                if foto != nil {
                    Button(role: .destructive) { FotoAblage.loeschen(sendung.id); foto = nil } label: { Label(T("Foto entfernen"), systemImage: "trash") }
                }
            }
            .buttonStyle(.bordered)
            if let foto {
                foto.resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func fotoLaden() {
        foto = FotoAblage.bild(sendung.id)
    }

    private var angaben: some View {
        VStack(alignment: .leading, spacing: 6) {
            zeile(T("Dienst"), sendung.dienstName)
            zeile(T("Quelle"), sendung.quelle == "direkt" ? T("direkt verfolgt") + (sendung.anbieter.isEmpty ? "" : " · " + sendung.anbieter)
                              : T("Home Assistant") + (sendung.anbieter.isEmpty ? "" : " · " + sendung.anbieter))
            if !sendung.nummer.isEmpty { zeile(T("Sendungsnummer"), sendung.nummer) }
            if !sendung.kundenkonto.isEmpty { zeile(T("Kundenkonto"), sendung.kundenkonto) }
            if kern.mehrereKonten && !sendung.kontoName.isEmpty { zeile(T("Postfach"), sendung.kontoName) }
            zeile(T("Letzte Meldung"), sendung.datum.formatted(date: .abbreviated, time: .shortened))
            if sendung.manuell { zeile(T("Hinzugefügt"), T("von Hand")) }
            if let m = kern.mehr[sendung.nummer] {
                if !m.absender.isEmpty { zeile(T("Absender (DHL)"), m.absender) }
                if !m.empfaenger.isEmpty { zeile(T("Adressiert an"), m.empfaenger) }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func zeile(_ a: String, _ b: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(a).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(b)
            Spacer(minLength: 0)
        }
    }
}

/// Karte mit den Orten aus dem Verlauf (Orte werden nachgeschlagen und gemerkt)
struct StationenKarte: View {
    let ereignisse: [Ereignis]
    @State private var punkte: [(ort: String, koordinate: CLLocationCoordinate2D)] = []

    var body: some View {
        Map {
            ForEach(Array(punkte.enumerated()), id: \.offset) { i, p in
                Marker(p.ort, systemImage: i == 0 ? "shippingbox.fill" : "circle.fill", coordinate: p.koordinate)
                    .tint(i == 0 ? Color.accentColor : .gray)
            }
            if punkte.count > 1 {
                MapPolyline(coordinates: punkte.reversed().map(\.koordinate)).stroke(Color.accentColor.opacity(0.7), lineWidth: 3)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .task(id: ereignisse.map(\.ort).joined()) { await nachschlagen() }
        .overlay { if punkte.isEmpty { ProgressView() } }
    }

    private func nachschlagen() async {
        var orte: [String] = []
        for e in ereignisse where !e.ort.isEmpty && !orte.contains(e.ort) { orte.append(e.ort) }
        var neu: [(String, CLLocationCoordinate2D)] = []
        for ort in orte.prefix(8) {
            if let k = await Orte.koordinate(ort) { neu.append((ort, k)) }
        }
        punkte = neu
    }
}

/// Orte nachschlagen (mit Zwischenspeicher – Apple begrenzt die Anfragen)
@MainActor
enum Orte {
    static var gemerkt: [String: CLLocationCoordinate2D] = [:]

    static func koordinate(_ ort: String) async -> CLLocationCoordinate2D? {
        if let k = gemerkt[ort] { return k }
        let d = UserDefaults.standard
        if let a = d.array(forKey: "ort2." + ort) as? [Double], a.count == 2 {
            let k = CLLocationCoordinate2D(latitude: a[0], longitude: a[1])
            gemerkt[ort] = k
            return k
        }
        // Mitteleuropa bevorzugen („Hamburg“ ist sonst womöglich Hamburg in New York)
        let europa = CLCircularRegion(center: CLLocationCoordinate2D(latitude: 50.5, longitude: 10.5), radius: 1_200_000, identifier: "europa")
        guard let ergebnis = try? await CLGeocoder().geocodeAddressString(ort, in: europa) else { return nil }
        let nah = ergebnis.first { p in p.location.map { europa.contains($0.coordinate) } ?? false }
        guard let k = (nah ?? ergebnis.first)?.location?.coordinate else { return nil }
        gemerkt[ort] = k
        d.set([k.latitude, k.longitude], forKey: "ort2." + ort)
        return k
    }
}

/// Fotos zu Sendungen (JPEG auf dem Gerät)
enum FotoAblage {
    static func speichern(_ daten: Data, _ id: String) throws {
        #if canImport(UIKit)
        let jpeg = UIImage(data: daten).flatMap { $0.jpegData(compressionQuality: 0.8) } ?? daten
        #else
        let jpeg = NSBitmapImageRep(data: daten)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) ?? daten
        #endif
        try jpeg.write(to: DirektListe.foto(id), options: .atomic)
    }

    static func bild(_ id: String) -> Image? {
        guard let d = try? Data(contentsOf: DirektListe.foto(id)) else { return nil }
        #if canImport(UIKit)
        return UIImage(data: d).map { Image(uiImage: $0) }
        #else
        return NSImage(data: d).map { Image(nsImage: $0) }
        #endif
    }

    static func loeschen(_ id: String) { try? FileManager.default.removeItem(at: DirektListe.foto(id)) }
}

/// Abholen: Code groß (zum Abtippen an der Packstation), Abholstelle mit Karte und Route, Frist
struct AbholKarte: View {
    let kern: Kern
    let sendung: Sendung
    @State private var ziel: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(T("Zur Abholung bereit"), systemImage: "shippingbox.and.arrow.backward").font(.headline).foregroundStyle(.orange)
            if !sendung.abholcode.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(T("Abholcode")).font(.caption).foregroundStyle(.secondary)
                        Text(sendung.abholcode)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .kerning(4)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button { Zwischenablage.kopieren(sendung.abholcode); kern.meldung = T("Abholcode kopiert") } label: {
                        Label(T("Kopieren"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !sendung.abholort.isEmpty || !sendung.abholadresse.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !sendung.abholort.isEmpty { Text(sendung.abholort).font(.body.weight(.semibold)) }
                    if !sendung.abholadresse.isEmpty { Text(sendung.abholadresse).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            if let frist = Texte.tagAus(sendung.abholfrist) {
                Label(T("Abholen bis %1", Texte.kurzTag(frist)), systemImage: "clock").font(.callout.weight(.medium))
                    .foregroundStyle(frist.timeIntervalSinceNow < 86400 * 2 ? Color.red : Color.primary)
            }
            if let ziel {
                Map(initialPosition: .region(MKCoordinateRegion(center: ziel, latitudinalMeters: 900, longitudinalMeters: 900))) {
                    Marker(sendung.abholort.isEmpty ? T("Abholstelle") : sendung.abholort, systemImage: "shippingbox.fill", coordinate: ziel).tint(.orange)
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !sendung.abholadresse.isEmpty {
                Button { route() } label: { Label(T("Route zur Abholstelle"), systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: sendung.abholadresse) {
            guard !sendung.abholadresse.isEmpty else { return }
            ziel = await Orte.koordinate(sendung.abholadresse)
        }
    }

    private func route() {
        let ort = (sendung.abholort.isEmpty ? "" : sendung.abholort + ", ") + sendung.abholadresse
        let q = ort.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let u = URL(string: "https://maps.apple.com/?daddr=\(q)&dirflg=w") { kern.oeffnen(u) }
    }
}

/// Rückgabefrist eines zugestellten Pakets mit Erinnerung
struct RueckgabeKarte: View {
    let kern: Kern
    let sendung: Sendung
    let bis: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward.circle.fill").font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Rückgabe bis %1", Texte.kurzTag(bis))).font(.headline)
                Text(T("Rücksendefrist laut Shop (ohne Gewähr)")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(T("Erinnern")) { Task { await kern.rueckgabeErinnern(sendung, bis: bis) } }.buttonStyle(.bordered)
        }
        .padding()
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Großer Termin: Kalenderblatt + „Voraussichtliche Zustellung · Samstag, 7. November“ (sonst der Stand)
struct TerminZeile: View {
    let sendung: Sendung

    var body: some View {
        let farbe = standFarbe(sendung)
        HStack(spacing: 12) {
            if let d = sendung.erwartetTag(), !sendung.fertig {
                VStack(spacing: 0) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                    Text(d.formatted(.dateTime.day()))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 48, height: 50)
                .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Voraussichtliche Zustellung")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(d.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.headline)
                    Text(Texte.stand(sendung)).font(.subheadline.weight(.medium)).foregroundStyle(farbe)
                }
            } else {
                Image(systemName: sendung.fertig ? "checkmark.circle.fill" : sendung.problem ? "exclamationmark.triangle.fill" : sendung.stand == "abholbereit" ? "building.2.fill" : "shippingbox.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(sendung.fertig ? Color.green : farbe == .secondary ? Color.accentColor : farbe)
                    .frame(width: 48, height: 50)
                Text(Texte.stand(sendung)).font(.headline).foregroundStyle(farbe == .secondary ? Color.primary : farbe)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Inhalt eines Aktionsknopfs: Symbol über kurzem Text, alle gleich groß
struct AktionsInhalt: View {
    let titel: String
    let symbol: String
    var hervorgehoben = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(height: 22)
            Text(titel).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(hervorgehoben ? Color.white : Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(hervorgehoben ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.13)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// DHL-Live-Verfolgung: „Nur noch 4 Zustellstopps“
struct LiveKarte: View {
    let text: String
    var zeit: Date?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "box.truck.badge.clock.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Live von DHL")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.headline)
                if let zeit { Text(T("Stand %1", zeit.formatted(date: .omitted, time: .shortened))).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
