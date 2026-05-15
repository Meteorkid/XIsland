import AppKit
import SwiftUI

struct CollapsedPillView: View {
    @Environment(SessionManager.self) private var manager
    /// Obscured: left = expanded-list session that last received a message; right = active count.
    /// Unobscured: same session count/order as the expanded list (`visibleSessions`).
    let obscuredByNotch: Bool
    let onTap: () -> Void

    private var visible: [AgentSession] { manager.visibleSessions }

    var body: some View {
        Button(action: onTap) {
            Group {
                if obscuredByNotch {
                    obscuredBarContent
                } else {
                    unobscuredCenteredIcons
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(TestAccessibility.collapsedPill)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var obscuredBarContent: some View {
        HStack(spacing: 0) {
            obscuredLeadingIcon
            Spacer(minLength: 6)
            activeCountLabel
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    private var unobscuredCenteredIcons: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if visible.isEmpty {
                idleContent
            } else {
                HStack(spacing: 8) {
                    ForEach(visible) { session in
                        AgentIcon(agentType: session.agentType, size: 22, status: session.status)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private var needsAttention: Bool {
        visible.contains { $0.status == .waitingPermission || $0.status == .waitingAnswer || $0.status == .waitingPlanReview }
    }

    @ViewBuilder
    private var obscuredLeadingIcon: some View {
        if let session = manager.latestMessagedVisibleSession {
            ZStack(alignment: .topTrailing) {
                AgentIcon(agentType: session.agentType, size: 20, status: session.status)
                if needsAttention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 4, y: -2)
                }
            }
            .accessibilityLabel("Session that last received a message")
        } else {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.green.opacity(0.85))
                            .frame(width: 20, height: 20)
                    }
                }
                if needsAttention {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                }
            }
            .accessibilityLabel("X Island")
        }
    }

    private var activeCountLabel: some View {
        let n = manager.activeSessions.count
        return HStack(spacing: 3) {
            Text("\(n)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .monospacedDigit()
            Text("active")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
        }
        .accessibilityLabel("\(n) active agents")
    }

    private var idleContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green.opacity(0.6))
                .frame(width: 6, height: 6)
            Text("Ready")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
