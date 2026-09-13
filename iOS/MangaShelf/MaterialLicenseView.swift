import SwiftUI

struct MaterialLicenseView: View {
    @Environment(\.locale) private var interfaceLocale
    private var license: String {
        guard let url = Bundle.main.url(forResource: "MaterialIcons-LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Material Icons · Copyright 2019 Google LLC · Apache License 2.0\nhttps://www.apache.org/licenses/LICENSE-2.0"
        }
        return text
    }
    var body: some View {
        ScrollView { Text(license).font(.footnote).textSelection(.enabled).padding(18) }
            .tachiPage(L10n.string("Open-source licenses"))
    }
}
