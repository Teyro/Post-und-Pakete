import SwiftUI
import PaketKern

/// Einstellungen: Home Assistant, Postfach, Mitteilungen, Hinweise zur Integration
struct EinstellungenAnsicht: View {
    @Bindable var kern: Kern
    @Environment(\.dismiss) private var schliessen
    @State private var pruefung = ""
    @State private var prueft = false

    var body: some View {
        @Bindable var e = kern.einstellungen
        Form {
            Section {
                TextField(T("Adresse, z. B. http://homeassistant.local:8123"), text: $e.adresse)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(T("Langlebiges Zugriffstoken"), text: $e.token)
                HStack {
                    Button(T("Verbindung prüfen")) { pruefen() }.disabled(!e.eingerichtet || prueft)
                    if prueft { ProgressView().controlSize(.small) }
                }
                if !pruefung.isEmpty { Text(pruefung).font(.callout).foregroundStyle(.secondary) }
            } header: {
                Text(T("Home Assistant"))
            } footer: {
                Text(T("Das Token legst du in Home Assistant an: unten links auf deinen Namen → Sicherheit → Langlebige Zugriffstoken."))
            }

            Section {
                TextField(T("Postleitzahl, z. B. 22087"), text: $e.plz)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onChange(of: e.plz) { _, neu in
                        let n = String(neu.filter(\.isNumber).prefix(5))
                        if n != neu { e.plz = n }
                    }
            } header: {
                Text(T("DHL mit Postleitzahl"))
            } footer: {
                Text(T("Wie auf dhl.de nach „PLZ eingeben“: Absender, Empfänger und die Orte im Verlauf. Die Postleitzahl geht nur an DHL."))
            }

            DirektEinstellungen(kern: kern)

            if let konten = kern.daten?.konten, konten.count > 1 {
                Section(T("Postfach")) {
                    Picker(T("Zeigen"), selection: $e.konto) {
                        Text(T("Alle")).tag("")
                        ForEach(konten) { Text($0.name).tag($0.name) }
                    }
                }
            }

            Section {
                Toggle(T("Mitteilungen bei neuem Stand"), isOn: $e.mitteilungen)
                    .onChange(of: e.mitteilungen) { _, an in if an { Task { await kern.mitteilungenErlauben() } } }
                Stepper(T("Zugestellte %1 Tage zeigen", "\(e.tageZugestellt)"), value: $e.tageZugestellt, in: 1...60)
                #if os(iOS)
                Toggle(T("Live-Aktivität für Pakete, die heute kommen"), isOn: $e.liveAktivitaet)
                #endif
                Toggle(T("Nach der Zustellung an die Rücksendefrist erinnern"), isOn: $e.rueckgabeErinnern)
            } header: {
                Text(T("Anzeige"))
            } footer: {
                Text(T("Die App meldet sich, wenn sie neu lädt. Zuverlässiger im Hintergrund: in der Integration „Mitteilungen an“ die Home-Assistant-App wählen."))
            }

            Section {
                Toggle(T("Automatisch nach Updates suchen"), isOn: $e.autoUpdate)
            } header: {
                Text(T("Updates"))
            } footer: {
                #if os(macOS)
                Text(T("Neue Versionen werden geladen, geprüft und installiert; die App startet dann kurz neu."))
                #else
                Text(T("Eine selbst signierte App kann sich nicht selbst installieren. Bei einer neuen Version kommt eine Mitteilung mit einem Link zur IPA – die dann wie gewohnt signieren."))
                #endif
            }

            if e.eingerichtet { WidgetDiagnose(kern: kern) }

            if let k = kern.daten?.konten.first {
                Section(T("Sendungsverfolgung in Home Assistant")) {
                    LabeledContent(T("DHL live"), value: k.dhlLive ? T("an") : T("aus – DHL-Schlüssel in der Integration"))
                    LabeledContent(T("17TRACK"), value: k.siebzehn ? (k.siebzehnRest.map { T("an – noch %1 Sendungen frei", "\($0)") } ?? T("an")) : T("aus – Schlüssel in der Integration"))
                }
            }

            Section(T("Über")) {
                LabeledContent(T("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                Link(T("Post & Pakete auf GitHub"), destination: URL(string: "https://github.com/Teyro/Post-und-Pakete")!)
                Link(T("Integration „Briefankündigung“ (HACS)"), destination: URL(string: "https://github.com/Teyro/Briefankuendigung-HA")!)
                if !Ablage.gruppeDa {
                    Text(T("Widgets: Die Signatur (z. B. Signulous) erlaubt keine App-Gruppe. Das Widget lange drücken → „Widget bearbeiten“ → Home-Assistant-Adresse und Token eintragen; direkt verfolgte Sendungen zeigt es nach dem nächsten Öffnen der App."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(T("Einstellungen"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(T("Fertig")) {
                    schliessen()
                    Task { await kern.laden() }
                }
            }
        }
    }

    private func pruefen() {
        prueft = true
        pruefung = ""
        let ha = kern.ha
        Task {
            do {
                let u = try await ha.laden()
                let offen = u.sendungen.filter { !$0.fertig }.count
                pruefung = T("Verbunden – %1 Postfächer, %2 unterwegs.", "\(u.konten.count)", Texte.anzahl(offen))
                if u.version < 4 { pruefung += " " + T("Für Verlauf und Umbenennen die Integration auf 1.5 aktualisieren.") }
            } catch let f as HAFehler {
                pruefung = f.text
            } catch {
                pruefung = error.localizedDescription
            }
            prueft = false
        }
    }
}

/// Direkt verfolgen: Anbieter wählen (an/aus) und ihre Schlüssel – der Reihe nach gefragt, der nächste springt ein
struct DirektEinstellungen: View {
    @Bindable var kern: Kern
    var body: some View {
        @Bindable var e = kern.einstellungen
        Section {
            ForEach(Verfolgung.beschreibung, id: \.name) { a in
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { e.schluessel.an(a.name) }, set: { e.schluessel.setzen(a.name, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name)
                            Text(a.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if e.schluessel.an(a.name) {
                        switch a.name {
                        case "DHL": SecureField(T("DHL-API-Schlüssel"), text: $e.schluessel.dhl)
                        case "UPS":
                            SecureField(T("UPS Client-ID"), text: $e.schluessel.upsId)
                            SecureField(T("UPS Client-Secret"), text: $e.schluessel.upsGeheim)
                        case "17TRACK": SecureField(T("17TRACK-Schlüssel"), text: $e.schluessel.siebzehn)
                        case "Ship24": SecureField(T("Ship24-Schlüssel"), text: $e.schluessel.ship24)
                        default: EmptyView()
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            Toggle(T("Öffentliche Seiten fragen (DHL ohne Schlüssel, GLS, DPD)"), isOn: $e.schluessel.oeffentlich)
            if e.eingerichtet {
                Toggle(T("Auch in Home Assistant eintragen"), isOn: $e.auchInHA)
            }
        } header: {
            Text(T("Direkt verfolgen – Anbieter"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(T("Post & Pakete fragt die eingeschalteten Anbieter der Reihe nach. Antwortet einer nicht oder kennt die Nummer nicht, springt der nächste ein. DHL und Deutsche Post gehen ohne Schlüssel; für Hermes, DPD, GLS und UPS hilft ein 17TRACK- oder Ship24-Schlüssel. Die Schlüssel bleiben im Schlüsselbund dieses Geräts."))
                Link(T("DHL-Schlüssel (kostenlos)"), destination: URL(string: "https://developer.dhl.com")!)
                Link(T("UPS-Zugang (kostenlos)"), destination: URL(string: "https://developer.ups.com")!)
                Link(T("17TRACK-Schlüssel (200 Sendungen frei)"), destination: URL(string: "https://api.17track.net")!)
                Link(T("Ship24-Schlüssel"), destination: URL(string: "https://www.ship24.com/tracking-api")!)
            }
        }
    }
}

/// Was die Widgets an Home Assistant melden (ab Integration 1.9): startet das Widget, hat es Zugang, welcher Fehler?
struct WidgetDiagnose: View {
    let kern: Kern
    @State private var berichte: [(zeit: Date?, quelle: String, bericht: String)] = []
    @State private var geladen = false
    @State private var fehler = ""

    var body: some View {
        Section {
            Button(geladen ? T("Neu laden") : T("Berichte der Widgets laden")) { Task { await laden() } }
            if !fehler.isEmpty { Text(fehler).font(.callout).foregroundStyle(.red) }
            if geladen && berichte.isEmpty && fehler.isEmpty {
                Text(T("Noch kein Bericht. Dann startet iOS das Widget gar nicht – oder es hat keinen Zugang: Widget lange drücken → „Widget bearbeiten“ → Adresse und Token eintragen und eine Minute warten."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(berichte.prefix(8).enumerated()), id: \.offset) { _, b in
                VStack(alignment: .leading, spacing: 2) {
                    Text((b.zeit?.formatted(date: .abbreviated, time: .standard) ?? "–") + " · " + b.quelle).font(.caption).foregroundStyle(.secondary)
                    Text(b.bericht).font(.callout).textSelection(.enabled)
                }
            }
        } header: {
            Text(T("Widget-Diagnose"))
        } footer: {
            Text(T("Die Widgets schicken bei jedem Aktualisieren einen kurzen Bericht an Home Assistant (ohne Token und Inhalte)."))
        }
    }

    private func laden() async {
        do {
            berichte = try await kern.ha.diagnoseBerichte()
            fehler = ""
        } catch let f as HAFehler {
            fehler = f.status == 404 ? T("Dafür die Integration in Home Assistant auf 1.9 aktualisieren.") : f.text
        } catch {
            fehler = error.localizedDescription
        }
        geladen = true
    }
}
