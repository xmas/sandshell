import SwiftUI

extension AttributedString {
    /// `text` with every occurrence of `query` bolded and tinted (the Search
    /// window's results and preview); plain when `query` is empty.
    init(_ text: String, highlighting query: String) {
        self.init(text)
        guard !query.isEmpty else { return }
        var idx = startIndex
        while idx < endIndex, let r = self[idx...].range(of: query, options: .caseInsensitive) {
            self[r].inlinePresentationIntent = .stronglyEmphasized
            self[r].backgroundColor = Color.accentColor.opacity(0.28)
            idx = r.upperBound
        }
    }
}
