import SwiftUI

struct MascotGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let states: [(SessionStatus, Bool)] = [
        (.active, false), (.thinking, false), (.compacting, false), (.waitingPermission, false),
        (.waitingAnswer, false), (.waitingPlanReview, false), (.error, false), (.completed, true),
        (.completed, false), (.idle, false), (.completionUnconfirmed, false), (.observationUnavailable, false)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.mascotGuideTitle).font(.title2.bold())
                Spacer()
                Button(L10n.done) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.mascotGuideSummary).font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 14) {
                        ForEach(AgentType.allCases.filter(\.isSupported)) { agent in
                            HStack(spacing: 7) {
                                AgentIcon(agentType: agent, size: 28, status: .active)
                                Text(agent.displayName).font(.system(size: 10, weight: .medium)).lineLimit(2)
                            }
                        }
                    }
                    Divider()
                    Text(L10n.mascotTaskGuide).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { index in
                            AgentIcon(agentType: .codex, size: 30, status: .active,
                                      taskIdentity: MascotTaskIdentity(ordinal: index + 1, paletteIndex: index))
                        }
                    }.padding(.vertical, 4)
                    Divider()
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 16) {
                        ForEach(states.indices, id: \.self) { index in
                            let state = states[index]
                            HStack(spacing: 10) {
                                AgentIcon(agentType: .codex, size: 28, status: state.0,
                                          taskIdentity: MascotTaskIdentity(ordinal: 1, paletteIndex: 0),
                                          completionNeedsReview: state.1)
                                Text(state.1 ? L10n.completedNeedsReview : state.0.displayName)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }.padding(4)
            }
        }
        .padding(20)
        .frame(width: 610, height: 660)
        .background(.background)
        .accessibilityIdentifier("preferences.mascot-guide")
    }
}
