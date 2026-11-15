import SwiftUI
import WatchConnectivity
import PaketKern

/// Paketbote auf der Apple Watch: Heute und Unterwegs. Den Zugang schickt das iPhone; danach lädt die Uhr selbst.
@main
struct PaketboteUhr: App {
    @State private var zustand = UhrZustand.shared
    var body: some Scene {
        WindowGroup {
            NavigationStack { UhrListe(zustand: zustand) }
                .task { zustand.starten(); await zustand.laden() }
        }
    }
}

@MainActor
@Observable
final class UhrZustand: NSObject, WCSessionDelegate {
    static let shared = UhrZustand()
    private(set) var uebersicht: Uebersicht?
    private(set) var fehler = ""
    @ObservationIgnored private var ha = HomeAssistant(adresse: "", token: "")
    @ObservationIgnored private let d = UserDefaults.standard

    override init() {
        super.init()
        Sprache.laden()
        ha = HomeAssistant(adresse: d.string(forKey: "adresse") ?? "", token: d.string(forKey: "token") ?? "", konto: d.string(forKey: "konto") ?? "")
        if let s = d.data(forKey: "stand") { uebersicht = Self.lesen(s) }
    }

    static func lesen(_ d: Data) -> Uebersicht? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Uebersicht.self, from: d)
    }

    func starten() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func laden() async {
        guard ha.eingerichtet else { fehler = uebersicht == nil ? T("Post & Pakete auf dem iPhone öffnen.") : ""; return }
        do {
            var u = try await ha.laden()
            u.sendungen = zusammenfuehren(ha: u.sendungen, direkt: (uebersicht?.sendungen ?? []).filter { $0.quelle == "direkt" })
            uebersicht = u
            fehler = ""
        } catch let f as HAFehler {
            fehler = f.text
        } catch {
            fehler = error.localizedDescription
        }
    }

    nonisolated func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let k = s.receivedApplicationContext
        Task { @MainActor in self.uebernehmen(k) }
    }

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext k: [String: Any]) {
        Task { @MainActor in self.uebernehmen(k) }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ s: WCSession) {}
    nonisolated func sessionDidDeactivate(_ s: WCSession) { s.activate() }
    #endif

    private func uebernehmen(_ k: [String: Any]) {
        guard let a = k["adresse"] as? String else { return }
        let t = k["token"] as? String ?? "", konto = k["konto"] as? String ?? ""
        d.set(a, forKey: "adresse"); d.set(t, forKey: "token"); d.set(konto, forKey: "konto")
        ha = HomeAssistant(adresse: a, token: t, konto: konto)
        if let s = k["stand"] as? Data, let u = Self.lesen(s) { uebersicht = u; d.set(s, forKey: "stand") }
        Task { await laden() }
    }
}

struct UhrListe: View {
    let zustand: UhrZustand
    var body: some View {
        let g = Gruppen(zustand.uebersicht?.sendungen ?? [])
        let b = BriefGruppen(zustand.uebersicht?.briefe ?? [])
        List {
            if !zustand.fehler.isEmpty { Text(zustand.fehler).font(.footnote).foregroundStyle(.secondary) }
            if !b.heute.isEmpty {
                Section(T("Briefe heute")) {
                    ForEach(b.heute) { br in
                        Label { Text(br.titel).lineLimit(2) } icon: { Image(systemName: br.wichtig ? "envelope.badge.fill" : "envelope.fill").foregroundStyle(br.wichtig ? .red : .primary) }
                    }
                }
            }
            if !g.heute.isEmpty { Section(T("Heute")) { ForEach(g.heute) { UhrZeile(sendung: $0) } } }
            if !g.unterwegs.isEmpty { Section(T("Unterwegs")) { ForEach(g.unterwegs) { UhrZeile(sendung: $0) } } }
            if g.aktiv.isEmpty && zustand.fehler.isEmpty { Text(T("Keine Pakete unterwegs")).foregroundStyle(.secondary) }
        }
        .navigationTitle(T("Post & Pakete"))
        .refreshable { await zustand.laden() }
    }
}

struct UhrZeile: View {
    let sendung: Sendung
    var body: some View {
        NavigationLink {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sendung.titel).font(.headline)
                    Text(Texte.stand(sendung)).foregroundStyle(standFarbe(sendung))
                    ForEach(sendung.ereignisse.prefix(8)) { e in
                        VStack(alignment: .leading) {
                            Text(e.text).font(.footnote)
                            Text([Texte.ereigniszeit(e.zeit), e.ort].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(sendung.dienstName)
        } label: {
            HStack {
                DienstLogo(dienst: sendung.dienst, groesse: 30)
                VStack(alignment: .leading) {
                    Text(sendung.titel).font(.headline).lineLimit(1)
                    Text(Texte.stand(sendung)).font(.caption).foregroundStyle(standFarbe(sendung)).lineLimit(2)
                }
            }
        }
    }
}
