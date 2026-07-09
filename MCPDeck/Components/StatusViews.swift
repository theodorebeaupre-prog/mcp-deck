import SwiftUI
import MCPDeckCore

extension HealthStatus {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .authRequired: return .yellow
        case .error: return .red
        case .timeout: return .orange
        case .checking: return .blue
        case .unknown: return .secondary.opacity(0.5)
        }
    }

    var shortLabel: String {
        switch self {
        case .ok: return "OK"
        case .authRequired: return "Auth required"
        case .error: return "Error"
        case .timeout: return "Timeout"
        case .checking: return "Checking…"
        case .unknown: return "Not checked"
        }
    }

    var detailText: String? {
        switch self {
        case .ok(let latency):
            return String(format: "Responded in %.0f ms", latency * 1000)
        case .error(let message):
            return message
        case .timeout:
            return "No response within the timeout"
        case .authRequired:
            return "The server answered 401/403 — authenticate from the client app"
        case .checking, .unknown:
            return nil
        }
    }
}

struct StatusDot: View {
    let status: HealthStatus

    var body: some View {
        if case .checking = status {
            ProgressView()
                .controlSize(.small)
                .frame(width: 10, height: 10)
        } else {
            Circle()
                .fill(status.tint)
                .frame(width: 8, height: 8)
                .accessibilityLabel(status.shortLabel)
        }
    }
}

struct StatusBadge: View {
    let status: HealthStatus

    var body: some View {
        HStack(spacing: 5) {
            StatusDot(status: status)
            Text(status.shortLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ClientTag: View {
    let client: ClientID

    var body: some View {
        Text(client.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct TransportTag: View {
    let transport: Transport

    var body: some View {
        Text(transport.kindLabel)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.quaternary))
    }
}
