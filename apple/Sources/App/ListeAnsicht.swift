import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import PaketKern

/// Hauptansicht: Liste links (bzw. oben), Sendung rechts (bzw. beim Antippen)
struct Hauptansicht: View {
    @Bindable var kern: Kern

    var body: some View {
        NavigationSplitView {
            SendungsListe(kern: kern)
                .navigationTitle(T("Post & Pakete"))
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
                #endif
        } detail: {
            if let s = kern.sendung(kern.auswahl) {
                DetailAnsicht(kern: kern, sendung: s)
            } else if let b = kern.brief(kern.auswahl) {
                BriefDetail(kern: kern, brief: b)
            } else {
                ContentUnavailableView(T("Nichts gewählt"), systemImage: "tray", description: Text(T("Links einen Brief oder ein Paket wählen.")))
            }
        }
        .sheet(isPresented: $kern.hinzufuegenOffen) {
            HinzufuegenAnsicht(kern: kern)
        }
        .sheet(isPresented: $kern.statistikOffen) {
            NavigationStack { StatistikAnsicht(kern: kern) }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 600)
                #endif
        }
        .sheet(isPresented: $kern.einstellungenOffen) {
            NavigationStack { EinstellungenAnsicht(kern: kern) }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        .overlay(alignment: .bottom) { MeldungsBand(kern: kern) }
        .task {
            await kern.laden()
            if !kern.bereit && !kern.vorschau { kern.einstellungenOffen = true }
        }
    }
}

/// Kurze Meldung unten (verschwindet nach ein paar Sekunden)
struct MeldungsBand: View {
    let kern: Kern
    var body: some View {
        if !kern.meldung.isEmpty {
            Text(kern.meldung)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: kern.meldung) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { kern.meldung = "" }
                }
        }
    }
}

struct SendungsListe: View {
    @Bindable var kern: Kern
    @State private var zugestelltOffen = true
    @State private var umbenennen: Sendung?
    @State private var neuerName = ""

    var body: some View {
        @Bindable var e = kern.einstellungen
        let bereich = e.bereich
        let mitPaketen = bereich != "briefe", mitBriefen = bereich != "pakete"
        let g = mitPaketen ? kern.gruppen : Gruppen()
        let b = mitBriefen ? kern.briefGruppen : BriefGruppen()
        let leer = g.aktiv.isEmpty && g.zugestellt.isEmpty && b.offen.isEmpty && b.angekommen.isEmpty
        // Unterwegs nach Liefertag gegliedert (früheste zuerst), ohne Termin am Ende
        let nachTag = Dictionary(grouping: g.unterwegs.filter { !$0.erwartet.isEmpty }, by: \.erwartet)
        let ohneTermin = g.unterwegs.filter { $0.erwartet.isEmpty }
        List(selection: $kern.auswahl) {
            if kern.einstellungen.eingerichtet {
                Picker(T("Zeigen"), selection: $e.bereich) {
                    Text(T("Alles")).tag("alle")
                    Text(kern.briefGruppen.offen.isEmpty ? T("Briefe") : T("Briefe (%1)", "\(kern.briefGruppen.offen.count)")).tag("briefe")
                    Text(kern.gruppen.aktiv.isEmpty ? T("Pakete") : T("Pakete (%1)", "\(kern.gruppen.aktiv.count)")).tag("pakete")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            if !kern.bereit {
                Section {
                    EinrichtenHinweis(kern: kern)
                }
            } else if !kern.fehler.isEmpty {
                Section {
                    Label(kern.fehler, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                }
            }
            if !g.heute.isEmpty || !b.heute.isEmpty {
                Section(T("Heute")) {
                    ForEach(b.heute) { briefZeile($0) }
                    ForEach(g.heute) { zeile($0) }
                }
            }
            ForEach(nachTag.keys.sorted(), id: \.self) { tag in
                Section(Self.tagUeberschrift(tag)) {
                    ForEach(nachTag[tag] ?? []) { zeile($0) }
                }
            }
            if !ohneTermin.isEmpty || !b.unterwegs.isEmpty {
                Section(nachTag.isEmpty ? T("Unterwegs") : T("Unterwegs ohne Termin")) {
                    ForEach(b.unterwegs) { briefZeile($0) }
                    ForEach(ohneTermin) { zeile($0) }
                }
            }
            if !g.zugestellt.isEmpty || !b.angekommen.isEmpty {
                Section(isExpanded: $zugestelltOffen) {
                    ForEach(b.angekommen.prefix(10)) { briefZeile($0) }
                    ForEach(g.zugestellt) { zeile($0) }
                } header: {
                    Text(T("Angekommen"))
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.sidebar)
        #endif
        .overlay {
            if kern.bereit && (kern.daten != nil || !kern.einstellungen.eingerichtet) && leer {
                ContentUnavailableView {
                    Label(bereich == "briefe" ? T("Keine Briefe angekündigt") : bereich == "pakete" ? T("Keine Pakete unterwegs") : T("Keine Post unterwegs"),
                          systemImage: bereich == "briefe" ? "envelope" : "shippingbox")
                } description: {
                    Text(kern.einstellungen.eingerichtet ? T("Versandmails von DHL, Hermes, DPD, GLS, UPS und Amazon erscheinen hier – oder eine Sendung mit ＋ hinzufügen.")
                         : T("Sendungsnummer mit ＋ eintragen oder den Paketschein scannen – Post & Pakete holt Stand, Verlauf und Karte."))
                } actions: {
                    Button(T("Sendung hinzufügen")) { kern.hinzufuegenOffen = true }.buttonStyle(.borderedProminent)
                }
            } else if kern.daten == nil && kern.laedt {
                ProgressView()
            }
        }
        .refreshable { await kern.laden() }
        .dropDestination(for: String.self) { texte, _ in
            guard let n = texte.lazy.compactMap({ Dienst.nummerIn($0) }).first else { return false }
            kern.hinzufuegenNummer = n
            kern.hinzufuegenOffen = true
            return true
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { kern.hinzufuegenOffen = true } label: { Label(T("Sendung hinzufügen"), systemImage: "plus") }
                    .keyboardShortcut("n")
            }
            ToolbarItem {
                Menu {
                    if kern.einstellungen.eingerichtet {
                        Button { Task { await kern.jetztNachsehen() } } label: { Label(T("Postfach jetzt lesen"), systemImage: "envelope.arrow.triangle.branch") }
                    }
                    Button { Task { await kern.laden() } } label: { Label(T("Neu laden"), systemImage: "arrow.clockwise") }
                    Divider()
                    Button { kern.statistikOffen = true } label: { Label(T("Statistik"), systemImage: "chart.bar.xaxis") }
                    #if os(macOS)
                    Button { Drucken.liste(kern) } label: { Label(T("Drucken …"), systemImage: "printer") }
                    #endif
                    Button { kern.einstellungenOffen = true } label: { Label(T("Einstellungen …"), systemImage: "gearshape") }
                } label: {
                    Label(T("Mehr"), systemImage: "ellipsis.circle")
                }
            }
        }
        .alert(T("Umbenennen"), isPresented: Binding(get: { umbenennen != nil }, set: { if !$0 { umbenennen = nil } })) {
            TextField(T("Name"), text: $neuerName)
            Button(T("Sichern")) { if let s = umbenennen { Task { await kern.umbenennen(s, neuerName) } } }
            Button(T("Abbrechen"), role: .cancel) {}
        } message: {
            Text(T("Leer lassen, um wieder den Absender zu zeigen."))
        }
    }

    /// "2026-11-07" → „Morgen · Samstag, 7. November“ / „Samstag, 7. November“ / „Überfällig“
    static func tagUeberschrift(_ iso: String) -> String {
        let t = iso.split(separator: "-").compactMap { Int($0) }
        let k = Calendar.current
        guard t.count == 3, let d = k.date(from: DateComponents(year: t[0], month: t[1], day: t[2])) else { return iso }
        let tage = k.dateComponents([.day], from: k.startOfDay(for: Date()), to: d).day ?? 0
        let text = d.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if tage < 0 { return T("Überfällig") }
        if tage == 1 { return T("Morgen · %1", text) }
        return text
    }

    private func briefZeile(_ b: Brief) -> some View {
        BriefZeile(kern: kern, brief: b, mitKonto: kern.mehrereKonten)
            .tag(b.id)
            .contextMenu {
                Button { Task { await kern.briefErledigt(b, !b.erledigt) } } label: {
                    b.erledigt ? Label(T("Doch nicht angekommen"), systemImage: "arrow.uturn.backward") : Label(T("Angekommen"), systemImage: "checkmark")
                }
                Button { Task { await kern.erinnern(titel: T("Brief von %1", b.titel), notiz: "", in: 1) } } label: { Label(T("Morgen erinnern"), systemImage: "bell") }
            }
            .swipeActions(edge: .trailing) {
                Button { Task { await kern.briefErledigt(b, !b.erledigt) } } label: {
                    b.erledigt ? Label(T("Doch nicht"), systemImage: "arrow.uturn.backward") : Label(T("Angekommen"), systemImage: "checkmark")
                }.tint(.green)
            }
    }

    private func zeile(_ s: Sendung) -> some View {
        SendungsZeile(sendung: s, mitKonto: kern.mehrereKonten)
            .tag(s.id)
            .contextMenu { aktionen(s) }
            .swipeActions(edge: .trailing) {
                if s.manuell {
                    Button(role: .destructive) { Task { await kern.entfernen(s) } } label: { Label(T("Entfernen"), systemImage: "trash") }
                }
                if !s.fertig {
                    Button { Task { await kern.erledigt(s, true) } } label: { Label(T("Angekommen"), systemImage: "checkmark") }.tint(.green)
                }
            }
            .swipeActions(edge: .leading) {
                Button { neuerName = s.name; umbenennen = s } label: { Label(T("Umbenennen"), systemImage: "pencil") }.tint(.indigo)
            }
    }

    @ViewBuilder
    private func aktionen(_ s: Sendung) -> some View {
        if let u = s.verfolgenURL { Link(destination: u) { Label(T("Beim Dienst verfolgen"), systemImage: "safari") } }
        Button { neuerName = s.name; umbenennen = s } label: { Label(T("Umbenennen"), systemImage: "pencil") }
        if !s.nummer.isEmpty {
            Button { Zwischenablage.kopieren(s.nummer) } label: { Label(T("Nummer kopieren"), systemImage: "doc.on.doc") }
        }
        if s.erledigt {
            Button { Task { await kern.erledigt(s, false) } } label: { Label(T("Doch nicht angekommen"), systemImage: "arrow.uturn.backward") }
        } else if !s.fertig {
            Button { Task { await kern.erledigt(s, true) } } label: { Label(T("Angekommen"), systemImage: "checkmark") }
        }
        if s.manuell {
            Button(role: .destructive) { Task { await kern.entfernen(s) } } label: { Label(T("Entfernen"), systemImage: "trash") }
        }
    }
}

/// Ein Brief: Umschlag (Bild von der Post), Absender, angekündigt wann
struct BriefZeile: View {
    let kern: Kern
    let brief: Brief
    var mitKonto = false

    var body: some View {
        HStack(spacing: 12) {
            Umschlag(kern: kern, brief: brief)
                .frame(width: 64, height: 44)
                .opacity(brief.erledigt ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if brief.wichtig && !brief.erledigt { Etikett(text: T("Wichtig"), farbe: .red) }
                    Text(brief.titel).font(.body.weight(.semibold)).lineLimit(1)
                }
                Text(Texte.brief(brief, mitKonto: mitKonto))
                    .font(.subheadline)
                    .foregroundStyle(brief.heute() && !brief.erledigt ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Umschlag: das Bild der Post (aus Home Assistant, zwischengespeichert) – sonst ein gezeichneter Umschlag
struct Umschlag: View {
    let kern: Kern
    let brief: Brief
    var gross = false
    @State private var bild: Image?

    var body: some View {
        let form = RoundedRectangle(cornerRadius: gross ? 14 : 7, style: .continuous)
        ZStack {
            Color(red: 0.98, green: 0.97, blue: 0.94)
            if let bild {
                bild.resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(gross ? 6 : 2)
            } else {
                Image(systemName: brief.wichtig ? "envelope.badge.fill" : "envelope.fill")
                    .resizable().aspectRatio(contentMode: .fit)
                    .padding(gross ? 40 : 10)
                    .foregroundStyle(brief.wichtig ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.black.opacity(0.35)))
            }
        }
        .clipShape(form)
        .overlay(form.strokeBorder(brief.wichtig && !brief.erledigt ? Color.red.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: brief.wichtig ? 1.5 : 0.5))
        .task(id: brief.id) {
            guard brief.bild, let d = await Umschlaege.laden(brief.id, ha: kern.ha) else { return }
            #if canImport(UIKit)
            bild = UIImage(data: d).map { Image(uiImage: $0) }
            #else
            bild = NSImage(data: d).map { Image(nsImage: $0) }
            #endif
        }
        .accessibilityHidden(true)
    }
}

/// Eine Zeile: Logo, Name, Stand, Fortschritt
struct SendungsZeile: View {
    let sendung: Sendung
    var mitKonto = false

    var body: some View {
        HStack(spacing: 12) {
            DienstLogo(dienst: sendung.dienst, groesse: 44)
                .opacity(sendung.fertig ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if sendung.ruecksendung { Etikett(text: T("Rücksendung"), farbe: .purple) }
                    Text(sendung.titel)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                }
                Text(Texte.zeile(sendung, mitKonto: mitKonto))
                    .font(.subheadline)
                    .foregroundStyle(standFarbe(sendung))
                    .lineLimit(1)
                if !sendung.fertig { Fortschritt(sendung: sendung, hoehe: 4).frame(maxWidth: 180) }
                if let bis = sendung.rueckgabeBis, bis >= Calendar.current.startOfDay(for: Date()) {
                    Text(T("Rückgabe bis %1", Texte.kurzTag(bis))).font(.caption).foregroundStyle(.purple)
                }
            }
            Spacer(minLength: 0)
            if sendung.zumAbholen && !sendung.abholcode.isEmpty {
                Text(sendung.abholcode)
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
                    .accessibilityLabel(T("Abholcode %1", sendung.abholcode))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct EinrichtenHinweis: View {
    let kern: Kern
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(T("Willkommen bei Post & Pakete"), systemImage: "envelope.fill").font(.headline)
            Text(T("Einfach eine Sendungsnummer eintragen – oder mit Home Assistant verbinden: dann kommen die angekündigten Briefe und die Pakete aus deinen Versandmails dazu."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(T("Sendung hinzufügen")) { kern.einstellungen.direktModus = true; kern.hinzufuegenOffen = true }.buttonStyle(.borderedProminent)
                Button(T("Home Assistant …")) { kern.einstellungenOffen = true }.buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Zwischenablage für beide Systeme
enum Zwischenablage {
    static func kopieren(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static var text: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
