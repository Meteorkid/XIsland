import Foundation

/// Lightweight localization without Xcode string catalogs.
/// Supports zh, ko, ja, fr, en (auto-detected from preferredLanguages).
enum L10n {
    // MARK: - Language detection

    private static let preferredLanguage: String = {
        let prefs = Locale.preferredLanguages
        for lang in prefs {
            let code = lang.prefix(2).lowercased()
            if ["zh", "ko", "ja", "fr"].contains(code) { return String(code) }
        }
        return "en"
    }()

    static var isChinese: Bool { preferredLanguage == "zh" }

    // MARK: - Helper

    private static func localized(_ key: String,
                                  zh: String, ko: String, ja: String, fr: String, en: String) -> String {
        switch preferredLanguage {
        case "zh": return zh
        case "ko": return ko
        case "ja": return ja
        case "fr": return fr
        default: return en
        }
    }

    // MARK: - UI strings

    static var activeSessions: String {
        localized("activeSessions",
            zh: "个活跃会话", ko: "개 활성 세션", ja: "件のアクティブセッション", fr: " sessions actives",
            en: " active")
    }

    static var approveTitle: String {
        localized("approveTitle",
            zh: "批准", ko: "허용", ja: "許可", fr: "Autoriser",
            en: "Allow")
    }

    static var denyTitle: String {
        localized("denyTitle",
            zh: "拒绝", ko: "거부", ja: "拒否", fr: "Refuser",
            en: "Deny")
    }

    static var planApprove: String {
        localized("planApprove",
            zh: "批准计划", ko: "계획 승인", ja: "計画を承認", fr: "Approuver le plan",
            en: "Approve Plan")
    }

    static var planDeny: String {
        localized("planDeny",
            zh: "拒绝计划", ko: "계획 거부", ja: "計画を拒否", fr: "Refuser le plan",
            en: "Deny Plan")
    }

    static var planFeedback: String {
        localized("planFeedback",
            zh: "反馈意见...", ko: "피드백...", ja: "フィードバック...", fr: "Commentaires...",
            en: "Feedback...")
    }

    static var jumpTitle: String {
        localized("jumpTitle",
            zh: "跳转", ko: "이동", ja: "ジャンプ", fr: "Aller",
            en: "Jump")
    }

    static var running: String {
        localized("running",
            zh: "运行中", ko: "실행 중", ja: "実行中", fr: "En cours",
            en: "Running")
    }

    static var thinking: String {
        localized("thinking",
            zh: "思考中", ko: "생각 중", ja: "思考中", fr: "Réflexion",
            en: "Thinking")
    }

    static var done: String {
        localized("done",
            zh: "完成", ko: "완료", ja: "完了", fr: "Terminé",
            en: "Done")
    }

    static var error: String {
        localized("error",
            zh: "错误", ko: "오류", ja: "エラー", fr: "Erreur",
            en: "Error")
    }

    static var permission: String {
        localized("permission",
            zh: "权限审批", ko: "권한 승인", ja: "権限承認", fr: "Autorisation",
            en: "Permission")
    }

    static var question: String {
        localized("question",
            zh: "问题回答", ko: "질문 답변", ja: "質問回答", fr: "Question",
            en: "Question")
    }

    static var review: String {
        localized("review",
            zh: "计划审查", ko: "계획 검토", ja: "計画レビュー", fr: "Révision",
            en: "Review")
    }

    static var compacting: String {
        localized("compacting",
            zh: "压缩中", ko: "압축 중", ja: "圧縮中", fr: "Compactage",
            en: "Compacting")
    }

    static var settings: String {
        localized("settings",
            zh: "设置", ko: "설정", ja: "設定", fr: "Paramètres",
            en: "Settings")
    }

    static var soundMute: String {
        localized("soundMute",
            zh: "静音", ko: "음소거", ja: "ミュート", fr: "Silence",
            en: "Mute")
    }

    static var rtkRunning: String {
        localized("rtkRunning",
            zh: "运行中", ko: "실행 중", ja: "実行中", fr: "En cours",
            en: "Running")
    }

    static var subagentCount: (_ count: Int) -> String = { count in
        switch preferredLanguage {
        case "zh": return "\(count)个子代理运行中"
        case "ko": return "하위 에이전트 \(count)개 실행 중"
        case "ja": return "\(count)個のサブエージェントが実行中"
        case "fr": return "\(count) sous-agent\(count > 1 ? "s" : "") en cours"
        default: return "\(count) subagent\(count > 1 ? "s" : "") running"
        }
    }

    static var usageQuota: String {
        localized("usageQuota",
            zh: "用量配额", ko: "사용량 할당량", ja: "使用量", fr: "Quota d'utilisation",
            en: "Usage Quota")
    }

    static var tokensLeft: (_ provider: String, _ tokens: String) -> String = { provider, tokens in
        switch preferredLanguage {
        case "zh": return "\(provider): 剩余 \(tokens) tokens"
        case "ko": return "\(provider): \(tokens) 남음"
        case "ja": return "\(provider): 残り\(tokens)トークン"
        case "fr": return "\(provider): \(tokens) restants"
        default: return "\(provider): \(tokens) left"
        }
    }

    static var autoCollapse: String {
        localized("autoCollapse",
            zh: "自动收起延迟", ko: "자동 접기 지연", ja: "自動折りたたみ遅延", fr: "Délai de réduction",
            en: "Auto-collapse delay")
    }

    static var completedDisplay: String {
        localized("completedDisplay",
            zh: "完成会话显示", ko: "완료 세션 표시", ja: "完了セッション表示", fr: "Affichage terminé",
            en: "Completed display")
    }

    static var smartSuppression: String {
        localized("smartSuppression",
            zh: "智能抑制", ko: "스마트 억제", ja: "スマート抑制", fr: "Suppression intelligente",
            en: "Smart suppression")
    }

    static var soundEffects: String {
        localized("soundEffects",
            zh: "音效", ko: "음향 효과", ja: "効果音", fr: "Effets sonores",
            en: "Sound effects")
    }

    static var importSoundPack: String {
        localized("importSoundPack",
            zh: "导入音效包", ko: "사운드 팩 가져오기", ja: "サウンドパックをインポート", fr: "Importer un pack audio",
            en: "Import Sound Pack")
    }

    static var builtinPack: String {
        localized("builtinPack",
            zh: "内置", ko: "내장", ja: "内蔵", fr: "Intégré",
            en: "Built-in")
    }

    static var agentConfig: String {
        localized("agentConfig",
            zh: "Agent 配置", ko: "에이전트 구성", ja: "エージェント設定", fr: "Configuration de l'agent",
            en: "Agent Configuration")
    }

    static var autoConfigured: String {
        localized("autoConfigured",
            zh: "已自动配置", ko: "자동 구성됨", ja: "自動設定済み", fr: "Auto-configuré",
            en: "Auto-configured")
    }

    static var notConfigured: String {
        localized("notConfigured",
            zh: "未配置", ko: "구성되지 않음", ja: "未設定", fr: "Non configuré",
            en: "Not configured")
    }

    static var keyboardShortcuts: String {
        localized("keyboardShortcuts",
            zh: "键盘快捷键", ko: "키보드 단축키", ja: "キーボードショートカット", fr: "Raccourcis clavier",
            en: "Keyboard Shortcuts")
    }

    static var activityLog: String {
        localized("activityLog",
            zh: "活动日志", ko: "활동 로그", ja: "アクティビティログ", fr: "Journal d'activité",
            en: "Activity Log")
    }

    static var expandCollapse: String {
        localized("expandCollapse",
            zh: "展开/收起", ko: "확장/접기", ja: "展開/折りたたみ", fr: "Déplier/Replier",
            en: "Expand/Collapse")
    }
}
