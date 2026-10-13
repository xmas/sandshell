import AppKit
import SwiftUI

/// Searchable browser over all past agent conversations. A sidebar lists the
/// conversations (full-text filtered); the detail pane previews the selected
/// one. "Open Session" restores it.
struct HistoryView: View {
    @ObservedObject var theme: ThemeController
    @ObservedObject var store: HistoryStore
    let onOpen: (ConversationRecord) -> Void
    let onClose: () -> Void

    @State private var selection: ConversationRecord.ID?
    @State private var preview: [Message] = []

    private struct Message: Identifiable { let id = UUID(); let role: String; let text: String }
    private var selected: ConversationRecord? { store.records.first { $0.id == selection } }
    /// Use the main palette uniformly (not the app's split sidebar/detail).
    private var colors: ThemeColors { theme.colors }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(colors.text3))
                TextField("Search all conversations", text: $store.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color(colors.text))
                if store.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(colors.panel))
            Divider().overlay(Color(colors.border))

            HSplitView {
                conversationList.frame(minWidth: 260, idealWidth: 300)
                previewPane.frame(minWidth: 380)
            }

            Divider().overlay(Color(colors.border))
            HStack {
                Text(footerText).font(.caption).foregroundStyle(Color(colors.text2))
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Open Session") { if let s = selected { onOpen(s) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(12)
            .background(Color(colors.panel))
        }
        .frame(width: 860, height: 580)
        .background(Color(colors.panel))
        .tint(Color(colors.accent))
        .onAppear { store.load() }
        .onChange(of: selection) { _, _ in loadPreview() }
    }

    private var footerText: String {
        let n = store.filtered.count
        return store.query.isEmpty ? "\(n) conversation\(n == 1 ? "" : "s")"
                                   : "\(n) match\(n == 1 ? "" : "es")"
    }

    private var conversationList: some View {
        List(store.filtered, selection: $selection) { rec in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    agentBadge(rec.agent)
                    Text(highlighted(rec.title)).lineLimit(1).fontWeight(.medium)
                        .foregroundStyle(Color(colors.text))
                }
                HStack(spacing: 6) {
                    Text(rec.date, format: .relative(presentation: .named))
                    if let cwd = rec.cwd { Text("·"); Text(shortPath(cwd)).lineLimit(1).truncationMode(.middle) }
                    Text("· \(rec.messageCount) msgs")
                }
                .font(.caption2).foregroundStyle(Color(colors.text3))
            }
            .padding(.vertical, 2)
            .tag(rec.id)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(colors.sidebar))
    }

    @ViewBuilder
    private var previewPane: some View {
        Group {
            if selected == nil {
                VStack { Spacer(); Text("Select a conversation")
                    .foregroundStyle(Color(colors.text3)); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preview) { msg in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(msg.role == "user" ? "You" : "Assistant")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(msg.role == "user" ? Color(colors.accent) : Color(colors.text2))
                                Text(highlighted(msg.text))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(colors.text))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(colors.panel))
    }

    private func loadPreview() {
        guard let sel = selected else { preview = []; return }
        let msgs = TranscriptReader.messages(at: sel.url, agent: sel.agent)
        preview = msgs.map { Message(role: $0.role, text: $0.text) }
    }

    /// Bold + highlight occurrences of the current search query in `text`.
    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = store.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return attr }
        var idx = attr.startIndex
        while idx < attr.endIndex,
              let r = attr[idx...].range(of: q, options: .caseInsensitive) {
            attr[r].inlinePresentationIntent = .stronglyEmphasized
            attr[r].backgroundColor = Color(colors.accent).opacity(0.30)
            idx = r.upperBound
        }
        return attr
    }

    /// The agent's colored badge with its brand logo (glyph fallback).
    @ViewBuilder
    private func agentBadge(_ agent: AgentKind) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(agent.badgeColor))
            if let name = agent.badgeImageName, let img = NSImage(named: name) {
                Image(nsImage: img).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 12, height: 12).foregroundStyle(.white)
            } else {
                Text(agent.badgeGlyph).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
    }

    private func shortPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }
}
