import SwiftUI

/// How the context window is spent: a bar, the categories, what's deferred,
/// the MCP tools and memory files behind it, and how far from auto-compact.
struct ContextCard: View {
    let model: SessionInspectorModel
    @State private var showTools = false
    @State private var showMemory = false
    @State private var showSkills = false

    var body: some View {
        if let usage = model.context {
            breakdown(usage)
        } else {
            fallback
        }
    }

    // MARK: The breakdown

    @ViewBuilder private func breakdown(_ usage: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(usage.percentage)% used").font(.title3.weight(.medium))
                Spacer()
                Text("\(Format.tokens(usage.totalTokens)) / \(Format.tokens(usage.maxTokens))")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            ContextBar(rows: usage.windowRows, total: max(usage.maxTokens, 1))
                .frame(height: 6)
            VStack(spacing: 5) {
                ForEach(usage.windowRows) { row in
                    categoryRow(row, of: usage.maxTokens)
                }
            }
            if !usage.deferredRows.isEmpty {
                VStack(spacing: 5) {
                    ForEach(usage.deferredRows) { row in categoryRow(row, of: nil) }
                }
                .padding(.top, 2)
            }
            if !usage.mcpTools.isEmpty {
                DisclosureGroup(isExpanded: $showTools) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(usage.mcpToolsByServer, id: \.server) { group in
                            HStack {
                                Text(group.server.isEmpty ? "MCP" : group.server).lineLimit(1)
                                Spacer()
                                Text("\(group.tools.count) tools · \(Format.tokens(group.tokens))")
                                    .foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    countLabel("MCP tools", usage.mcpTools.count)
                }
            }
            if !usage.memoryFiles.isEmpty {
                DisclosureGroup(isExpanded: $showMemory) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(usage.memoryFiles) { file in
                            HStack {
                                Text((file.name as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
                                    .help(file.name)
                                Spacer()
                                Text(Format.tokens(file.tokens)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    countLabel("Memory files", usage.memoryFiles.count)
                }
            }
            if !usage.skills.isEmpty {
                DisclosureGroup(isExpanded: $showSkills) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(usage.skills) { skill in
                            HStack {
                                Text(skill.name).lineLimit(1)
                                Spacer()
                                Text(Format.tokens(skill.tokens)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.leading, 4)
                } label: {
                    countLabel("Skills", usage.skills.count)
                }
            }
            footer(usage)
        }
    }

    private func categoryRow(_ row: ContextUsage.Category, of total: Int?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(ContextPalette.color(for: row))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(row.name)
                .foregroundStyle(row.kind == .deferred ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Text(Format.tokens(row.tokens)).foregroundStyle(.secondary).monospacedDigit()
            Group {
                if let total, total > 0 {
                    Text(Double(row.tokens) / Double(total), format: .percent.precision(.fractionLength(1)))
                } else {
                    Text("—")
                }
            }
            .frame(width: 48, alignment: .trailing)
            .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func countLabel(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
    }

    private func footer(_ usage: ContextUsage) -> some View {
        HStack {
            if let left = usage.untilAutoCompact {
                Text("\(Format.tokens(left)) until auto-compact").foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshContext() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(model.refreshingContext)
                .help("Update the breakdown")
            Button("Compact Session") { model.compact() }
                .controlSize(.small)
                .disabled(model.canCompact == false)
                .help("Summarize the conversation so far to free up the window (/compact)")
        }
        .font(.callout)
        .padding(.top, 2)
    }

    // MARK: Without the breakdown

    @ViewBuilder private var fallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage = model.usage, usage.size > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(Double(usage.used) / Double(usage.size), format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.medium))
                    Text("used").font(.title3.weight(.medium))
                    Spacer()
                    Text("\(Format.tokens(usage.used)) / \(Format.tokens(usage.size))").foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(usage.used), total: Double(usage.size))
                    .progressViewStyle(.linear)
            }
            if model.refreshingContext {
                ProgressView().controlSize(.small)
            } else if let note = model.contextNote {
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if model.usage == nil {
                Text("Shows once the chat has started.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The segmented bar: each category's share of the window, in its colour.
struct ContextBar: View {
    let rows: [ContextUsage.Category]
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(rows) { row in
                    Rectangle()
                        .fill(ContextPalette.color(for: row))
                        .frame(width: max(row.tokens > 0 ? 2 : 0, proxy.size.width * CGFloat(row.tokens) / CGFloat(total)))
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color.secondary.opacity(0.15))
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

/// Category colours like the Claude app's: messages blue, system tools
/// orange, MCP tools green, the rest greys; the buffer and free space pale.
enum ContextPalette {
    static func color(for row: ContextUsage.Category) -> Color {
        switch row.kind {
        case .free: return Color.secondary.opacity(0.12)
        case .buffer: return Color.secondary.opacity(0.3)
        case .deferred: return Color.secondary.opacity(0.25)
        case .used:
            let name = row.name.lowercased()
            if name.hasPrefix("messages") { return .blue }
            if name.hasPrefix("system tools") { return .orange }
            if name.hasPrefix("mcp tools") { return .green }
            if name.contains("agent") { return .purple }
            if name.contains("since last") { return Color.secondary.opacity(0.55) }
            return .gray
        }
    }
}
