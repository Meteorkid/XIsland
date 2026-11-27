import Foundation

enum SummaryProviderKind {
    case openAICompatible
    case anthropic
    case ollama
}

/// 摘要后端预设。免费项排在前面：摘要只需要短文本，小模型完全够用。
struct SummaryProviderPreset: Identifiable {
    let id: String
    let baseURL: String?
    let defaultModel: String
    let kind: SummaryProviderKind

    var title: String { L10n.summaryProviderTitle(id) }
    var note: String? { L10n.summaryProviderNote(id) }

    static let all: [SummaryProviderPreset] = [
        SummaryProviderPreset(
            id: "zhipu",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-flash", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.0-flash", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "groq",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "openrouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "meta-llama/llama-3.3-70b-instruct:free", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "siliconflow",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-7B-Instruct", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "", kind: .ollama
        ),
        SummaryProviderPreset(
            id: "openai",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini", kind: .openAICompatible
        ),
        SummaryProviderPreset(
            id: "anthropic",
            baseURL: nil,
            defaultModel: "claude-3-5-haiku-latest", kind: .anthropic
        ),
    ]

    static func preset(_ id: String) -> SummaryProviderPreset {
        all.first { $0.id == id } ?? all[0]
    }

    var environmentKeyName: String? {
        switch id {
        case "openai": return "OPENAI_API_KEY"
        case "anthropic": return "ANTHROPIC_API_KEY"
        default: return nil
        }
    }
}
