import SwiftUI
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#endif
import PaketKern

/// Zum Vorzeigen an Packstation, Filiale oder Paketshop: Code groß, als QR-Code, Frist als Countdown,
/// dazu das eigene Foto (z. B. der QR-Code des Rücksendeetiketts). Auf dem iPhone volle Helligkeit.
struct VorzeigenAnsicht: View {
    let sendung: Sendung
    var foto: Image?
    @Environment(\.dismiss) private var schliessen
    #if os(iOS)
    @State private var helligkeit: CGFloat = -1
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Text(sendung.titel).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    if !sendung.abholort.isEmpty || !sendung.abholadresse.isEmpty {
                        Text([sendung.abholort, sendung.abholadresse].filter { !$0.isEmpty }.joined(separator: "\n"))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if !sendung.abholcode.isEmpty {
                        if let qr = Self.qr(sendung.abholcode) {
                            qr.interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 260)
                                .padding(14)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        Text(sendung.abholcode)
                            .font(.system(size: 52, weight: .bold, design: .monospaced))
                            .kerning(6)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    if let foto {
                        foto.resizable().scaledToFit()
                            .frame(maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if let t = frist {
                        Label(t.text, systemImage: "clock.fill")
                            .font(.headline)
                            .foregroundStyle(t.knapp ? Color.red : Color.primary)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background((t.knapp ? Color.red : Color.secondary).opacity(0.14), in: Capsule())
                    }
                    if !sendung.nummer.isEmpty {
                        Text(T("Sendung %1", sendung.nummer)).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(T("Fertig")) { schliessen() } } }
        }
        #if os(iOS)
        .onAppear { helligkeit = UIScreen.main.brightness; UIScreen.main.brightness = 1 }
        .onDisappear { if helligkeit >= 0 { UIScreen.main.brightness = helligkeit } }
        #endif
    }

    /// „Noch 3 Tage abholen“ / „Rückgabe noch 12 Tage“
    private var frist: (text: String, knapp: Bool)? {
        let k = Calendar.current
        let heute = k.startOfDay(for: Date())
        if sendung.stand == "abholbereit", let f = Texte.tagAus(sendung.abholfrist) {
            let tage = k.dateComponents([.day], from: heute, to: k.startOfDay(for: f)).day ?? 0
            return (tage <= 0 ? T("Heute letzter Abholtag") : tage == 1 ? T("Noch bis morgen abholen") : T("Noch %1 Tage abholen", "\(tage)"), tage <= 1)
        }
        if let bis = sendung.rueckgabeBis {
            let tage = k.dateComponents([.day], from: heute, to: k.startOfDay(for: bis)).day ?? 0
            guard tage >= 0 else { return nil }
            return (tage == 0 ? T("Rückgabe nur noch heute") : T("Rückgabe noch %1 Tage", "\(tage)"), tage <= 2)
        }
        return nil
    }

    static func qr(_ text: String) -> Image? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let bild = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(bild, from: bild.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
