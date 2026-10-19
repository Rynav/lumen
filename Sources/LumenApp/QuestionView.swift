import LumenCore
import SwiftUI

/// A card that asks the user one question and blocks the run until it is answered.
struct QuestionView: View {
    let question: UserQuestion
    let answer: (String) -> Void
    @State private var text = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: LumenStyle.space3) {
                Text(question.question)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ForEach(question.options, id: \.self) { option in
                    Button(option) { answer(option) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: LumenStyle.space2) {
                    TextField("Or type another answer", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, LumenStyle.space1)
        } label: {
            Label("Lumen needs an answer", systemImage: "questionmark.bubble")
        }
    }

    private func send() { answer(text) }
}
