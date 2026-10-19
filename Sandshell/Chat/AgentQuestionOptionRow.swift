import SwiftUI

/// One option of a question in an agent's question card: a radio (or, for a
/// multi-choice, checkbox) row with the option's detail, and its 1–9 key when
/// the card is a single choice question. Pointing at it shows its preview.
struct AgentQuestionOptionRow: View {
    let form: AgentQuestionForm
    let option: AgentQuestion.Option
    let index: Int
    let fieldID: String
    let selected: Bool
    let multi: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title).font(.role(selected ? .bodyEmphasis : .body))
                    if let detail = option.detail {
                        Text(detail).font(.role(.meta)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if index < 9, form.singleChoice != nil {
                    Text("\(index + 1)").font(.role(.code))
.foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.detail.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in if inside, option.preview != nil { form.previewed[fieldID] = option } }
    }
}
