import SwiftUI
import WicketCore

/// Settings ▸ Features: a switch for each built-in result source. Like every pane this only writes
/// settings.json (`features`), and the reload applies it.
struct FeaturesPane: View {
    let store: SettingsStore
    @State private var error: String?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                ForEach(Feature.allCases, id: \.self) { feature in
                    Toggle(isOn: enabled(feature)) {
                        Text(feature.title)
                        Text(feature.summary)
                    }
                }
            } footer: {
                Text("A feature that is off does no work and leaves the search. Commands are always on.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func enabled(_ feature: Feature) -> Binding<Bool> {
        Binding {
            store.settings.isEnabled(feature)
        } set: { isOn in
            do {
                try store.update { $0.setEnabled(feature, isOn) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
