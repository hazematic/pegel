import AppKit
import SwiftUI

struct AboutView: View {

    @ObservedObject var updates: UpdateController
    let showLicences: () -> Void

    private var installBinding: Binding<Bool> {
        Binding(
            get: { updates.automaticallyChecks && updates.automaticallyInstalls },
            set: { updates.automaticallyInstalls = $0 })
    }

    private static let repository = URL(string: "https://github.com/hazematic/pegel")!
    private static let coffee = URL(string: "https://buymeacoffee.com/hazematic")!
    /// Language & Region in System Settings, where macOS sets the language per app.
    private static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text("Pegel")
                        .font(.title2.weight(.semibold))
                    Text(Self.versionLine)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(L("about.tagline"))
                        .padding(.top, 4)
                    Text(L("about.copyright"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Link(L("about.repository"), destination: Self.repository)
                        Link(L("about.coffee"), destination: Self.coffee)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            // Only in machine-translated languages: how the texts came about, and ways out.
            if Self.machineTranslated {
                Section(L("about.section.translation")) {
                    Text(L("about.translation.machine"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Link(L("about.translation.report"), destination: Self.reportURL)
                        Link(L("about.translation.useEnglish"), destination: Self.languageSettings)
                    }
                }
            }

            // Nothing goes out unless the user asks; the note says what GitHub receives.
            Section(L("about.section.updates")) {
                Toggle(L("about.updates.automatic"), isOn: $updates.automaticallyChecks)
                    .disabled(!updates.isAvailable)
                // Shown off without checks, since it does nothing then; the stored
                // value stays and returns with the checks.
                Toggle(L("about.updates.install"), isOn: installBinding)
                    .disabled(!updates.isAvailable || !updates.automaticallyChecks)
                Text(L("about.updates.install.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L("about.updates.check")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
                Text(L("about.updates.privacy"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L("about.section.licenses")) {
                Text(L("about.licenses.explanation"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L("about.licenses.show"), action: showLicences)
                    .disabled(Self.licensesFolder == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: Self.machineTranslated ? 740 : 640)
    }

    /// `Translation.plist`, written into each `.lproj` by `pegel-i18n sync`; the bundle returns
    /// the file of the language the app runs in. False for German, English and languages checked
    /// by native speakers, and under `swift run`, where the `.lproj` folders are not in the bundle.
    private static let machineTranslated: Bool = {
        guard let url = Bundle.main.url(forResource: "Translation", withExtension: "plist"),
            let dict = NSDictionary(contentsOf: url)
        else { return false }
        return dict["machine"] as? Bool ?? false
    }()

    /// Issue form for translation mistakes, with language and version in the title.
    private static var reportURL: URL {
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var url = URLComponents(string: "https://github.com/hazematic/pegel/issues/new")!
        url.queryItems = [
            URLQueryItem(name: "template", value: "translation.yml"),
            URLQueryItem(name: "title", value: "[\(lang), \(version)] "),
        ]
        return url.url!
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? version
        return build == version
            ? L("about.version", version) : L("about.versionBuild", version, build)
    }

    /// Placed there by `build-app.sh`; missing under `swift run`.
    static var licensesFolder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
