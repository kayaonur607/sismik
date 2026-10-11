import SwiftUI

struct DisplaySettingsCard: View {
    @Binding var language: String
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue


    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("settings.appearance")).font(.subheadline.weight(.bold))
                Spacer()
                Picker("", selection: $appearance) {
                    Text(L("settings.appearance.system")).tag(AppAppearance.system.rawValue)
                    Text(L("settings.appearance.light")).tag(AppAppearance.light.rawValue)
                    Text(L("settings.appearance.dark")).tag(AppAppearance.dark.rawValue)
                }
                .pickerStyle(.menu)
                .tint(Color.appAction)
            }

            Divider()

            HStack {
                Text(L("settings.language")).font(.subheadline.weight(.bold))
                Spacer()
                Picker("", selection: $language) {
                    ForEach(AppLanguage.allCases) { appLanguage in
                        Text(appLanguage.title).tag(appLanguage.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.appAction)
            }
        }
        .padding(.vertical, 4)
    }
}
