import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CopyableValue: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(value)
                    .monospaced()
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    copyValue()
                } label: {
                    Label("Copy \(label)", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Copy \(label.lowercased())")
                .accessibilityInputLabels(["Copy \(label)", "Copy"])
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func copyValue() {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #endif
    }
}
