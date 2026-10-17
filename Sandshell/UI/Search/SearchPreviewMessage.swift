/// One message of the conversation the Search window previews (`id` is its
/// position in the transcript).
struct SearchPreviewMessage: Identifiable, Equatable {
    let id: Int
    let role: String
    let text: String
}
