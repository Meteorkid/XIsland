import SwiftUI

/// A segmented picker for selecting the app's appearance mode.
struct ThemePickerView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        @Bindable var theme = themeManager
        Picker("", selection: $theme.mode) {
            Text(L10n.appearanceDark).tag(AppearanceMode.dark)
            Text(L10n.appearanceLight).tag(AppearanceMode.light)
            Text(L10n.appearanceSystem).tag(AppearanceMode.system)
        }
        .pickerStyle(.segmented)
    }
}

#Preview {
    ThemePickerView()
        .environment(ThemeManager())
        .padding()
}
