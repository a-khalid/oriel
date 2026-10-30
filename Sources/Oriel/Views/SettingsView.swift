import SwiftUI

struct SettingsView: View {
    @State private var language = AppLanguage.current
    private let launchLanguage = AppLanguage.current

    var body: some View {
        Form {
            Picker("Language", selection: $language) {
                Text("System Default").tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "العربية").tag(AppLanguage.arabic)
            }
            .onChange(of: language) { _, newValue in newValue.apply() }

            if language != launchLanguage {
                HStack {
                    Text("Oriel needs to restart to change its language.")
                        .font(.oriel(.callout))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .font(.oriel(.body))
    }
}
