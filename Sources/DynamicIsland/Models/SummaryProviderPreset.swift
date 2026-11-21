import Foundation

enum SummaryProviderKind {
    case openAICompatible
    case anthropic
    case ollama
}

/// 摘要后端预设。免费项排在前面：摘要只需要短文本，小模型完全够用。
struct SummaryProviderPreset: Identifiable {
    let id: String
    let title: String
    let baseURL: String?
    let defaultModel: String
    let kind: SummaryProviderKind
    let note: String?

    static let all: [SummaryProviderPreset] = [
        SummaryProviderPreset(
            id: "zhipu", title: "智谱 GLM-4-Flash（免费）",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            defaultModel: "glm-4-flash", kind: .openAICompatible,
            note: "注册即免费，中文摘要质量好，国内直连。"
        ),
        SummaryProviderPreset(
            id: "gemini", title: "Google Gemini（免费额度）",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            defaultModel: "gemini-2.0-flash", kind: .openAICompatible,
            note: "有免费额度，需要可访问 Google 的网络。"
        ),
        SummaryProviderPreset(
            id: "groq", title: "Groq（免费额度）",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile", kind: .openAICompatible,
            note: "免费额度、响应很快，英文摘要更稳。"
        ),
        SummaryProviderPreset(
            id: "openrouter", title: "OpenRouter（:free 模型）",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "meta-llama/llama-3.3-70b-instruct:free", kind: .openAICompatible,
            note: "可选带 :free 后缀的免费模型，额度受上游限制。"
        ),
        SummaryProviderPreset(
            id: "siliconflow", title: "硅基流动（免费额度）",
            baseURL: "https://api.siliconflow.cn/v1",
            defaultModel: "Qwen/Qwen2.5-7B-Instruct", kind: .openAICompatible,
            note: "国内可直连，注册赠送额度。"
        ),
        SummaryProviderPreset(
            id: "ollama", title: "本地 Ollama（完全免费）",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "", kind: .ollama,
            note: "需要先 ollama pull 一个模型（如 qwen2.5:3b）。"
        ),
        SummaryProviderPreset(
            id: "openai", title: "OpenAI（付费）",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini", kind: .openAICompatible,
            note: "按 token 计费，质量稳定。"
        ),
        SummaryProviderPreset(
            id: "anthropic", title: "Anthropic（付费）",
            baseURL: nil,
            defaultModel: "claude-3-5-haiku-latest", kind: .anthropic,
            note: "按 token 计费。"
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
