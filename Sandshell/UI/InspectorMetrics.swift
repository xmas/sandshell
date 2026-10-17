import Foundation

/// Shared size of the inspector sheet's pane area; every pane view fixes its
/// own frame to these so switching tabs never resizes the sheet.
enum InspectorMetrics {
    static let paneWidth: CGFloat = 780
    static let paneHeight: CGFloat = 720
}
