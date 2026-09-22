import SwiftUI

/// The licence texts shipped in the bundle, NOTICE first, readable in one window.
struct AcknowledgementsView: View {

    private let text = Self.load()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(width: 620, height: 560)
    }

    private static func load() -> String {
        guard let folder = AboutView.licensesFolder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return "" }
        let order = ["NOTICE", "LICENSE"]
        let sorted = order.filter(names.contains) + names.filter { !order.contains($0) }.sorted()
        return sorted.compactMap { name in
            try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\n\n\n")
    }
}
