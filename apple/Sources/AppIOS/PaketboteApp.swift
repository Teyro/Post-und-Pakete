import SwiftUI
import BackgroundTasks
import UserNotifications
import PaketKern

/// Paketbote fürs iPhone und iPad
@main
struct PaketboteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var kern = Kern.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if kern.vorschau { Vorschau(kern: kern) } else { Hauptansicht(kern: kern) }
            }
            .onOpenURL { url in oeffnen(url) }
            .task { await UpdateHinweis.shared.pruefen() }
            .safeAreaInset(edge: .top) { UpdateBand() }
        }
        .onChange(of: phase) { _, neu in
            if neu == .active {
                Task { await kern.laden(still: true); await LiveAktivitaeten.abgleichen(kern, darfStarten: true); await WidgetVerbinder.beiBedarf(kern); await UpdateHinweis.shared.pruefen() }
            }
            if neu == .background { Hintergrund.planen() }
        }
        .backgroundTask(.appRefresh(Hintergrund.kennung)) {
            await Hintergrund.ausfuehren()
        }
    }

    /// paketbote://sendung/<id> (aus Widgets und Mitteilungen), paketbote://neu?nummer=…
    private func oeffnen(_ url: URL) {
        guard url.scheme == "paketbote" else { return }
        switch url.host {
        case "sendung": kern.auswahl = url.lastPathComponent
        case "neu":
            // aus dem Teilen-Menü: paketbote://neu?nummer=…
            kern.hinzufuegenNummer = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "nummer" }?.value ?? ""
            kern.hinzufuegenOffen = true
        default: break
        }
    }
}

/// Hintergrundabruf: iOS weckt die App ab und zu (frühestens alle 30 Minuten) – dann neue Stände melden
enum Hintergrund {
    static let kennung = "de.teyro.paketbote.aktualisieren"

    static func planen() {
        let a = BGAppRefreshTaskRequest(identifier: kennung)
        a.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(a)
    }

    @MainActor
    static func ausfuehren() async {
        planen()
        await Kern.shared.laden(still: true)
        await UpdateHinweis.shared.pruefen()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            Uhr.shared.starten()
            Kern.shared.nachLaden = { kern in
                Uhr.shared.senden(kern)
                Task { await LiveAktivitaeten.abgleichen(kern, darfStarten: UIApplication.shared.applicationState == .active) }
            }
        }
        return true
    }

    /// Mitteilung antippen: die Sendung zeigen
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let s = response.notification.request.content.userInfo["update"] as? String, let url = URL(string: s) {
            await MainActor.run { UIApplication.shared.open(url) }
            return
        }
        if let id = response.notification.request.content.userInfo["sendung"] as? String {
            await MainActor.run { Kern.shared.auswahl = id }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Neue Version auf GitHub? Selbst installieren kann sich eine selbst signierte App nicht – deshalb Band in der App,
/// eine Mitteilung (auch aus dem Hintergrund) und ein direkter Link zur IPA zum Signieren (z. B. mit Signulous).
@MainActor
@Observable
final class UpdateHinweis {
    static let shared = UpdateHinweis()
    private(set) var neu: String?
    private(set) var ipa: URL?
    let seite = URL(string: "https://github.com/Teyro/Post-und-Pakete/releases/latest")!
    var ausgeblendet = false
    @ObservationIgnored private var zuletzt = Date.distantPast

    func pruefen() async {
        guard !Kern.shared.vorschau, Kern.shared.einstellungen.autoUpdate, Date().timeIntervalSince(zuletzt) > 3600,
              let url = URL(string: "https://api.github.com/repos/Teyro/Post-und-Pakete/releases/latest") else { return }
        zuletzt = Date()
        var r = URLRequest(url: url)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (d, _) = try? await URLSession.shared.data(for: r), let j = JSON.lesen(d), let tag = j["tag_name"]?.text else { return }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let aktuell = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard v.compare(aktuell, options: .numeric) == .orderedDescending else { neu = nil; return }
        neu = v
        ipa = (j["assets"]?.liste ?? []).compactMap { a -> URL? in
            guard let n = a["name"]?.text, n.hasPrefix("PostUndPakete-iOS-"), !n.contains("mit-Uhr"), n.hasSuffix(".ipa"),
                  let s = a["browser_download_url"]?.text, s.hasPrefix("https://github.com/Teyro/Post-und-Pakete/releases/download/") else { return nil }
            return URL(string: s)
        }.first
        await melden(v)
    }

    /// Einmal je Version Bescheid geben
    private func melden(_ v: String) async {
        let d = UserDefaults.standard
        guard d.string(forKey: "updateGemeldet") != v else { return }
        d.set(v, forKey: "updateGemeldet")
        let c = UNMutableNotificationContent()
        c.title = T("Post & Pakete %1 ist da", v)
        c.body = T("Tippen, um die neue Version zu laden und zu signieren.")
        c.userInfo = ["update": (ipa ?? seite).absoluteString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-" + v, content: c, trigger: nil))
    }
}

struct UpdateBand: View {
    @State private var u = UpdateHinweis.shared
    var body: some View {
        if let v = u.neu, !u.ausgeblendet {
            HStack {
                Label(T("Version %1 ist da", v), systemImage: "arrow.down.circle.fill").font(.callout.weight(.medium))
                Spacer()
                Link(u.ipa == nil ? T("Ansehen") : T("Laden"), destination: u.ipa ?? u.seite).font(.callout.weight(.semibold))
                Button { u.ausgeblendet = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }
}
