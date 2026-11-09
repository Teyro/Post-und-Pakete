import SwiftUI
import WidgetKit
import PaketKern

// Ansichten der Widgets – auch in der App für die Vorschau-Bilder benutzt.

/// Ein Eintrag im Widget: Brief oder Paket
enum Posten: Identifiable {
    case brief(Brief)
    case paket(Sendung)

    var id: String {
        switch self {
        case .brief(let b): b.id
        case .paket(let s): s.id
        }
    }
    var link: URL { URL(string: "paketbote://sendung/\(id)")! }
}

/// Was ein Widget zeigt
struct WidgetDaten {
    var uebersicht: Uebersicht?
    var eingerichtet: Bool
    var jetzt = Date()
    /// "alle" | "briefe" | "pakete"
    var inhalt = "alle"
    /// Fehler beim Laden (wird statt der Liste gezeigt, wenn nichts da ist)
    var fehler = ""
    /// „Angekommen“-Knöpfe zeigen (das Widget hat selbst Zugang zu Home Assistant)
    var knoepfe = false
    /// Widget ohne eigene Einstellungen (Zugang kommt von der App)
    var einfach = false

    var gruppen: Gruppen { inhalt == "briefe" ? Gruppen() : Gruppen(uebersicht?.sendungen ?? [], jetzt: jetzt) }
    var briefe: BriefGruppen { inhalt == "pakete" ? BriefGruppen() : BriefGruppen(uebersicht?.briefe ?? [], jetzt: jetzt) }
    var aktiv: [Sendung] { gruppen.aktiv }
    /// Heute: Briefe zuerst (wichtige vorn), dann Pakete
    var heute: [Posten] { briefe.heute.map(Posten.brief) + gruppen.heute.map(Posten.paket) }
    var unterwegs: [Posten] { briefe.unterwegs.map(Posten.brief) + gruppen.unterwegs.map(Posten.paket) }
    var alle: [Posten] { heute + unterwegs }

    /// „2 Briefe, 3 Pakete unterwegs“
    var titel: String {
        let b = briefe.offen.count, p = gruppen.aktiv.count
        if b == 0 && p == 0 { return inhalt == "briefe" ? T("Keine Briefe angekündigt") : inhalt == "pakete" ? T("Keine Pakete unterwegs") : T("Keine Post unterwegs") }
        return T("%1 unterwegs", [b > 0 ? Texte.briefe(b) : "", p > 0 ? Texte.anzahl(p) : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }
    var symbol: String { inhalt == "briefe" ? "envelope.fill" : inhalt == "pakete" ? "shippingbox.fill" : "tray.full.fill" }

    static var leer: WidgetDaten { WidgetDaten(uebersicht: nil, eingerichtet: false) }
}

func sendungsLink(_ s: Sendung) -> URL { URL(string: "paketbote://sendung/\(s.id)")! }

/// Kopf: Symbol, „2 Briefe, 3 Pakete unterwegs“, rechts „2 heute“
struct WidgetKopf: View {
    let daten: WidgetDaten
    var kompakt = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: daten.symbol)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: kompakt ? 12 : 14, weight: .semibold))
            Text(kompakt ? (daten.alle.isEmpty ? T("Post & Pakete") : T("%1 unterwegs", "\(daten.alle.count)")) : daten.titel)
                .font(.system(size: kompakt ? 12 : 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            if !daten.heute.isEmpty {
                Text(T("%1 heute", "\(daten.heute.count)"))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Color.accentColor, in: Capsule())
                    .fixedSize()
            }
        }
    }
}

/// Hinweis, wenn nichts unterwegs ist oder etwas fehlt
struct WidgetLeer: View {
    let daten: WidgetDaten
    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: !daten.eingerichtet ? "gearshape" : !daten.fehler.isEmpty ? "wifi.exclamationmark" : daten.inhalt == "briefe" ? "envelope" : "shippingbox")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(!daten.eingerichtet ? (Ablage.gruppeDa ? T("App öffnen und einrichten") : daten.einfach ? T("App öffnen → Einstellungen → „Widget verbinden“") : T("Widget lange drücken → „Widget bearbeiten“ → Home Assistant eintragen"))
                 : !daten.fehler.isEmpty ? daten.fehler : daten.titel)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            if let z = daten.gruppen.zugestellt.first {
                Text(T("Zuletzt: %1", z.titel)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Briefsymbol im Widget (das Umschlagbild laden Widgets nicht – zu groß für die Zeitleiste)
struct BriefSymbol: View {
    let brief: Brief
    var groesse: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: groesse * 0.26, style: .continuous)
            .fill(Color(red: 0.98, green: 0.97, blue: 0.94))
            .frame(width: groesse, height: groesse)
            .overlay {
                Image(systemName: brief.wichtig ? "envelope.badge.fill" : "envelope.fill")
                    .font(.system(size: groesse * 0.46, weight: .semibold))
                    .foregroundStyle(brief.wichtig ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color(red: 0.25, green: 0.24, blue: 0.2)))
            }
            .overlay(RoundedRectangle(cornerRadius: groesse * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// Eine Zeile im Widget
struct WidgetZeile: View {
    let posten: Posten
    var logo: CGFloat = 30
    var jetzt = Date()
    var body: some View {
        HStack(spacing: 9) {
            switch posten {
            case .paket(let s): DienstLogo(dienst: s.dienst, groesse: logo)
            case .brief(let b): BriefSymbol(brief: b, groesse: logo)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(titel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(zeile).font(.system(size: 11)).foregroundStyle(farbe).lineLimit(1)
            }
            Spacer(minLength: 0)
            if interaktiv, let id = haID { AngekommenKnopf(id: id) }
        }
    }

    /// „Angekommen“ direkt im Widget (nur für Sendungen und Briefe aus Home Assistant)
    var interaktiv = false
    private var haID: String? {
        switch posten {
        case .paket(let s): s.quelle == "ha" && !s.fertig ? s.id : nil
        case .brief(let b): b.erledigt ? nil : b.id
        }
    }

    private var titel: String {
        switch posten {
        case .paket(let s): s.titel
        case .brief(let b): b.titel
        }
    }
    private var zeile: String {
        switch posten {
        case .paket(let s) where s.zumAbholen && !s.abholcode.isEmpty: T("Abholcode %1", s.abholcode) + (s.abholort.isEmpty ? "" : " · " + s.abholort)
        case .paket(let s): Texte.zeile(s, jetzt: jetzt)
        case .brief(let b): (b.wichtig ? T("Wichtig") + " · " : "") + Texte.brief(b, jetzt: jetzt)
        }
    }
    private var farbe: Color {
        switch posten {
        case .paket(let s): standFarbe(s)
        case .brief(let b): b.wichtig ? .red : b.heute(jetzt: jetzt) ? .accentColor : .secondary
        }
    }
}

/// Klein: das Wichtigste
struct KleinesWidget: View {
    let daten: WidgetDaten
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetKopf(daten: daten, kompakt: true)
            if let p = daten.alle.first {
                Spacer(minLength: 0)
                switch p {
                case .paket(let s) where s.zumAbholen && !s.abholcode.isEmpty:
                    Text(s.titel).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(T("Abholcode")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(s.abholcode).font(.system(size: 26, weight: .bold, design: .monospaced)).minimumScaleFactor(0.6).lineLimit(1)
                    Text(s.abholort.isEmpty ? Texte.stand(s, jetzt: daten.jetzt) : s.abholort)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange).lineLimit(2)
                case .paket(let s):
                    DienstLogo(dienst: s.dienst, groesse: 42)
                    Text(s.titel).font(.system(size: 14, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text(Texte.stand(s, jetzt: daten.jetzt)).font(.system(size: 11, weight: .medium)).foregroundStyle(standFarbe(s)).lineLimit(2)
                    Fortschritt(sendung: s, hoehe: 4)
                case .brief(let b):
                    BriefSymbol(brief: b, groesse: 42)
                    Text(b.titel).font(.system(size: 14, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    Text(Texte.brief(b, jetzt: daten.jetzt)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(b.wichtig ? Color.red : Color.accentColor).lineLimit(2)
                }
            } else {
                WidgetLeer(daten: daten)
            }
        }
        .widgetURL(daten.alle.first?.link)
    }
}

/// Mittel: bis zu drei Einträge
struct MittleresWidget: View {
    let daten: WidgetDaten
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetKopf(daten: daten)
            if daten.alle.isEmpty {
                WidgetLeer(daten: daten)
            } else {
                ForEach(daten.alle.prefix(3)) { p in
                    Link(destination: p.link) { WidgetZeile(posten: p, jetzt: daten.jetzt, interaktiv: daten.knoepfe) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Groß: Heute und Unterwegs, bis zu sieben Einträge
struct GrossesWidget: View {
    let daten: WidgetDaten
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetKopf(daten: daten)
            if daten.alle.isEmpty {
                WidgetLeer(daten: daten)
            } else {
                let heute = Array(daten.heute.prefix(7)), spaeter = Array(daten.unterwegs.prefix(max(0, 7 - heute.count)))
                if !heute.isEmpty {
                    ueberschrift(T("Heute"))
                    ForEach(heute) { p in Link(destination: p.link) { WidgetZeile(posten: p, logo: 34, jetzt: daten.jetzt, interaktiv: daten.knoepfe) } }
                }
                if !spaeter.isEmpty {
                    ueberschrift(T("Unterwegs"))
                    ForEach(spaeter) { p in Link(destination: p.link) { WidgetZeile(posten: p, logo: 34, jetzt: daten.jetzt, interaktiv: daten.knoepfe) } }
                }
                Spacer(minLength: 0)
                if daten.alle.count > 7 {
                    Text(T("+ %1 weitere", "\(daten.alle.count - 7)")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func ueberschrift(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
    }
}

#if os(iOS)
/// Sperrbildschirm: das Nächste
struct RechteckWidget: View {
    let daten: WidgetDaten
    var body: some View {
        if let p = daten.alle.first {
            VStack(alignment: .leading, spacing: 1) {
                switch p {
                case .paket(let s):
                    Label(s.titel, systemImage: "shippingbox.fill").font(.headline).lineLimit(1)
                    Text(Texte.stand(s, jetzt: daten.jetzt)).font(.caption).lineLimit(1)
                case .brief(let b):
                    Label(b.titel, systemImage: b.wichtig ? "envelope.badge.fill" : "envelope.fill").font(.headline).lineLimit(1)
                    Text(Texte.brief(b, jetzt: daten.jetzt)).font(.caption).lineLimit(1)
                }
                if daten.alle.count > 1 { Text(T("+ %1 weitere", "\(daten.alle.count - 1)")).font(.caption2).foregroundStyle(.secondary) }
            }
            .widgetURL(p.link)
        } else {
            Label(daten.eingerichtet ? daten.titel : T("Post & Pakete einrichten"), systemImage: daten.symbol)
                .font(.caption)
        }
    }
}

/// Sperrbildschirm rund: Anzahl unterwegs, Ring = heute
struct RundWidget: View {
    let daten: WidgetDaten
    var body: some View {
        Gauge(value: Double(daten.heute.count), in: 0...Double(max(1, daten.alle.count))) {
            Image(systemName: daten.symbol)
        } currentValueLabel: {
            Text("\(daten.alle.count)")
        }
        .gaugeStyle(.accessoryCircular)
    }
}

/// Zeile über der Uhr: „2 heute“ bzw. „3 Pakete unterwegs“
struct ZeilenWidget: View {
    let daten: WidgetDaten
    var body: some View {
        Label(daten.heute.isEmpty ? daten.titel : T("%1 heute", "\(daten.heute.count)"), systemImage: daten.symbol)
    }
}
#endif

/// Knopf „Angekommen“ im Widget – führt die Absicht im Widget aus (mit dessen Zugang zu Home Assistant)
struct AngekommenKnopf: View {
    let id: String
    var body: some View {
        Button(intent: WidgetAngekommen(id: id)) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 22)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.green)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T("Angekommen"))
    }
}
