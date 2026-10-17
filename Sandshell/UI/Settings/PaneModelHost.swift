import SwiftUI

/// Holds a Settings pane's editing model, built once when the pane first shows;
/// switching to another pane drops it, discarding unapplied edits.
///
/// The model can't come from `State(initialValue:)` in the pane's init: that
/// argument is evaluated on every init, and the panes are re-created whenever
/// `InspectorView`'s controller changes — its clock ticks every second — while
/// the models' inits read UserDefaults or stat folders in `$HOME`.
struct PaneModelHost<Model: AnyObject, Content: View>: View {
    let make: () -> Model
    @ViewBuilder let content: (Model) -> Content

    @State private var model: Model?

    var body: some View {
        if let model {
            content(model)
        } else {
            Color.clear.onAppear { model = make() }
        }
    }
}
