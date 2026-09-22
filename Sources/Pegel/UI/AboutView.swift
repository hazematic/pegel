import AppKit
import SwiftUI

struct AboutView: View {

    @ObservedObject var updates: UpdateController

    private static let repository = URL(string: "https://github.com/hazematic/pegel")!
    private static let coffee = URL(string: "https://buymeacoffee.com/hazematic")!

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

            // Nothing goes out unless the user asks; the note says what GitHub receives.
            Section(L("about.section.updates")) {
                Toggle(L("about.updates.automatic"), isOn: $updates.automaticallyChecks)
                    .disabled(!updates.isAvailable)
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
                Button(L("about.licenses.show")) {
                    if let folder = Self.licensesFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                .disabled(Self.licensesFolder == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? version
        return build == version
            ? L("about.version", version) : L("about.versionBuild", version, build)
    }

    /// Placed there by `build-app.sh`; missing under `swift run`.
    private static var licensesFolder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
