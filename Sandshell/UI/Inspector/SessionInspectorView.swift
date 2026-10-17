import SwiftUI
import UniformTypeIdentifiers

/// The cards the inspector can show, in the order a person last arranged them.
enum InspectorCardKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case context, backgroundTasks, connectors, environment
    var id: String { rawValue }
    var title: String {
        switch self {
        case .context: "Context"
        case .backgroundTasks: "Background tasks"
        case .connectors: "Connectors"
        case .environment: "Environment"
        }
    }
}

/// Card order and collapsed cards, kept across launches (all chats share them).
@MainActor
@Observable
final class InspectorLayout {
    static let shared = InspectorLayout()
    private static let orderKey = "inspectorCardOrder", collapsedKey = "inspectorCollapsedCards"

    private(set) var order: [InspectorCardKind]
    private(set) var collapsed: Set<InspectorCardKind>

    private init() {
        let saved = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []).compactMap(InspectorCardKind.init(rawValue:))
        order = saved + InspectorCardKind.allCases.filter { !saved.contains($0) }
        collapsed = Set((UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []).compactMap(InspectorCardKind.init(rawValue:)))
    }

    func toggle(_ card: InspectorCardKind) {
        if collapsed.contains(card) { collapsed.remove(card) } else { collapsed.insert(card) }
        UserDefaults.standard.set(collapsed.map(\.rawValue), forKey: Self.collapsedKey)
    }

    /// Put `card` where `target` is (dragging a card onto another).
    func move(_ card: InspectorCardKind, to target: InspectorCardKind) {
        guard card != target, let from = order.firstIndex(of: card), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(card, at: to)
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.orderKey)
    }

    func move(_ card: InspectorCardKind, by delta: Int) {
        guard let i = order.firstIndex(of: card), order.indices.contains(i + delta) else { return }
        move(card, to: order[i + delta])
    }
}

/// A chat's side panel: Context, Background tasks, Connectors, Environment —
/// each a card that collapses from its header and moves by its handle.
struct SessionInspectorView: View {
    let model: SessionInspectorModel
    @State private var layout = InspectorLayout.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(layout.order) { kind in
                    InspectorCard(kind: kind, layout: layout) { content(kind) }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.automatic)
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refreshContext() }
        .task { await model.refreshMCP() }
        .onAppear { model.loadEnvironment() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session inspector")
    }

    @ViewBuilder private func content(_ kind: InspectorCardKind) -> some View {
        switch kind {
        case .context: ContextCard(model: model)
        case .backgroundTasks: BackgroundTasksCard(model: model)
        case .connectors: ConnectorsCard(model: model)
        case .environment: EnvironmentCard(model: model)
        }
    }
}

/// The card chrome: a header that collapses it (with a chevron) and a handle
/// that drags it into another place; the menu offers the same moves.
struct InspectorCard<Content: View>: View {
    let kind: InspectorCardKind
    let layout: InspectorLayout
    @ViewBuilder let content: Content
    @State private var targeted = false

    private var isCollapsed: Bool { layout.collapsed.contains(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { layout.toggle(kind) }
                } label: {
                    HStack(spacing: 5) {
                        Text(kind.title).font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Show \(kind.title)" : "Hide \(kind.title)")
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(4)
                    .contentShape(.rect)
                    .draggable(kind.rawValue)
                    .help("Drag to move this card")
                    .accessibilityHidden(true)
            }
            if !isCollapsed { content }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: targeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let card = InspectorCardKind(rawValue: raw) else { return false }
            withAnimation(.snappy) { layout.move(card, to: kind) }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button(isCollapsed ? "Expand" : "Collapse") { layout.toggle(kind) }
            Button("Move Up") { withAnimation(.snappy) { layout.move(kind, by: -1) } }
                .disabled(layout.order.first == kind)
            Button("Move Down") { withAnimation(.snappy) { layout.move(kind, by: 1) } }
                .disabled(layout.order.last == kind)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityActions {
            Button("Move Up") { layout.move(kind, by: -1) }
            Button("Move Down") { layout.move(kind, by: 1) }
        }
    }
}

/// A row with a leading symbol, a title, and trailing detail — the inspector's line.
struct InspectorRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.middle)
            if let subtitle {
                Text("· \(subtitle)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

extension InspectorRow where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}
