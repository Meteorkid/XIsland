import SwiftUI

struct PermissionApprovalView: View {
    let session: AgentSession
    let onComplete: () -> Void
    @Environment(SessionManager.self) private var manager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(.white.opacity(0.08))

            if let perm = session.pendingPermission {
                permissionContent(perm)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.green.opacity(0.6))
                    Text("Permission was handled externally")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { onComplete() }
            }
        }
        .accessibilityIdentifier(TestAccessibility.permissionPanel)
    }

    private var displayAgent: AgentType {
        session.pendingPermission?.requestingAgent ?? session.agentType
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIcon(agentType: displayAgent, size: 20)
            Text(displayAgent.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("Permission Request")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func permissionContent(_ perm: PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 16))
                    .padding(.top, 1)
                Text(perm.tool)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            if !perm.description.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("$ ")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.6))
                        Text(perm.description)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IslandStyle.insetFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if let path = perm.filePath, !path.isEmpty {
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                }
            } else if let path = perm.filePath, !path.isEmpty {
                HStack(spacing: 0) {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IslandStyle.insetFill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let diff = perm.diff, !diff.isEmpty {
                diffView(diff)
            }

            HStack(spacing: 8) {
                Button {
                    manager.denyPermission(session: session)
                    onComplete()
                } label: {
                    HStack {
                        Text("Deny")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("⌘N")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier(TestAccessibility.permissionDenyButton)

                Button {
                    manager.approvePermission(session: session)
                    onComplete()
                } label: {
                    HStack {
                        Text("Allow Once")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("⌘Y")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.green.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("y", modifiers: .command)
                .accessibilityIdentifier(TestAccessibility.permissionApproveButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func diffView(_ diff: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(20).enumerated()), id: \.offset) { _, line in
                    let str = String(line)
                    HStack(spacing: 0) {
                        Text(str)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(diffColor(for: str))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(diffBackground(for: str))
                }
            }
        }
        .frame(maxHeight: 120)
        .background(IslandStyle.codeWell)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func diffColor(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.9) }
        if line.hasPrefix("-") { return .red.opacity(0.9) }
        return .white.opacity(0.5)
    }

    private func diffBackground(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.08) }
        if line.hasPrefix("-") { return .red.opacity(0.08) }
        return .clear
    }
}
