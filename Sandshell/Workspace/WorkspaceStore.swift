import Foundation

/// One folder's persisted workspace (`state.json` + `config.json`), shared by
/// every window open on it. Each window has its own `WorkspaceController`
/// (selection, live sessions), but they read and write this one copy — two
/// windows each saving their own would put back what the other changed.
/// A change from one window tells the others, which redraw from it.
@MainActor
final class WorkspaceStore {
    let root: URL
    private(set) var state: WorkspaceState
    private(set) var config: WorkspaceConfig

    private init(root: URL, state: WorkspaceState, config: WorkspaceConfig) {
        self.root = root
        self.state = state
        self.config = config
    }

    // MARK: Sharing

    private final class Weak { weak var store: WorkspaceStore?; init(_ s: WorkspaceStore) { store = s } }
    private static var open: [String: Weak] = [:]

    /// The store for `root`: the one a window already has open, else loaded
    /// (bootstrapping the folder's control files).
    static func shared(root: URL) throws -> WorkspaceStore {
        let key = root.standardizedFileURL.path
        if let store = open[key]?.store { return store }
        let state = try WorkspaceBootstrap.openOrCreate(root: root)
        let config = WorkspaceConfig.loadOrDefault(root: root, home: FileManager.default.homeDirectoryForCurrentUser)
        let store = WorkspaceStore(root: root, state: state, config: config)
        open = open.filter { $0.value.store != nil }
        open[key] = Weak(store)
        return store
    }

    // MARK: Writes

    enum Part { case state, config }

    /// Each window's controller, told (on the next main-loop turn, coalesced)
    /// which parts someone else changed. Held weakly: a closed window drops out.
    private final class Observer {
        weak var owner: AnyObject?
        let id: ObjectIdentifier
        let notify: (Set<Part>) -> Void
        init(_ owner: AnyObject, _ notify: @escaping (Set<Part>) -> Void) {
            self.owner = owner
            id = ObjectIdentifier(owner)
            self.notify = notify
        }
    }
    private var observers: [Observer] = []
    private var pending: [Part: Set<ObjectIdentifier>] = [:]

    func observe(_ owner: AnyObject, _ notify: @escaping (Set<Part>) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner, notify))
    }

    func setState(_ new: WorkspaceState, by writer: AnyObject) {
        state = new
        changed(.state, by: writer)
    }

    func setConfig(_ new: WorkspaceConfig, by writer: AnyObject) {
        config = new
        changed(.config, by: writer)
    }

    private func changed(_ part: Part, by writer: AnyObject) {
        observers.removeAll { $0.owner == nil }
        guard observers.count > 1 else { return }   // one window: nobody else to tell
        let first = pending.isEmpty
        pending[part, default: []].insert(ObjectIdentifier(writer))
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        let batch = pending
        pending = [:]
        for observer in observers where observer.owner != nil {
            // Every part someone other than this observer wrote.
            let parts = Set(batch.compactMap { part, writers in
                writers.contains { $0 != observer.id } ? part : nil
            })
            if !parts.isEmpty { observer.notify(parts) }
        }
    }
}
