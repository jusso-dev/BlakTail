import BlakTailCore
import SwiftUI

struct EndpointRowView: View {
    let device: EndpointDevice

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: device.credentialState.symbol)
                .foregroundStyle(statusColour)
                .accessibilityHidden(true)
                .frame(minWidth: 28)
            VStack(alignment: .leading) {
                Text(device.displayName)
                    .font(.headline)
                Text(secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(device.credentialState.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(device.displayName), \(device.organisationName), \(device.credentialState.label)"
        )
        .accessibilityHint("Opens endpoint details")
    }

    private var secondaryLine: String {
        if device.friendlyName == nil {
            return device.organisationName
        }
        return "\(device.technicalName) · \(device.organisationName)"
    }

    private var statusColour: Color {
        switch device.credentialState {
        case .active: return .green
        case .expiresSoon: return .orange
        case .expired, .revoked: return .red
        }
    }
}
