import Foundation

/// Lightweight localization without Xcode string catalogs.
/// Supports zh, ko, ja, fr, en. Auto-detected from preferredLanguages,
/// with optional manual override via UserDefaults "appLanguage".
enum L10n {
    // MARK: - Available languages

    static let availableLanguages: [(code: String, name: String)] = [
        ("auto", "Auto"),
        ("zh", "中文"),
        ("en", "English"),
        ("ko", "한국어"),
        ("ja", "日本語"),
        ("fr", "Français"),
    ]

    static var currentLanguageName: String {
        availableLanguages.first { $0.code == effectiveLanguage }?.name ?? "English"
    }

    // MARK: - Language detection

    static var effectiveLanguage: String {
        if let manual = UserDefaults.standard.string(forKey: "appLanguage"),
           manual != "auto",
           availableLanguages.contains(where: { $0.code == manual }) {
            return manual
        }
        let prefs = Locale.preferredLanguages
        for lang in prefs {
            let code = lang.prefix(2).lowercased()
            if ["zh", "ko", "ja", "fr"].contains(code) { return String(code) }
        }
        return "en"
    }

    static var isChinese: Bool { effectiveLanguage == "zh" }

    // MARK: - Helper

    private static func localized(_ key: String,
                                  zh: String, ko: String, ja: String, fr: String, en: String) -> String {
        switch effectiveLanguage {
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

    static var unmute: String {
        localized("unmute",
            zh: "取消静音", ko: "음소거 해제", ja: "ミュート解除", fr: "Réactiver le son",
            en: "Unmute")
    }

    static var prefsEllipsis: String {
        localized("prefsEllipsis",
            zh: "设置...", ko: "설정...", ja: "設定...", fr: "Paramètres...",
            en: "Preferences...")
    }

    static var quitApp: String {
        localized("quitApp",
            zh: "退出 X Island", ko: "X Island 종료", ja: "X Islandを終了", fr: "Quitter X Island",
            en: "Quit X Island")
    }

    static var dismissAll: String {
        localized("dismissAll",
            zh: "关闭所有会话", ko: "모든 세션 닫기", ja: "すべてのセッションを閉じる", fr: "Fermer toutes les sessions",
            en: "Dismiss All Sessions")
    }

    static var ready: String {
        localized("ready",
            zh: "就绪", ko: "준비됨", ja: "準備完了", fr: "Prêt",
            en: "Ready")
    }

    static var active: String {
        localized("active",
            zh: "活跃", ko: "활성", ja: "アクティブ", fr: "actifs",
            en: "active")
    }

    // MARK: - Preferences

    static var language: String {
        localized("language",
            zh: "语言", ko: "언어", ja: "言語", fr: "Langue",
            en: "Language")
    }

    static var bypassMode: String {
        localized("bypassMode",
            zh: "自动模式", ko: "자동 모드", ja: "自動モード", fr: "Mode automatique",
            en: "Bypass mode")
    }

    static var bypassDesc: String {
        localized("bypassDesc",
            zh: "自动批准所有权限、问题和计划审查", ko: "모든 권한, 질문, 계획 검토 자동 승인",
            ja: "すべての権限、質問、計画レビューを自動承認",
            fr: "Approuver automatiquement toutes les autorisations, questions et révisions de plan",
            en: "Auto-approve all permissions, questions, and plan reviews")
    }

    static var panelWidth: String {
        localized("panelWidth",
            zh: "面板宽度", ko: "패널 너비", ja: "パネル幅", fr: "Largeur du panneau",
            en: "Panel width")
    }

    static var panelMaxHeight: String {
        localized("panelMaxHeight",
            zh: "面板最大高度", ko: "패널 최대 높이", ja: "パネル最大高さ", fr: "Hauteur max du panneau",
            en: "Panel max height")
    }

    static var panelSizePx: (_ px: Int) -> String = { px in
        switch effectiveLanguage {
        case "zh": return "\(px)像素"
        case "ko": return "\(px)px"
        case "ja": return "\(px)px"
        case "fr": return "\(px) px"
        default: return "\(px)px"
        }
    }

    // MARK: - Sound

    static var soundEnabled: String {
        localized("soundEnabled",
            zh: "声音开关", ko: "사운드 켜기", ja: "サウンドオン", fr: "Son activé",
            en: "Sound enabled")
    }

    static var volume: String {
        localized("volume",
            zh: "音量", ko: "볼륨", ja: "音量", fr: "Volume",
            en: "Volume")
    }

    // MARK: - Quiet Hours

    static var quietHours: String {
        localized("quietHours",
            zh: "定时勿扰", ko: "방해 금지 시간", ja: "おやすみ時間", fr: "Heures de silence",
            en: "Quiet Hours")
    }

    static var enableQuietHours: String {
        localized("enableQuietHours",
            zh: "启用定时勿扰", ko: "방해 금지 시간 활성화", ja: "おやすみ時間を有効にする",
            fr: "Activer les heures de silence",
            en: "Enable quiet hours")
    }

    static var fromTime: String {
        localized("fromTime",
            zh: "从", ko: "시작", ja: "開始", fr: "De",
            en: "From")
    }

    static var toTime: String {
        localized("toTime",
            zh: "至", ko: "종료", ja: "終了", fr: "À",
            en: "To")
    }

    static var statusLabel: String {
        localized("status",
            zh: "状态", ko: "상태", ja: "状態", fr: "Statut",
            en: "Status")
    }

    static var quietHoursActive: String {
        localized("quietHoursActive",
            zh: "勿扰中 — 声音已静音", ko: "활성화됨 — 음소거됨", ja: "有効 — ミュート中",
            fr: "Actif — sons coupés",
            en: "Active — sounds muted")
    }

    static var quietHoursInactive: String {
        localized("quietHoursInactive",
            zh: "非勿扰时段", ko: "방해 금지 시간 아님", ja: "時間外",
            fr: "Hors période de silence",
            en: "Outside quiet hours")
    }

    static var disabled: String {
        localized("disabled",
            zh: "已禁用", ko: "비활성화됨", ja: "無効", fr: "Désactivé",
            en: "Disabled")
    }

    // MARK: - Mute Rules

    static var muteRules: String {
        localized("muteRules",
            zh: "静音规则", ko: "음소거 규칙", ja: "ミュートルール", fr: "Règles de silence",
            en: "Mute Rules")
    }

    static var noRules: String {
        localized("noRules",
            zh: "暂无规则", ko: "규칙 없음", ja: "ルールなし", fr: "Aucune règle",
            en: "No rules configured")
    }

    static var regexPattern: String {
        localized("regexPattern",
            zh: "正则表达式", ko: "정규식 패턴", ja: "正規表現パターン", fr: "Expression régulière",
            en: "Regex pattern")
    }

    static var addRule: String {
        localized("addRule",
            zh: "添加", ko: "추가", ja: "追加", fr: "Ajouter",
            en: "Add")
    }

    // MARK: - Recap

    static var showRecap: String {
        localized("showRecap",
            zh: "展开回顾", ko: "요약 보기", ja: "サマリーを表示", fr: "Afficher le résumé",
            en: "Show recap")
    }

    static var hideRecap: String {
        localized("hideRecap",
            zh: "收起回顾", ko: "요약 숨기기", ja: "サマリーを隠す", fr: "Masquer le résumé",
            en: "Hide recap")
    }

    // MARK: - Subagent

    static func subagentCount(_ count: Int) -> String {
        switch effectiveLanguage {
        case "zh": return "\(count)个子代理"
        case "ko": return "하위 에이전트 \(count)개"
        case "ja": return "\(count)個のサブエージェント"
        case "fr": return "\(count) sous-agent\(count > 1 ? "s" : "")"
        default: return "\(count) subagent\(count > 1 ? "s" : "")"
        }
    }

    static func subagentCountRunning(_ count: Int) -> String {
        switch effectiveLanguage {
        case "zh": return "\(count)个子代理运行中"
        case "ko": return "하위 에이전트 \(count)개 실행 중"
        case "ja": return "\(count)個のサブエージェントが実行中"
        case "fr": return "\(count) sous-agent\(count > 1 ? "s" : "") en cours"
        default: return "\(count) subagent\(count > 1 ? "s" : "") running"
        }
    }

    // MARK: - General prefs

    static var usageQuota: String {
        localized("usageQuota",
            zh: "用量配额", ko: "사용량 할당량", ja: "使用量", fr: "Quota d'utilisation",
            en: "Usage Quota")
    }

    static func tokensLeft(_ provider: String, _ tokens: String) -> String {
        switch effectiveLanguage {
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

    // MARK: - Preferences section titles

    static var sectionSystem: String {
        localized("system",
            zh: "系统", ko: "시스템", ja: "システム", fr: "Système",
            en: "System")
    }

    static var sectionBehavior: String {
        localized("behavior",
            zh: "行为", ko: "동작", ja: "動作", fr: "Comportement",
            en: "Behavior")
    }

    static var sectionDisplay: String {
        localized("display",
            zh: "显示", ko: "표시", ja: "表示", fr: "Affichage",
            en: "Display")
    }

    static var sectionSound: String {
        localized("sectionSound",
            zh: "声音", ko: "사운드", ja: "サウンド", fr: "Son",
            en: "Sound")
    }

    static var sectionPlayback: String {
        localized("playback",
            zh: "播放", ko: "재생", ja: "再生", fr: "Lecture",
            en: "Playback")
    }

    static var sectionEvents: String {
        localized("sectionEvents",
            zh: "事件", ko: "이벤트", ja: "イベント", fr: "Événements",
            en: "Events")
    }

    static var sectionSoundPack: String {
        localized("sectionSoundPack",
            zh: "音效包", ko: "사운드 팩", ja: "サウンドパック", fr: "Pack audio",
            en: "Sound Pack")
    }

    static var sectionUsageTracking: String {
        localized("usageTracking",
            zh: "用量追踪", ko: "사용량 추적", ja: "使用量追跡", fr: "Suivi d'utilisation",
            en: "Usage Tracking")
    }

    static var sectionRemoteServers: String {
        localized("remoteServers",
            zh: "远程服务器", ko: "원격 서버", ja: "リモートサーバー", fr: "Serveurs distants",
            en: "Remote Servers")
    }

    static var sectionCLIHooks: String {
        localized("cliHooks",
            zh: "CLI Hooks", ko: "CLI 훅", ja: "CLIフック", fr: "Hooks CLI",
            en: "CLI Hooks")
    }

    static var sectionIDEIntegration: String {
        localized("ideIntegration",
            zh: "IDE 集成", ko: "IDE 통합", ja: "IDE統合", fr: "Intégration IDE",
            en: "IDE Integration")
    }

    static var sectionMaintenance: String {
        localized("maintenance",
            zh: "维护", ko: "유지보수", ja: "メンテナンス", fr: "Maintenance",
            en: "Maintenance")
    }

    static var sectionSessions: String {
        localized("sectionSessions",
            zh: "会话", ko: "세션", ja: "セッション", fr: "Sessions",
            en: "Sessions")
    }

    static var sectionAbout: String {
        localized("sectionAbout",
            zh: "关于", ko: "정보", ja: "について", fr: "À propos",
            en: "About")
    }

    static var sectionMacPrivacy: String {
        localized("sectionMacPrivacy",
            zh: "macOS 隐私与授权",
            ko: "macOS 개인정보 보호 및 권한",
            ja: "macOSのプライバシーとアクセス",
            fr: "Confidentialité et accès macOS",
            en: "macOS Privacy & Access")
    }

    static var macPrivacyIntro: String {
        localized("macPrivacyIntro",
            zh: "首次使用可在系统设置中授予所需权限：「自动化」用于跳转终端标签；辅助功能仅在部分场景需要。",
            ko: "첫 실행 시 시스템에서 권한을 허용하세요. 터미널 탭 이동에는 「자동화」가 필요합니다.",
            ja: "初回はシステム設定で許可してください。ターミナルタブへのジャンプには「自動化」が必要です。",
            fr: "Lors de la première utilisation, accordez les accès requis dans Réglages. « Automatisation » sert à aller à l’onglet du terminal.",
            en: "On first launch, grant access in System Settings. Automation is needed for jumping to terminal tabs (Apple Events).")
    }

    static var openPrivacySecurityButton: String {
        localized("openPrivacySecurityButton",
            zh: "隐私与安全性…", ko: "개인정보 보호 및 보안…", ja: "プライバシーとセキュリティ…", fr: "Confidentialité et sécurité…",
            en: "Privacy & Security…")
    }

    static var openAccessibilityButton: String {
        localized("openAccessibilityButton",
            zh: "辅助功能…", ko: "손쉬운 사용…", ja: "アクセシビリティ…", fr: "Accessibilité…",
            en: "Accessibility…")
    }

    static var openAutomationButton: String {
        localized("openAutomationButton",
            zh: "自动化（Apple 事件）…", ko: "자동화(Apple 이벤트)…", ja: "自動化（Apple イベント）…", fr: "Automatisation (Événements Apple)…",
            en: "Automation (Apple Events)…")
    }

    static var openLoginItemsButton: String {
        localized("openLoginItemsButton",
            zh: "登录项与扩展…", ko: "로그인 항목 및 확장…", ja: "ログイン項目と拡張機能…", fr: "Ouverture et extensions…",
            en: "Login Items & Extensions…")
    }

    // MARK: - Preferences pane titles

    static var paneGeneral: String {
        localized("paneGeneral",
            zh: "通用", ko: "일반", ja: "一般", fr: "Général",
            en: "General")
    }

    static var paneAgents: String {
        localized("paneAgents",
            zh: "代理", ko: "에이전트", ja: "エージェント", fr: "Agents",
            en: "Agents")
    }

    // MARK: - Preferences misc rows

    static var launchAtLogin: String {
        localized("launchAtLogin",
            zh: "登录时启动", ko: "로그인 시 시작", ja: "ログイン時に起動", fr: "Lancer à l'ouverture",
            en: "Launch at Login")
    }

    static var showOnAllSpaces: String {
        localized("showOnAllSpaces",
            zh: "在所有桌面显示", ko: "모든 데스크탑에 표시", ja: "すべてのデスクトップに表示",
            fr: "Afficher sur tous les bureaux",
            en: "Show on all Spaces")
    }

    static var hideInFullscreen: String {
        localized("hideInFullscreen",
            zh: "全屏时隐藏", ko: "전체 화면 시 숨기기", ja: "フルスクリーン時に隠す",
            fr: "Masquer en plein écran",
            en: "Hide in fullscreen")
    }

    static var autoHideIdle: String {
        localized("autoHideIdle",
            zh: "空闲时自动隐藏", ko: "유휴 시 자동 숨기기", ja: "アイドル時に自動非表示",
            fr: "Masquer automatiquement en inactivité",
            en: "Auto-hide when idle")
    }

    static var compactBadges: String {
        localized("compactBadges",
            zh: "紧凑标签", ko: "소형 배지", ja: "コンパクトバッジ", fr: "Badges compacts",
            en: "Compact badges")
    }

    static var showTimestamps: String {
        localized("showTimestamps",
            zh: "显示时间戳", ko: "타임스탬프 표시", ja: "タイムスタンプを表示",
            fr: "Afficher l'horodatage",
            en: "Show timestamps")
    }

    static var reduceMotion: String {
        localized("reduceMotion",
            zh: "减少动画", ko: "모션 줄이기", ja: "モーションを減らす", fr: "Réduire les animations",
            en: "Reduce motion")
    }

    static var noRemoteServers: String {
        localized("noRemoteServers",
            zh: "未配置远程服务器", ko: "원격 서버 구성 안 됨", ja: "リモートサーバー未設定",
            fr: "Aucun serveur distant configuré",
            en: "No remote servers configured")
    }

    static var hookActive: String {
        localized("hookActive",
            zh: "活跃", ko: "활성", ja: "有効", fr: "Actif",
            en: "Active")
    }

    static var hookOff: String {
        localized("hookOff",
            zh: "关闭", ko: "꺼짐", ja: "オフ", fr: "Désactivé",
            en: "Off")
    }

    static var ideInstalled: String {
        localized("ideInstalled",
            zh: "已安装", ko: "설치됨", ja: "インストール済み", fr: "Installé",
            en: "Installed")
    }

    static var ideNotFound: String {
        localized("ideNotFound",
            zh: "未找到", ko: "찾을 수 없음", ja: "見つかりません", fr: "Introuvable",
            en: "Not Found")
    }

    // MARK: - Preferences subtitles

    static var autoCollapseDesc: String {
        localized("autoCollapseDesc",
            zh: "任务完成后面板保持展开的时长", ko: "작업 완료 후 패널이 열려 있는 시간",
            ja: "タスク完了後にパネルが開いたままになる時間",
            fr: "Durée pendant laquelle le panneau reste ouvert après une tâche",
            en: "How long the panel stays open after a task completes")
    }

    static var expandedInactivityAutoHide: String {
        localized("expandedInactivityAutoHide",
            zh: "展开后无操作收起",
            ko: "펼침 후 유휴 시 접기",
            ja: "展開後の無操作で折りたたむ",
            fr: "Réduire si inactif",
            en: "Collapse when idle while expanded")
    }

    static var expandedInactivityAutoHideDesc: String {
        localized("expandedInactivityAutoHideDesc",
            zh: "展开状态下无任何操作后自动收起的等待时间；选「永不」则关闭",
            ko: "펼친 뒤 상호작용이 없을 때 접히기까지의 시간입니다. 「안 함」이면 비활성화됩니다.",
            ja: "展開中に操作がないとき、自動で折りたたむまでの時間。「なし」で無効化。",
            fr: "Délai sans interaction avant réduction ; « Jamais » désactive.",
            en: "Delay with no activity before the expanded panel collapses; “Never” turns this off.")
    }

    static var hoverExitCollapse: String {
        localized("hoverExitCollapse",
            zh: "鼠标离开后收起",
            ko: "포인터가 벗어난 뒤 접기",
            ja: "ポインター退避後に折りたたむ",
            fr: "Réduire après sortie du pointeur",
            en: "Collapse after pointer leaves")
    }

    static var hoverExitCollapseDesc: String {
        localized("hoverExitCollapseDesc",
            zh: "悬停展开或无会话时，指针离开岛区域后过多久收起",
            ko: "호버로 펼쳤거나 세션이 없을 때, 포인터가 영역을 벗어난 뒤 접히기까지의 지연",
            ja: "ホバー展開、またはセゼロ件のとき、ポインターが離れてから折りたたむまでの遅延",
            fr: "Délai après la sortie du pointeur (ouverture au survol ou panneau vide).",
            en: "After hover-expand or with no sessions, how long to wait once the pointer leaves before collapsing.")
    }

    static var neverOption: String {
        localized("neverOption",
            zh: "永不", ko: "안 함", ja: "なし", fr: "Jamais",
            en: "Never")
    }

    static var smartSuppressionDesc: String {
        localized("smartSuppressionDesc",
            zh: "当 Agent 终端获得焦点时不自动展开", ko: "에이전트 터미널이 포커스되면 자동 확장 안 함",
            ja: "エージェント端末がフォーカスされているときは自動展開しない",
            fr: "Ne pas ouvrir automatiquement quand le terminal de l'agent est actif",
            en: "Don't auto-expand when the agent terminal is focused")
    }

    static var completedDisplayDesc: String {
        localized("completedDisplayDesc",
            zh: "已完成会话保持可见的时长", ko: "완료된 세션이 표시되는 시간",
            ja: "完了したセッションが表示され続ける時間",
            fr: "Durée d'affichage des sessions terminées",
            en: "How long completed sessions remain visible")
    }

    // MARK: - About pane sections

    static var sectionApplication: String {
        localized("sectionApplication",
            zh: "应用程序", ko: "애플리케이션", ja: "アプリケーション", fr: "Application",
            en: "Application")
    }

    static var sectionUpdates: String {
        localized("sectionUpdates",
            zh: "更新", ko: "업데이트", ja: "アップデート", fr: "Mises à jour",
            en: "Updates")
    }

    // MARK: - Misc UI

    static var noActivity: String {
        localized("noActivity",
            zh: "暂无活动", ko: "활동 없음", ja: "アクティビティなし", fr: "Aucune activité",
            en: "No activity yet")
    }

    static func toolRunning(_ tool: String) -> String {
        switch effectiveLanguage {
        case "zh": return "正在运行 \(tool)..."
        case "ko": return "\(tool) 실행 중..."
        case "ja": return "\(tool) 実行中..."
        case "fr": return "Exécution de \(tool)..."
        default: return "Running \(tool)..."
        }
    }

    static var youPrefix: String {
        localized("youPrefix",
            zh: "你", ko: "당신", ja: "あなた", fr: "Vous",
            en: "You")
    }
}
