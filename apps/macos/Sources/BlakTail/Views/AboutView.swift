import BlakTailCore
import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BlakTail")
                .font(.largeTitle.weight(.semibold))
            Text(Tagline.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Native endpoint manager · minimum macOS 14 Sonoma")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
