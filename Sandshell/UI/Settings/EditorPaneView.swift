import SwiftUI

/// Settings ▸ Editor: the Files editor's text, gutter, indentation and what
/// saving tidies. For the app, not just this folder; open editors follow live.
struct EditorPaneView: View {
    @ObservedObject var settings: EditorSettings

    private var prefs: Binding<EditorPreferences> { $settings.prefs }
    @State private var replyFont = ChatFonts.reply
    @State private var messageFont = ChatFonts.message

    var body: some View {
        Form {
            Section("Chat") {
                Picker("Replies", selection: $replyFont) {
                    ForEach(ChatFonts.families, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: replyFont) { _, family in ChatFonts.reply = family }
                Picker("Your Messages", selection: $messageFont) {
                    ForEach(ChatFonts.families, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: messageFont) { _, family in ChatFonts.message = family }
            }

            Section("Text") {
                Stepper(value: prefs.fontSize, in: EditorPreferences.fontSizes, step: 0.5) {
                    LabeledContent("Font Size", value: settings.prefs.fontSize.formatted(.number.precision(.fractionLength(0...1))) + " pt")
                }
                Toggle("Wrap Lines", isOn: prefs.wrapsLines)
                Toggle("Syntax Coloring", isOn: prefs.colorsSyntax)
                Toggle("Highlight Current Line", isOn: prefs.highlightsCurrentLine)
                Toggle("Page Guide", isOn: prefs.showsPageGuide)
                if settings.prefs.showsPageGuide {
                    Picker("At Column", selection: prefs.pageGuideColumn) {
                        ForEach(EditorPreferences.pageGuideColumns, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            }

            Section("Gutter") {
                Toggle("Line Numbers", isOn: prefs.showsLineNumbers)
                Toggle("Change Bars", isOn: prefs.showsChangeBars)
                    .disabled(!settings.prefs.showsLineNumbers)
            }

            Section {
                Picker("Tab Width", selection: prefs.tabWidth) {
                    ForEach(EditorPreferences.tabWidths, id: \.self) { Text("\($0) spaces").tag($0) }
                }
                Picker("Indent Using", selection: prefs.indentsWithSpaces) {
                    Text("Spaces").tag(true)
                    Text("Tabs").tag(false)
                }
                .pickerStyle(.segmented)
                Toggle("Keep Indentation on Return", isOn: prefs.autoIndents)
            } header: {
                Text("Indentation")
            } footer: {
                Text("Tab inserts spaces up to the next tab stop, or a tab character.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Remove Trailing Spaces", isOn: prefs.trimsTrailingWhitespace)
                Toggle("End With a Line Break", isOn: prefs.endsWithNewline)
            } header: {
                Text("When Saving")
            } footer: {
                Text("Trailing spaces stay on the line you're typing on. Saving can be undone like any edit.")
                    .font(.role(.meta)).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("These settings apply to the Files editor in every folder.")
                        .font(.role(.meta)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { settings.reset() }
                        .disabled(settings.prefs == EditorPreferences())
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.bottom, 80, for: .scrollContent)
    }
}
