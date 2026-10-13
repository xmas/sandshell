import Combine
import Foundation

/// Drop-in replacement for `@Published` on a `@MainActor ObservableObject` whose
/// publisher emits **after** the new value is stored.
///
/// `@Published` emits in `willSet`: inside a `$prop.sink { … }` the object's
/// stored properties are still the *old* values. Every AppKit subscriber that
/// re-read controller state from a sink (header status, "New Session" enabled
/// state, the kit banner) lagged one change behind, and several call sites grew
/// "use the delivered value, not `controller.x`" workarounds. With `@Committed`
/// the sequence on assignment is:
///
/// 1. `objectWillChange.send()` — SwiftUI still sees a pre-change notification.
/// 2. the value is stored.
/// 3. `$prop` emits the committed value — subscribers may read the object freely.
///
/// The projected publisher replays the current value on subscribe, like
/// `@Published`, so existing `.dropFirst().sink` call sites are unchanged.
@MainActor
@propertyWrapper
struct Committed<Value> {
    private let subject: CurrentValueSubject<Value, Never>

    init(wrappedValue: Value) {
        subject = CurrentValueSubject(wrappedValue)
    }

    @available(*, unavailable, message: "@Committed can only be applied to properties of classes")
    var wrappedValue: Value {
        get { fatalError("@Committed is enclosing-instance only") }
        set { fatalError("@Committed is enclosing-instance only") }
    }

    /// `$prop` — emits the current value on subscribe, then every committed change.
    var projectedValue: AnyPublisher<Value, Never> { subject.eraseToAnyPublisher() }

    static subscript<Owner: ObservableObject>(
        _enclosingInstance owner: Owner,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Owner, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Owner, Committed<Value>>
    ) -> Value where Owner.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { owner[keyPath: storageKeyPath].subject.value }
        set {
            owner.objectWillChange.send()
            // `send` stores the value and then delivers it, so subscribers observe
            // the object in its post-change state.
            owner[keyPath: storageKeyPath].subject.send(newValue)
        }
    }
}
