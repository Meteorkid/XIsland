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
        if let manual = AppPreferences.defaults.string(forKey: "appLanguage"),
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

    static func mascotTask(_ number: Int) -> String {
        String(format: localized("mascotTask", zh: "任务 %d", ko: "작업 %d", ja: "タスク %d", fr: "Tâche %d", en: "Task %d"), number)
    }
    static var completedNeedsReview: String {
        localized("completedNeedsReview", zh: "已完成 · 未查看", ko: "완료 · 읽지 않음", ja: "完了 · 未確認", fr: "Terminé · Non consulté", en: "Completed · Unviewed")
    }
    static var markCompletionReviewed: String {
        localized("markCompletionReviewed", zh: "标为已查看", ko: "확인함으로 표시", ja: "確認済みにする", fr: "Marquer comme consulté", en: "Mark as viewed")
    }
    static var mascotGuideTitle: String {
        localized("mascotGuideTitle", zh: "吉祥物识别图例", ko: "마스코트 안내", ja: "マスコットの凡例", fr: "Légende des mascottes", en: "Mascot legend")
    }
    static var mascotGuideSummary: String {
        localized("mascotGuideSummary", zh: "造型认软件，颜色与编号认任务，表情认状态。", ko: "모양은 앱, 색상과 번호는 작업, 표정은 상태를 나타냅니다.", ja: "形はアプリ、色と番号はタスク、表情は状態を示します。", fr: "La forme identifie l’app, la couleur et le numéro la tâche, l’expression son état.", en: "Shape identifies the app, color and number identify the task, expression shows its state.")
    }
    static var mascotTaskGuide: String {
        localized("mascotTaskGuide", zh: "同一聊天／任务保留配色和编号。颜色循环时仍以编号区分；打开详情或主动跳转后确认已查看。", ko: "같은 작업은 색상과 번호를 유지합니다. 색상이 반복되면 번호로 구분합니다. 세부정보 또는 이동 시 확인됩니다.", ja: "同じタスクは色と番号を保持します。色が循環しても番号で区別できます。詳細表示または移動で確認済みになります。", fr: "Une tâche garde sa couleur et son numéro. Les numéros distinguent les couleurs répétées. Ouvrir les détails ou accéder à la tâche la marque consultée.", en: "A task keeps its color and number. Numbers distinguish repeated colors. Opening details or jumping to a task marks its completion viewed.")
    }

    static var historySaveFailed: String {
        localized("historySaveFailed", zh: "历史暂未保存，相关会话将保留供重试。",
                  ko: "기록이 저장되지 않았습니다. 재시도를 위해 세션을 유지합니다.",
                  ja: "履歴は未保存です。再試行できるようセッションを保持します。",
                  fr: "Historique non enregistré. Les sessions sont conservées pour réessayer.",
                  en: "History is not saved. Sessions are retained so you can retry.")
    }

    static var retryHistorySave: String {
        localized("retryHistorySave", zh: "重试保存", ko: "저장 재시도", ja: "保存を再試行",
                  fr: "Réessayer l’enregistrement", en: "Retry saving")
    }

    static var collapsePanel: String {
        localized("collapsePanel", zh: "收起面板", ko: "패널 접기", ja: "パネルを折りたたむ",
                  fr: "Réduire le panneau", en: "Collapse panel")
    }

    static var searchHistory: String {
        localized("searchHistory", zh: "搜索", ko: "검색", ja: "検索", fr: "Rechercher", en: "Search")
    }
    static var clearHistorySearch: String {
        localized("clearHistorySearch", zh: "清除搜索", ko: "검색 지우기", ja: "検索を解除", fr: "Effacer la recherche", en: "Clear search")
    }
    static var historyReadFailed: String {
        localized("historyReadFailed", zh: "历史读取失败", ko: "기록을 읽지 못했습니다", ja: "履歴を読み込めませんでした", fr: "Lecture de l’historique impossible", en: "History could not be loaded")
    }
    static var retryHistoryRead: String {
        localized("retryHistoryRead", zh: "重新读取", ko: "다시 읽기", ja: "再読み込み", fr: "Réessayer", en: "Retry loading")
    }
    static var noHistoryMatches: String {
        localized("noHistoryMatches", zh: "没有匹配的历史记录", ko: "일치하는 기록 없음", ja: "一致する履歴はありません", fr: "Aucun historique correspondant", en: "No matching history")
    }
    static var historyPreviousPage: String {
        localized("historyPreviousPage", zh: "上一页", ko: "이전", ja: "前へ", fr: "Précédent", en: "Previous")
    }
    static var historyNextPage: String {
        localized("historyNextPage", zh: "下一页", ko: "다음", ja: "次へ", fr: "Suivant", en: "Next")
    }
    static func historyPageSummary(_ page: Int, _ pages: Int, _ count: Int) -> String {
        localized("historyPageSummary", zh: "第 \(page)/\(pages) 页 · 共 \(count) 条",
                  ko: "\(page)/\(pages) 페이지 · \(count)개", ja: "\(page)/\(pages) ページ · \(count) 件",
                  fr: "Page \(page)/\(pages) · \(count) entrées", en: "Page \(page)/\(pages) · \(count) records")
    }
    static var exportAllHistory: String {
        localized("exportAllHistory", zh: "导出全部历史", ko: "전체 기록 내보내기", ja: "すべての履歴を書き出す", fr: "Exporter tout l’historique", en: "Export all history")
    }
    static var historyExportScope: String {
        localized("historyExportScope", zh: "导出全部会话、聊天和工具输入输出，不受当前搜索或页码限制。",
                  ko: "현재 검색이나 페이지에 관계없이 모든 세션, 대화, 도구 입력과 출력을 내보냅니다.",
                  ja: "検索やページに関係なく、全セッション、会話、ツールの入出力を書き出します。",
                  fr: "Exporte toutes les sessions, conversations et entrées/sorties d’outils, sans limite de recherche ou de page.",
                  en: "Exports all sessions, chats and tool inputs/outputs, regardless of the current search or page.")
    }
    static var historyExportFailed: String {
        localized("historyExportFailed", zh: "历史导出失败", ko: "기록 내보내기 실패", ja: "履歴の書き出しに失敗しました", fr: "Échec de l’export", en: "History export failed")
    }
    static func historyExportSucceeded(_ count: Int) -> String {
        localized("historyExportSucceeded", zh: "已导出 \(count) 条历史记录", ko: "기록 \(count)개 내보냄", ja: "履歴 \(count) 件を書き出しました",
                  fr: "\(count) entrées exportées", en: "Exported \(count) history records")
    }
    static var showHistoryExport: String {
        localized("showHistoryExport", zh: "在 Finder 中显示", ko: "Finder에서 보기", ja: "Finderに表示", fr: "Afficher dans le Finder", en: "Show in Finder")
    }
    static var historyClearScope: String {
        localized("historyClearScope", zh: "删除全部已结束会话及其聊天和工具记录，包括当前搜索以外的记录。未结束会话会保留。此操作无法撤销。",
                  ko: "현재 검색 범위 밖의 기록을 포함해 종료된 모든 세션, 대화 및 도구 기록을 삭제합니다. 진행 중인 세션은 유지됩니다. 되돌릴 수 없습니다.",
                  ja: "検索範囲外も含め、終了した全セッションと会話・ツール履歴を削除します。未終了のセッションは保持します。取り消せません。",
                  fr: "Supprime toutes les sessions terminées et leurs conversations et outils, même hors de la recherche. Les sessions en cours sont conservées. Cette action est irréversible.",
                  en: "Deletes all ended sessions and their chats and tool records, including records outside this search. Unfinished sessions are kept. This cannot be undone.")
    }

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

    static var viewFullPlan: String {
        localized("viewFullPlan",
            zh: "查看完整计划", ko: "전체 계획 보기", ja: "計画の全文を表示", fr: "Voir le plan complet",
            en: "View full plan")
    }

    static var viewPermissionDetails: String {
        localized("viewPermissionDetails",
            zh: "查看完整请求", ko: "전체 요청 보기", ja: "リクエスト全体を表示", fr: "Voir la demande complète",
            en: "View full request")
    }

    static var interactionSending: String {
        localized("interactionSending",
            zh: "正在发送…", ko: "전송 중…", ja: "送信中…", fr: "Envoi en cours…",
            en: "Sending…")
    }

    static var interactionSent: String {
        localized("interactionSent",
            zh: "已发送，等待 Agent 更新", ko: "전송됨 · 에이전트 업데이트 대기 중", ja: "送信済み · エージェントの更新を待機中", fr: "Envoyé · en attente de l’agent",
            en: "Sent · waiting for the agent to update")
    }

    static var interactionFailed: String {
        localized("interactionFailed",
            zh: "发送失败，请前往 Agent 重新发起", ko: "전송 실패. 에이전트에서 요청을 다시 시작하세요.", ja: "送信できませんでした。エージェントでリクエストをやり直してください。", fr: "Échec de l’envoi. Relancez la demande dans l’agent.",
            en: "Sending failed. Start a new request in the agent.")
    }

    static var interactionOpenAgent: String {
        localized("interactionOpenAgent",
            zh: "前往 Agent 处理", ko: "에이전트에서 처리", ja: "エージェントで操作", fr: "Ouvrir dans l’agent",
            en: "Continue in agent")
    }

    static var questionUnavailable: String {
        localized("questionUnavailable",
            zh: "问题或选项不完整，请前往 Agent 处理", ko: "질문 또는 선택지가 불완전합니다. 에이전트에서 처리하세요.", ja: "質問または選択肢が不完全です。エージェントで操作してください。", fr: "Question ou choix incomplets. Continuez dans l’agent.",
            en: "The question or choices are incomplete. Continue in the agent.")
    }

    static var customAnswer: String {
        localized("customAnswer", zh: "输入其他回答", ko: "직접 답변 입력", ja: "回答を入力", fr: "Saisir une réponse", en: "Type a custom answer")
    }

    static var sendAnswer: String {
        localized("sendAnswer", zh: "发送", ko: "보내기", ja: "送信", fr: "Envoyer", en: "Send")
    }

    static var permissionDiffAvailable: String {
        localized("permissionDiffAvailable",
            zh: "包含文件改动，展开查看完整 diff", ko: "파일 변경 사항이 있습니다. 펼쳐서 전체 diff를 확인하세요.", ja: "ファイル変更があります。展開して差分全体を確認してください。", fr: "Modifications incluses. Développez pour voir le diff complet.",
            en: "Includes file changes. Expand to read the full diff.")
    }

    static var permissionRawInput: String {
        localized("permissionRawInput",
            zh: "完整工具参数", ko: "전체 도구 매개변수", ja: "完全なツールパラメーター", fr: "Paramètres complets de l’outil",
            en: "Full tool parameters")
    }

    static var quotaUnknown: String {
        localized("quotaUnknown", zh: "额度未知", ko: "한도 알 수 없음", ja: "上限不明", fr: "Quota inconnu", en: "Quota unknown")
    }

    static func quotaTokensUsed(_ tokens: String) -> String {
        localized("quotaTokensUsed", zh: "本地已用 \(tokens) tokens", ko: "로컬에서 \(tokens) 토큰 사용", ja: "ローカル使用済み \(tokens) トークン", fr: "\(tokens) tokens utilisés localement", en: "\(tokens) tokens used locally")
    }

    static func quotaTokensRemaining(_ tokens: String) -> String {
        localized("quotaTokensRemaining", zh: "剩余 \(tokens) tokens", ko: "\(tokens) 토큰 남음", ja: "残り \(tokens) トークン", fr: "\(tokens) tokens restants", en: "\(tokens) tokens left")
    }

    static var quotaAPIAvailable: String {
        localized("quotaAPIAvailable", zh: "API 可访问", ko: "API 연결 가능", ja: "API 接続可能", fr: "API accessible", en: "API reachable")
    }

    static var quotaAPIUnavailable: String {
        localized("quotaAPIUnavailable", zh: "API 不可访问", ko: "API 연결 불가", ja: "API 接続不可", fr: "API inaccessible", en: "API unreachable")
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

    static var idle: String {
        localized("idle",
            zh: "空闲", ko: "대기", ja: "待機中", fr: "Inactif",
            en: "Idle")
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

    static var total: String {
        localized("total",
            zh: "总计", ko: "총", ja: "合計", fr: "total",
            en: "total")
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

    static var islandWidth: String {
        localized("islandWidth",
            zh: "岛宽度", ko: "섬 너비", ja: "アイランド幅", fr: "Largeur de l'île",
            en: "Island width")
    }

    static var islandHeight: String {
        localized("islandHeight",
            zh: "岛高度", ko: "섬 높이", ja: "アイランド高さ", fr: "Hauteur de l'île",
            en: "Island height")
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

    static var recap: String {
        localized("recap",
            zh: "回顾", ko: "요약", ja: "サマリー", fr: "Résumé",
            en: "Recap")
    }

    static var showMore: String {
        localized("showMore",
            zh: "展开更多", ko: "더 보기", ja: "もっと見る", fr: "Voir plus",
            en: "Show more")
    }

    static var showLess: String {
        localized("showLess",
            zh: "收起", ko: "접기", ja: "閉じる", fr: "Voir moins",
            en: "Show less")
    }

    // MARK: - Subagent

    static var completionUnconfirmed: String {
        localized("completionUnconfirmed",
            zh: "完成未确认", ko: "완료 확인 안 됨", ja: "完了未確認", fr: "Fin non confirmée",
            en: "Completion unconfirmed")
    }

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

    // MARK: - Appearance / Theme

    static var appearanceDark: String {
        localized("appearanceDark",
            zh: "深色", ko: "다크", ja: "ダーク", fr: "Sombre",
            en: "Dark")
    }

    static var appearanceLight: String {
        localized("appearanceLight",
            zh: "浅色", ko: "라이트", ja: "ライト", fr: "Clair",
            en: "Light")
    }

    static var appearanceSystem: String {
        localized("appearanceSystem",
            zh: "跟随系统", ko: "시스템", ja: "システム", fr: "Système",
            en: "System")
    }

    static var appearanceSection: String {
        localized("appearanceSection",
            zh: "外观", ko: "외관", ja: "外観", fr: "Apparence",
            en: "Appearance")
    }

    static var themeShortcut: String {
        localized("themeShortcut",
            zh: "切换主题", ko: "테마 전환", ja: "テーマ切替", fr: "Changer de thème",
            en: "Toggle theme")
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

    static var sectionInteraction: String {
        localized("sectionInteraction",
            zh: "交互", ko: "상호작용", ja: "操作", fr: "Interaction",
            en: "Interaction")
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

    // MARK: - History

    static var sectionHistory: String {
        localized("sectionHistory",
            zh: "历史", ko: "기록", ja: "履歴", fr: "Historique",
            en: "History")
    }

    static var historyRetentionDays: String {
        localized("historyRetentionDays",
            zh: "历史保留天数", ko: "기록 보존 기간", ja: "履歴保持日数", fr: "Durée de rétention",
            en: "Retention days")
    }

    static var clearHistory: String {
        localized("clearHistory",
            zh: "清除历史", ko: "기록 삭제", ja: "履歴をクリア", fr: "Effacer l'historique",
            en: "Clear History")
    }

    static var noHistory: String {
        localized("noHistory",
            zh: "暂无历史记录", ko: "기록 없음", ja: "履歴なし", fr: "Aucun historique",
            en: "No history yet")
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

    static var paneDisplay: String {
        localized("paneDisplay",
            zh: "显示", ko: "표시", ja: "表示", fr: "Affichage",
            en: "Display")
    }

    static var paneIntegration: String {
        localized("paneIntegration",
            zh: "联动", ko: "연동", ja: "連携", fr: "Intégration",
            en: "Integration")
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

    static var hoverToExpandPanel: String {
        localized("hoverToExpandPanel",
            zh: "悬停展开面板", ko: "호버 확장 패널", ja: "ホバーでパネルを展開", fr: "Développer le panneau au survol",
            en: "Hover to expand panel")
    }

    static var scrollDownToExpand: String {
        localized("scrollDownToExpand",
            zh: "双指下滑展开", ko: "두 손가락 아래로 스크롤하여 펼치기", ja: "二本指の下スクロールで展開", fr: "Déplier avec un défilement vers le bas à deux doigts",
            en: "Scroll down to expand")
    }

    static var animationIntensity: String {
        localized("animationIntensity",
            zh: "动画强度", ko: "애니메이션 강도", ja: "アニメーション強度", fr: "Intensité de l'animation",
            en: "Animation intensity")
    }

    static var jellyIntensity: String {
        localized("jellyIntensity",
            zh: "果冻动画强度", ko: "젤리 애니메이션 강도", ja: "ゼリーアニメーション強度", fr: "Intensité de l'animation gélatineuse",
            en: "Jelly animation intensity")
    }

    static var jellyWeak: String {
        localized("jellyWeak",
            zh: "弱", ko: "약함", ja: "弱", fr: "Faible",
            en: "Weak")
    }

    static var jellyMedium: String {
        localized("jellyMedium",
            zh: "中", ko: "중간", ja: "中", fr: "Moyenne",
            en: "Medium")
    }

    static var jellyStrong: String {
        localized("jellyStrong",
            zh: "强", ko: "강함", ja: "強", fr: "Forte",
            en: "Strong")
    }

    static var sectionCollapsedModules: String {
        localized("sectionCollapsedModules",
            zh: "收起态模块", ko: "접힘 상태 모듈", ja: "折りたたみ時のモジュール", fr: "Modules repliés",
            en: "Collapsed modules")
    }

    static var sectionActivityTicker: String {
        localized("sectionActivityTicker",
            zh: "活动跑马灯", ko: "활동 티커", ja: "アクティビティティッカー", fr: "Ticker d'activité",
            en: "Activity ticker")
    }

    static var showCollapsedAgentIcon: String {
        localized("showCollapsedAgentIcon",
            zh: "显示 Agent 图标", ko: "에이전트 아이콘 표시", ja: "エージェントアイコンを表示", fr: "Afficher l'icône de l'agent",
            en: "Show agent icons")
    }

    static var collapsedRecentTaskLimit: String {
        localized("collapsedRecentTaskLimit",
            zh: "最近任务数量", ko: "최근 작업 수", ja: "最近のタスク数", fr: "Nombre de tâches récentes",
            en: "Recent task count")
    }

    static var showCollapsedSessionCount: String {
        localized("showCollapsedSessionCount",
            zh: "显示会话数量", ko: "세션 수 표시", ja: "セッション数を表示", fr: "Afficher le nombre de sessions",
            en: "Show session count")
    }

    static var showCollapsedQuota: String {
        localized("showCollapsedQuota",
            zh: "显示额度摘要", ko: "사용량 요약 표시", ja: "クォータ概要を表示", fr: "Afficher le résumé des quotas",
            en: "Show quota summary")
    }

    static var showActivityTicker: String {
        localized("showActivityTicker",
            zh: "显示活动跑马灯", ko: "활동 티커 표시", ja: "アクティビティティッカーを表示", fr: "Afficher le ticker d'activité",
            en: "Show activity ticker")
    }

    static var activityTickerSpeed: String {
        localized("activityTickerSpeed",
            zh: "跑马灯速度", ko: "티커 속도", ja: "ティッカー速度", fr: "Vitesse du ticker",
            en: "Ticker speed")
    }

    static var tickerContentMode: String {
        localized("tickerContentMode",
            zh: "跑马灯内容", ko: "티커 내용", ja: "ティッカー内容", fr: "Contenu du ticker",
            en: "Ticker content")
    }

    static var tickerContentActivity: String {
        localized("tickerContentActivity",
            zh: "活动状态", ko: "활동 상태", ja: "アクティビティ", fr: "Activité",
            en: "Activity")
    }

    static var tickerContentProject: String {
        localized("tickerContentProject",
            zh: "项目名", ko: "프로젝트", ja: "プロジェクト", fr: "Projet",
            en: "Project")
    }

    static var tickerContentAutomatic: String {
        localized("tickerContentAutomatic",
            zh: "自动轮换", ko: "자동 전환", ja: "自動切替", fr: "Rotation auto",
            en: "Automatic")
    }

    static var permanent: String {
        localized("permanent",
            zh: "永久", ko: "영구", ja: "永続", fr: "Permanent",
            en: "Permanent")
    }

    static var noRemoteServers: String {
        localized("noRemoteServers",
            zh: "未配置远程服务器", ko: "원격 서버 구성 안 됨", ja: "リモートサーバー未設定",
            fr: "Aucun serveur distant configuré",
            en: "No remote servers configured")
    }

    static var enableSwipeSwitch: String {
        localized("enableSwipeSwitch",
            zh: "启用双指横滑切换", ko: "두 손가락 좌우 스와이프 전환", ja: "二本指の横スワイプ切替",
            fr: "Activer le basculement par glissement à deux doigts",
            en: "Enable two-finger swipe switching")
    }

    static var switchSensitivity: String {
        localized("switchSensitivity",
            zh: "切换灵敏度", ko: "전환 민감도", ja: "切替感度", fr: "Sensibilité du basculement",
            en: "Switch sensitivity")
    }

    static var startupDisplay: String {
        localized("startupDisplay",
            zh: "启动时显示", ko: "시작 시 표시", ja: "起動時に表示", fr: "Afficher au lancement",
            en: "Show on launch")
    }

    static var startupLastUsed: String {
        localized("startupLastUsed",
            zh: "上次使用", ko: "마지막 사용", ja: "前回使用", fr: "Dernière utilisée",
            en: "Last used")
    }

    static var sensitivityLow: String {
        localized("sensitivityLow",
            zh: "低", ko: "낮음", ja: "低", fr: "Faible",
            en: "Low")
    }

    static var sensitivityMedium: String {
        localized("sensitivityMedium",
            zh: "中", ko: "중간", ja: "中", fr: "Moyenne",
            en: "Medium")
    }

    static var sensitivityHigh: String {
        localized("sensitivityHigh",
            zh: "高", ko: "높음", ja: "高", fr: "Élevée",
            en: "High")
    }

    // MARK: - 触觉反馈

    static var sectionHaptics: String {
        localized("sectionHaptics",
            zh: "触觉反馈", ko: "햅틱 피드백", ja: "触覚フィードバック", fr: "Retour haptique",
            en: "Haptic feedback")
    }

    static var hapticIntensity: String {
        localized("hapticIntensity",
            zh: "反馈强度", ko: "피드백 강도", ja: "フィードバック強度", fr: "Intensité du retour",
            en: "Feedback level")
    }

    static var hapticIntensityDesc: String {
        localized("hapticIntensityDesc",
            zh: "控制哪些操作会触发触控板振动。档位越高，纳入反馈的事件越多。",
            ko: "어떤 동작이 촉각 피드백을 트리거할지 제어합니다. 단계가 높을수록 더 많은 이벤트가 포함됩니다.",
            ja: "どの操作で触覚フィードバックを返すかを制御します。段階が高いほど対象イベントが増えます。",
            fr: "Contrôle les actions déclenchant un retour haptique. Plus le niveau est élevé, plus d'événements sont inclus.",
            en: "Controls which actions trigger trackpad feedback. Higher levels include more events.")
    }

    static var hapticIntensityOff: String {
        localized("hapticIntensityOff",
            zh: "关闭", ko: "끔", ja: "オフ", fr: "Désactivé",
            en: "Off")
    }

    static var hapticIntensityMinimal: String {
        localized("hapticIntensityMinimal",
            zh: "极简", ko: "최소", ja: "最小", fr: "Minimal",
            en: "Minimal")
    }

    static var hapticIntensityStandard: String {
        localized("hapticIntensityStandard",
            zh: "标准", ko: "표준", ja: "標準", fr: "Standard",
            en: "Standard")
    }

    static var hapticIntensityFull: String {
        localized("hapticIntensityFull",
            zh: "完整", ko: "전체", ja: "フル", fr: "Complet",
            en: "Full")
    }

    static var hapticIntensityOffDesc: String {
        localized("hapticIntensityOffDesc",
            zh: "不产生任何触觉反馈。",
            ko: "촉각 피드백을 전혀 발생시키지 않습니다.",
            ja: "触覚フィードバックを一切発生させません。",
            fr: "Aucun retour haptique.",
            en: "No haptic feedback at all.")
    }

    static var hapticIntensityMinimalDesc: String {
        localized("hapticIntensityMinimalDesc",
            zh: "仅权限审批与失败时反馈，干扰最小。",
            ko: "권한 승인과 실패 시에만 피드백합니다.",
            ja: "権限承認と失敗時のみフィードバックします。",
            fr: "Retour uniquement pour les approbations et échecs.",
            en: "Feedback only for approvals and failures.")
    }

    static var hapticIntensityStandardDesc: String {
        localized("hapticIntensityStandardDesc",
            zh: "在极简基础上加入等待输入与面板展开/收起。",
            ko: "최소에 더해 입력 대기와 패널 열기/닫기를 포함합니다.",
            ja: "最小に加え、入力待ちとパネルの開閉を含みます。",
            fr: "Inclut aussi les saisies en attente et l'ouverture/fermeture du panneau.",
            en: "Adds input prompts and panel expand/collapse.")
    }

    static var hapticIntensityFullDesc: String {
        localized("hapticIntensityFullDesc",
            zh: "所有事件均反馈，包含会话切换与工具完成。",
            ko: "모든 이벤트에 피드백하며 세션 전환과 도구 완료를 포함합니다.",
            ja: "全イベントにフィードバックし、セッション切替とツール完了を含みます。",
            fr: "Tous les événements, y compris le changement de session et la fin d'outil.",
            en: "All events, including session switch and tool completion.")
    }

    static var hapticEventPermission: String {
        localized("hapticEventPermission", zh: "权限审批", ko: "권한 승인", ja: "権限承認", fr: "Approbation", en: "Approval request")
    }

    static var hapticEventInput: String {
        localized("hapticEventInput", zh: "等待输入", ko: "입력 대기", ja: "入力待ち", fr: "Saisie requise", en: "Input required")
    }

    static var hapticEventExpand: String {
        localized("hapticEventExpand", zh: "面板展开", ko: "패널 열기", ja: "パネル展開", fr: "Ouverture du panneau", en: "Panel expand")
    }

    static var hapticEventCollapse: String {
        localized("hapticEventCollapse", zh: "面板收起", ko: "패널 닫기", ja: "パネル収納", fr: "Fermeture du panneau", en: "Panel collapse")
    }

    static var hapticEventSwitch: String {
        localized("hapticEventSwitch", zh: "会话切换", ko: "세션 전환", ja: "セッション切替", fr: "Changement de session", en: "Session switch")
    }

    static var hapticEventToolDone: String {
        localized("hapticEventToolDone", zh: "工具完成", ko: "도구 완료", ja: "ツール完了", fr: "Fin d'outil", en: "Tool completion")
    }

    static var hapticEventFailure: String {
        localized("hapticEventFailure", zh: "失败 / 拒绝", ko: "실패/거부", ja: "失敗・拒否", fr: "Échec / refus", en: "Failure / denial")
    }

    // MARK: - 图标与卡片动效

    static var sectionMicroMotion: String {
        localized("sectionMicroMotion",
            zh: "微动效", ko: "마이크로 모션", ja: "マイクロモーション", fr: "Micro-animations",
            en: "Micro-animations")
    }

    static var symbolEffectsEnabled: String {
        localized("symbolEffectsEnabled",
            zh: "图标动效", ko: "아이콘 효과", ja: "アイコンエフェクト", fr: "Effets d'icône",
            en: "Icon effects")
    }

    static var symbolEffectsEnabledDesc: String {
        localized("symbolEffectsEnabledDesc",
            zh: "状态图标在等待输入时脉动、运行中分层变色、工具完成时弹跳。",
            ko: "대기 중 아이콘은 맥동하고, 실행 중에는 레이어별로 색이 변하며, 완료 시 튕깁니다.",
            ja: "待機中のアイコンは脈動し、実行中は層ごとに色が変わり、完了時は弾みます。",
            fr: "Les icônes pulsent en attente, changent de couleur en cours et rebondissent à la fin.",
            en: "Icons pulse when waiting, shift color while running, and bounce on completion.")
    }

    static var cascadeEntranceEnabled: String {
        localized("cascadeEntranceEnabled",
            zh: "列表入场级联", ko: "목록 순차 등장", ja: "リストの順次表示", fr: "Apparition en cascade",
            en: "Cascading list entrance")
    }

    static var cascadeEntranceEnabledDesc: String {
        localized("cascadeEntranceEnabledDesc",
            zh: "打开面板时，会话卡片依次上浮落定，而非整体闪现。",
            ko: "패널을 열 때 카드가 하나씩 떠오르며 나타납니다.",
            ja: "パネルを開くとカードが順に浮かび上がります。",
            fr: "À l'ouverture, les cartes apparaissent une à une.",
            en: "Cards rise into place one by one when the panel opens.")
    }

    static var proximityLiftEnabled: String {
        localized("proximityLiftEnabled",
            zh: "指针距离感应", ko: "포인터 근접 반응", ja: "ポインタ近接反応", fr: "Réaction de proximité",
            en: "Pointer proximity lift")
    }

    static var proximityLiftEnabledDesc: String {
        localized("proximityLiftEnabledDesc",
            zh: "指针靠近时，附近卡片连续隆起（类似 macOS Dock）。可能增加少量 CPU 占用。",
            ko: "포인터가 가까워지면 주변 카드가 연속적으로 솟아오릅니다(Dock과 유사). CPU 사용량이 약간 증가할 수 있습니다.",
            ja: "ポインタが近づくと周辺カードが連続的に浮き上がります（Dock と同様）。CPU 使用量がわずかに増える場合があります。",
            fr: "Les cartes proches se soulèvent en continu (comme le Dock). Peut augmenter légèrement l'usage CPU.",
            en: "Nearby cards lift continuously as the pointer approaches (like the Dock). May slightly increase CPU usage.")
    }

    static var counterpartInstalled: String {
        localized("counterpartInstalled",
            zh: "应用安装状态", ko: "앱 설치 상태", ja: "アプリのインストール状態", fr: "Installation de l'app",
            en: "App installation")
    }

    static var counterpartProtocol: String {
        localized("counterpartProtocol",
            zh: "协议状态", ko: "프로토콜 상태", ja: "プロトコル状態", fr: "État du protocole",
            en: "Protocol status")
    }

    static var testSwitch: String {
        localized("testSwitch",
            zh: "立即切换测试", ko: "즉시 전환 테스트", ja: "今すぐ切替テスト", fr: "Tester le basculement",
            en: "Switch test")
    }

    static var testSwitchButton: String {
        localized("testSwitchButton",
            zh: "切换到对方", ko: "상대 앱으로 전환", ja: "相手へ切り替え", fr: "Basculer maintenant",
            en: "Switch now")
    }

    static var statusInstalled: String {
        localized("statusInstalled",
            zh: "已安装", ko: "설치됨", ja: "インストール済み", fr: "Installée",
            en: "Installed")
    }

    static var statusMissing: String {
        localized("statusMissing",
            zh: "未安装", ko: "미설치", ja: "未インストール", fr: "Absente",
            en: "Missing")
    }

    static var statusRunning: String {
        localized("statusRunning",
            zh: "运行中", ko: "실행 중", ja: "実行中", fr: "En cours",
            en: "Running")
    }

    static var statusStopped: String {
        localized("statusStopped",
            zh: "未运行", ko: "중지됨", ja: "停止中", fr: "Arrêtée",
            en: "Stopped")
    }

    static var statusReady: String {
        localized("statusReady",
            zh: "协议正常", ko: "준비됨", ja: "準備完了", fr: "Prêt",
            en: "Ready")
    }

    static var statusMisconfigured: String {
        localized("statusMisconfigured",
            zh: "协议异常", ko: "설정 오류", ja: "設定異常", fr: "Mal configuré",
            en: "Misconfigured")
    }

    static var hookActive: String {
        localized("hookActive",
            zh: "已配置", ko: "설정됨", ja: "設定済み", fr: "Configuré",
            en: "Configured")
    }

    static var hookOff: String {
        localized("hookOff",
            zh: "未配置", ko: "미설정", ja: "未設定", fr: "Non configuré",
            en: "Not configured")
    }

    static var hookViaExtension: String {
        localized("hookViaExtension", zh: "通过扩展接入", ko: "확장으로 연결", ja: "拡張機能で接続", fr: "Via une extension", en: "Via extension")
    }

    static var hookViaObserver: String {
        localized("hookViaObserver", zh: "服务状态观察", ko: "서버 상태 관찰", ja: "サーバー状態監視", fr: "Observation du serveur", en: "Server observation")
    }

    static var hookViaCody: String {
        localized("hookViaCody", zh: "Cody Agent 观察", ko: "Cody Agent 관찰", ja: "Cody Agent 監視", fr: "Observation Cody Agent", en: "Cody Agent observation")
    }

    static var hookViaAmazonQ: String {
        localized("hookViaAmazonQ", zh: "旧 Q 进程观察", ko: "이전 Q 프로세스 관찰", ja: "旧 Q プロセス監視", fr: "Observation Q historique", en: "Legacy Q observation")
    }

    static var hookViaWorkBuddy: String {
        localized("hookViaWorkBuddy", zh: "WorkBuddy 插件观察", ko: "WorkBuddy 플러그인 관찰", ja: "WorkBuddy プラグイン監視", fr: "Observation WorkBuddy", en: "WorkBuddy plugin observation")
    }

    static var hookWorkBuddyHint: String {
        localized("hookWorkBuddyHint", zh: "需手动导出并在 WorkBuddy 中安装观察插件。此开关仅控制接收；不会写入配置或回传审批决定。真实客户端验收尚未完成。",
                  ko: "WorkBuddy 관찰 플러그인을 직접 설치해야 합니다. 이 스위치는 수신만 제어합니다.",
                  ja: "監視プラグインを WorkBuddy に手動でインストールしてください。このスイッチは受信のみを制御します。",
                  fr: "Installez manuellement le plugin WorkBuddy. Ce réglage contrôle uniquement la réception.",
                  en: "Manually export and install the WorkBuddy observer plugin. This toggle controls reception only; it does not write configuration or make permission decisions. Native client acceptance is pending.")
    }

    static var hookAmazonQHint: String {
        localized("hookAmazonQHint", zh: "仅接收显式包装的 qchat 1.19.7；需审查选定 agent 的 hooks 配置。不会自动安装，不覆盖 Q IDE 或 Kiro，审批仍在原客户端。",
                  ko: "명시적으로 래핑한 qchat 1.19.7만 지원합니다. 자동 설치하지 않습니다.",
                  ja: "明示的にラップした qchat 1.19.7 のみ対象です。自動設定はしません。",
                  fr: "Uniquement qchat 1.19.7 explicitement enveloppé. Aucune installation automatique.",
                  en: "Receives only explicitly wrapped qchat 1.19.7 with reviewed agent hooks. No automatic installation; Q IDE and Kiro are not covered. Approve in the original client.")
    }

    static var hookCodyHint: String {
        localized("hookCodyHint", zh: "仅接收显式包装的 Cody jsonrpc-stdio 进程；不自动修改 IDE 或认证。普通 Cody CLI/IDE 会话不在此通道范围。",
                  ko: "명시적으로 래핑한 Cody jsonrpc-stdio 프로세스만 관찰합니다.",
                  ja: "明示的にラップした Cody jsonrpc-stdio プロセスのみ監視します。",
                  fr: "Observe uniquement un processus Cody jsonrpc-stdio explicitement enveloppé.",
                  en: "Receives only an explicitly wrapped Cody jsonrpc-stdio process. Does not change IDE or authentication settings. Ordinary CLI/IDE sessions are outside this channel.")
    }

    static var hookObserverHint: String {
        localized("hookObserverHint", zh: "仅接收显式指定的 cn serve 状态；需手动启动限时观察命令。开关不启动服务，不配置 hooks，审批在 Continue 完成。",
                  ko: "명시적으로 지정한 cn serve만 관찰합니다. 승인은 Continue에서 처리합니다.",
                  ja: "明示的に指定した cn serve のみ監視します。承認は Continue で行います。",
                  fr: "Observe uniquement le serveur cn serve choisi explicitement. Approbations dans Continue.",
                  en: "Receives only an explicitly selected cn serve via a manually started, time-limited observer. Does not start a server or configure hooks. Approve in Continue.")
    }

    static var hookViaACP: String {
        localized("hookViaACP", zh: "ACP 外部接入", ko: "ACP 연결", ja: "ACP 連携", fr: "Agent ACP", en: "External ACP")
    }

    static var hookACPHint: String {
        localized("hookACPHint", zh: "需要显式包装选定的外部 ACP Agent；内置 AI 不在此通道范围。此开关控制接收，审批仍在原编辑器完成。",
                  ko: "선택한 외부 ACP Agent를 연결해야 합니다. 승인은 원래 편집기에서 처리합니다.",
                  ja: "選択した外部 ACP Agent の設定が必要です。承認は元のエディターで行います。",
                  fr: "Nécessite un agent ACP externe configuré. Les autorisations restent dans l’éditeur.",
                  en: "Requires explicit wrapping of an external ACP agent. Built-in AI is separate; permissions remain in the editor. This switch controls reception.")
    }

    static var hookPending: String {
        localized("hookPending", zh: "待适配", ko: "통합 대기", ja: "対応準備中", fr: "Intégration en cours", en: "Integration pending")
    }

    static var hookViaModelClient: String {
        localized("hookViaModelClient", zh: "通过客户端接入", ko: "클라이언트 연결", ja: "クライアント経由", fr: "Via le client", en: "Via client")
    }

    static var hookViaKiro: String {
        localized("hookViaKiro", zh: "Kiro V3 手动接入", ko: "Kiro V3 수동 연결", ja: "Kiro V3 手動連携", fr: "Kiro V3 manuel", en: "Manual Kiro V3")
    }

    static var hookKiroHint: String {
        localized("hookKiroHint", zh: "可导出 Kiro CLI 2.31.0 V3 的独立观察配置。请按指南检查并安装；不会自动改写配置，不接管审批，不覆盖 IDE。",
                  ko: "Kiro CLI 2.31.0 V3 관찰 설정을 내보낼 수 있습니다. 자동 설치 또는 승인은 하지 않습니다.",
                  ja: "Kiro CLI 2.31.0 V3 の監視設定を書き出せます。自動設定や承認は行いません。",
                  fr: "Export de configuration pour Kiro CLI 2.31.0 V3. Installation manuelle, sans contrôle des autorisations.",
                  en: "Export an observation configuration for Kiro CLI 2.31.0 V3. Review and install using the guide; no automatic configuration, approval control or IDE coverage.")
    }

    static var hookModelClientHint: String {
        localized("hookModelClientHint", zh: "在 Claude Code、OpenCode、Cline 或 Pi 中选择 GLM，并启用对应客户端的 X Island 接入。会话保留客户端名称，显示其上报的模型；可用 GLM 筛选。",
                  ko: "Claude Code, OpenCode, Cline 또는 Pi에서 GLM을 선택하고 해당 클라이언트를 연결하세요.",
                  ja: "Claude Code、OpenCode、Cline、Pi で GLM を選び、対応するクライアントを連携してください。",
                  fr: "Choisissez GLM dans Claude Code, OpenCode, Cline ou Pi et activez son intégration.",
                  en: "Select GLM in Claude Code, OpenCode, Cline or Pi and enable that client's integration. Sessions keep their client identity, show the reported model and can be filtered by GLM.")
    }

    static var setupGuide: String {
        localized("setupGuide", zh: "接入说明", ko: "설정 안내", ja: "設定ガイド", fr: "Guide", en: "Setup guide")
    }

    static var hookPendingHint: String {
        localized("hookPendingHint", zh: "原生接入仍待实现或验证，已停用旧通用模板；不会改写现有配置。",
                  ko: "기본 통합 검증 대기 중입니다. 기존 설정은 변경하지 않습니다.",
                  ja: "ネイティブ連携は検証中です。既存設定は変更しません。",
                  fr: "L’intégration native reste à valider. La configuration existante est conservée.",
                  en: "Native integration remains pending. Legacy generic templates are disabled and existing configuration is preserved.")
    }

    static var hookExtensionHint: String {
        localized("hookExtensionHint", zh: "需要在对应编辑器安装 X Island Bridge 扩展并启用已支持的来源。此开关控制本应用是否接收该来源。",
                  ko: "편집기에 X Island Bridge 확장이 필요합니다. 이 스위치는 수신을 제어합니다.",
                  ja: "エディターに X Island Bridge 拡張機能が必要です。このスイッチは受信を制御します。",
                  fr: "Nécessite X Island Bridge dans l’éditeur. Ce bouton contrôle la réception.",
                  en: "Requires X Island Bridge in the editor and an enabled supported source. This switch controls reception in this app.")
    }

    static var hookConfigurationHint: String {
        localized("hookConfigurationHint",
            zh: "此处仅检查配置。部分软件还需在原软件中启用或信任后才会生效。",
            ko: "설정 여부만 확인합니다. 일부 앱에서는 활성화하거나 신뢰해야 작동합니다.",
            ja: "設定の有無を確認します。一部のアプリでは有効化や信頼の承認も必要です。",
            fr: "Vérifie la configuration. Certaines applications exigent aussi une activation ou une autorisation de confiance.",
            en: "Checks configuration only. Some apps also require enabling or trusting the hooks in that app.")
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
            zh: "任务完成且鼠标离开面板和岛后，等待多久收起", ko: "작업 완료 후 포인터가 패널과 아일랜드를 벗어나면 시작하는 대기 시간",
            ja: "タスク完了後、ポインターがパネルとアイランドから離れてからの待ち時間",
            fr: "Délai après la fin de la tâche et la sortie du pointeur du panneau et de l’îlot",
            en: "Delay after task completion and the pointer leaves both the panel and island")
    }

    static var expandedInactivityAutoHide: String {
        localized("expandedInactivityAutoHide",
            zh: "移出面板后收起",
            ko: "포인터가 패널을 벗어나면 접기",
            ja: "ポインターがパネルから離れたら折りたたむ",
            fr: "Réduire après sortie du panneau",
            en: "Collapse after leaving the panel")
    }

    static var expandedInactivityAutoHideDesc: String {
        localized("expandedInactivityAutoHideDesc",
            zh: "鼠标在面板或岛内时不收起；离开后开始计时，重新进入会取消。选「永不」关闭此项；多项同时适用时采用最短延时。",
            ko: "포인터가 패널과 아일랜드를 벗어나면 대기하며, 다시 들어오면 취소합니다. 「안 함」은 이 규칙을 끕니다. 적용 가능한 가장 짧은 지연을 사용합니다.",
            ja: "パネルとアイランドから離れると計時を開始し、戻ると解除します。「なし」でこの規則を無効化。適用可能な最短の待ち時間を使用します。",
            fr: "Le délai commence après la sortie du panneau et de l’îlot ; le retour l’annule. « Jamais » désactive cette règle. Le délai applicable le plus court est utilisé.",
            en: "Wait after the pointer leaves both the panel and island. Re-entry cancels the countdown. “Never” disables this rule; the shortest applicable delay wins.")
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
            zh: "悬停展开或无会话时，从指针离开面板和岛时开始计时；重新进入后取消",
            ko: "호버로 펼쳤거나 세션이 없을 때, 패널과 아일랜드를 벗어나면 대기하며 다시 들어오면 취소합니다.",
            ja: "ホバー展開または会話がない場合、パネルとアイランドから離れてから計時し、戻ると解除します。",
            fr: "Après ouverture au survol ou sans session, comptez depuis la sortie du panneau et de l’îlot ; le retour annule le délai.",
            en: "After hover-expand or with no sessions, count from leaving both the panel and island; re-entry cancels the countdown.")
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

    static var launchAtLoginDesc: String {
        localized("launchAtLoginDesc",
            zh: "登录 macOS 时自动启动 X Island", ko: "macOS 로그인 시 자동 시작",
            ja: "macOS ログイン時に自動起動",
            fr: "Lancer automatiquement au démarrage de macOS",
            en: "Start X Island automatically when you log in to macOS")
    }

    static var showOnAllSpacesDesc: String {
        localized("showOnAllSpacesDesc",
            zh: "在所有桌面空间（Mission Control）中显示面板", ko: "모든 데스크톱 공간에 패널 표시",
            ja: "すべてのスペース（ミッションコントロール）でパネルを表示",
            fr: "Afficher le panneau sur tous les espaces Mission Control",
            en: "Show the panel on all desktop spaces (Mission Control)")
    }

    static var hideInFullscreenDesc: String {
        localized("hideInFullscreenDesc",
            zh: "全屏应用运行时隐藏面板", ko: "전체 화면 앱 실행 중 패널 숨기기",
            ja: "フルスクリーンアプリ実行中にパネルを非表示",
            fr: "Masquer le panneau en mode plein écran",
            en: "Hide the panel when a full-screen app is running")
    }

    static var autoHideIdleDesc: String {
        localized("autoHideIdleDesc",
            zh: "没有活跃会话时自动隐藏面板，有新会话时恢复显示", ko: "활성 세션이 없을 때 패널 자동 숨기기",
            ja: "活跃セッションがないときパネルを自動非表示にし、新しいセッションで再表示",
            fr: "Masquer automatiquement le panneau quand il n'y a aucune session active",
            en: "Auto-hide the panel when there are no active sessions; it reappears when a new session starts")
    }

    static var panelWidthDesc: String {
        localized("panelWidthDesc",
            zh: "展开面板的宽度（像素），拖动滑块无极调节", ko: "展开된 패널의 너비 (픽셀)",
            ja: "展開パネルの幅（ピクセル）、スライダーで調整",
            fr: "Largeur du panneau déplié (pixels), ajustable avec le curseur",
            en: "Width of the expanded panel in pixels, adjustable with the slider")
    }

    static var islandWidthDesc: String {
        localized("islandWidthDesc",
            zh: "收起状态下灵动岛的宽度（像素），拖动滑块无极调节",
            ko: "접힌 상태의 아일랜드 너비 (픽셀)",
            ja: "折りたたみ時のアイランド幅（ピクセル）、スライダーで調整",
            fr: "Largeur de l'île en mode réduit (pixels), ajustable avec le curseur",
            en: "Width of the island when collapsed in pixels, adjustable with the slider")
    }

    static var islandHeightDesc: String {
        localized("islandHeightDesc",
            zh: "收起状态下灵动岛的高度（像素），拖动滑块无极调节",
            ko: "접힌 상태의 아일랜드 높이 (픽셀)",
            ja: "折りたたみ時のアイランド高さ（ピクセル）、スライダーで調整",
            fr: "Hauteur de l'île en mode réduit (pixels), ajustable avec le curseur",
            en: "Height of the island when collapsed in pixels, adjustable with the slider")
    }

    static var panelMaxHeightDesc: String {
        localized("panelMaxHeightDesc",
            zh: "展开面板的最大高度（像素），内容超出时可滚动", ko: "펼친 패널의 최대 높이(픽셀)",
            ja: "展開パネルの最大高さ（ピクセル）、内容が多い場合はスクロール",
            fr: "Hauteur maximale du panneau déplié (pixels), défilement si le contenu dépasse",
            en: "Maximum height of the expanded panel in pixels; content scrolls when it exceeds this")
    }

    static var compactBadgesDesc: String {
        localized("compactBadgesDesc",
            zh: "在展开视图中使用紧凑的徽章样式，节省空间", ko: "展开된 뷰에서 компак트한 배지 스타일 사용",
            ja: "展開ビューでコンパクトなバッジスタイルを使用し、スペースを節約",
            fr: "Utiliser des badges compacts dans la vue dépliée pour économiser de l'espace",
            en: "Use compact badge style in the expanded view to save space")
    }

    static var showTimestampsDesc: String {
        localized("showTimestampsDesc",
            zh: "在会话卡片上显示时间戳", ko: "세션 카드에 타임스탬프 표시",
            ja: "セッションカードにタイムスタンプを表示",
            fr: "Afficher les horodatages sur les cartes de session",
            en: "Show timestamps on session cards")
    }

    static var reduceMotionDesc: String {
        localized("reduceMotionDesc",
            zh: "减少动画效果，适合对动态敏感的用户", ko: "애니메이션 효과 줄이기",
            ja: "アニメーション効果を減らす",
            fr: "Réduire les animations pour les sensibles au mouvement",
            en: "Reduce animation effects, useful for motion-sensitive users")
    }

    static var hoverToExpandPanelDesc: String {
        localized("hoverToExpandPanelDesc",
            zh: "鼠标悬停在药丸上时自动展开面板，无需点击", ko: "알약에 마우스를 올리면 자동으로 패널 확장",
            ja: "薬丸にマウスを乗せるとパネルが自動展開",
            fr: "Déplier le panneau automatiquement en survolant le comprimé",
            en: "Automatically expand the panel when hovering over the pill, no click needed")
    }

    static var scrollDownToExpandDesc: String {
        localized("scrollDownToExpandDesc",
            zh: "仅在灵动岛收起时响应双指下滑，用来直接展开面板而不影响已展开内容的滚动。",
            ko: "아일랜드가 접힌 상태일 때만 두 손가락 아래 스크롤로 패널을 펼치며, 펼쳐진 패널 내부 스크롤과 충돌하지 않습니다.",
            ja: "島が折りたたまれているときだけ、二本指の下スクロールでパネルを展開します。展開済みパネル内のスクロールとは競合しません。",
            fr: "N'agit que lorsque l'île est repliée : un défilement vers le bas à deux doigts ouvre le panneau sans gêner le défilement horizontal ou interne.",
            en: "Only responds while the island is collapsed, so a two-finger downward scroll expands the panel without conflicting with scrolling inside the expanded view.")
    }

    static var animationIntensityDesc: String {
        localized("animationIntensityDesc",
            zh: "调整展开与收起过渡的动效力度；开启“减少动画”后会自动使用最低档。",
            ko: "펼치기와 접기 전환의 움직임 강도를 조절합니다. 「모션 줄이기」를 켜면 자동으로 가장 낮은 강도를 사용합니다.",
            ja: "展開・折りたたみ時の動きの強さを調整します。「モーションを減らす」を有効にすると自動で最小になります。",
            fr: "Ajuste l'intensité des transitions d'ouverture et de fermeture ; « Réduire les animations » force automatiquement le niveau le plus faible.",
            en: "Adjust how strong the expand and collapse transitions feel. Turning on Reduce motion automatically uses the lowest intensity.")
    }

    static var jellyIntensityDesc: String {
        localized("jellyIntensityDesc",
            zh: "调整鼠标从下方进入灵动岛时的果冻弹跳强度，参数与 XNook 保持一致。",
            ko: "마우스가 아래에서 아일랜드로 들어올 때의 젤리 탄성 강도를 조절하며, XNook과 같은 파라미터를 사용합니다.",
            ja: "下から島に入るときのゼリー風バウンスの強さを調整します。パラメータは XNook と揃えています。",
            fr: "Ajuste l'intensité du rebond gélatineux quand le pointeur entre par le bas ; les paramètres sont alignés sur XNook.",
            en: "Adjust the jelly-style bounce when the pointer enters from below. The tuning matches XNook.")
    }

    static var showCollapsedAgentIconDesc: String {
        localized("showCollapsedAgentIconDesc",
            zh: "收起状态下显示活跃会话的 Agent 图标；关闭后仅保留其他状态模块",
            ko: "접힌 상태에서 활성 세션의 에이전트 아이콘을 표시합니다. 끄면 다른 상태 모듈만 남습니다.",
            ja: "折りたたみ時にアクティブセッションのエージェントアイコンを表示します。オフにすると他の状態モジュールだけ残ります。",
            fr: "Affiche les icônes d'agent quand l'île est repliée ; désactivez pour ne garder que les autres modules d'état.",
            en: "Show active-session agent icons while the island is collapsed; turn this off to keep only the other status modules.")
    }

    static func collapsedRecentTaskLimitDesc(_ count: Int) -> String {
        localized("collapsedRecentTaskLimitDesc",
            zh: "收起时最多显示或轮换 \(count) 个任务图标，待处理请求优先，其余按最近活动排序。展开列表仍显示全部任务。",
            ko: "접힌 상태에서 최대 \(count)개의 작업 아이콘을 표시하거나 순환합니다. 대기 중인 요청을 우선하고 나머지는 최근 활동 순으로 정렬합니다. 펼친 목록에는 모든 작업이 표시됩니다.",
            ja: "折りたたみ時は最大 \(count) 件のタスクアイコンを表示または切り替えます。対応待ちのリクエストを優先し、残りは最近のアクティビティ順に並べます。展開したリストにはすべてのタスクが表示されます。",
            fr: "Affiche ou fait défiler jusqu'à \(count) icônes de tâches dans l'état replié. Les demandes en attente sont prioritaires ; les autres tâches sont triées par activité récente. La liste dépliée affiche toujours toutes les tâches.",
            en: "Show or rotate through up to \(count) task icons while collapsed. Pending requests come first, followed by the most recently active tasks. The expanded list still shows all tasks.")
    }

    static var showCollapsedSessionCountDesc: String {
        localized("showCollapsedSessionCountDesc",
            zh: "在收起状态显示当前会话数量，方便快速判断是否仍有任务在运行",
            ko: "접힌 상태에서 현재 세션 수를 표시해 아직 진행 중인 작업이 있는지 빠르게 확인합니다.",
            ja: "折りたたみ時に現在のセッション数を表示し、まだ動いている作業があるかをすばやく確認できます。",
            fr: "Affiche le nombre de sessions dans l'état replié pour voir rapidement s'il reste du travail en cours.",
            en: "Show the current session count while collapsed so you can quickly see whether work is still active.")
    }

    static var showCollapsedQuotaDesc: String {
        localized("showCollapsedQuotaDesc",
            zh: "在收起状态显示首个可用的额度摘要，例如 Claude、Codex 或 Kimi 的剩余额度",
            ko: "접힌 상태에서 Claude, Codex, Kimi 같은 첫 번째 사용 가능한 사용량 요약을 표시합니다.",
            ja: "折りたたみ時に Claude、Codex、Kimi など最初に利用可能なクォータ概要を表示します。",
            fr: "Affiche dans l'état replié le premier résumé de quota disponible, par exemple Claude, Codex ou Kimi.",
            en: "Show the first available quota summary while collapsed, such as remaining Claude, Codex, or Kimi usage.")
    }

    static var showActivityTickerDesc: String {
        localized("showActivityTickerDesc",
            zh: "收起状态下滚动显示当前工具、最近一次工具结果或会话状态文本",
            ko: "접힌 상태에서 현재 도구, 최근 도구 결과, 또는 세션 상태 텍스트를 스크롤해 표시합니다.",
            ja: "折りたたみ時に現在のツール、直近のツール結果、またはセッション状態テキストをスクロール表示します。",
            fr: "Fait défiler l'outil en cours, le dernier résultat d'outil, ou le texte d'état de la session quand l'île est repliée.",
            en: "Scroll the current tool, most recent tool result, or session status text while the island is collapsed.")
    }

    static var activityTickerSpeedDesc: String {
        localized("activityTickerSpeedDesc",
            zh: "调整收起状态活动跑马灯的滚动速度",
            ko: "접힌 상태 활동 티커의 스크롤 속도를 조절합니다.",
            ja: "折りたたみ時のアクティビティティッカーのスクロール速度を調整します。",
            fr: "Ajuste la vitesse de défilement du ticker d'activité en mode replié.",
            en: "Adjust how fast the collapsed activity ticker scrolls.")
    }

    static var tickerContentModeDesc: String {
        localized("tickerContentModeDesc",
            zh: "选择收起状态跑马灯显示活动状态、项目名，或在两者之间自动轮换。",
            ko: "접힌 상태 티커에 활동 상태, 프로젝트 이름, 또는 두 내용을 자동 순환해 표시합니다.",
            ja: "折りたたみ時のティッカーにアクティビティ、プロジェクト名、またはその自動切替を表示します。",
            fr: "Choisissez d'afficher l'activité, le nom du projet, ou une rotation automatique entre les deux lorsque l'île est repliée.",
            en: "Choose whether the collapsed ticker shows activity, the project name, or rotates between the two automatically.")
    }

    static var sectionIslandSwitching: String {
        localized("sectionIslandSwitching",
            zh: "灵动岛切换", ko: "아일랜드 전환", ja: "アイランド切替", fr: "Basculement d'îles",
            en: "Island switching")
    }

    static var sectionCompanionIsland: String {
        localized("sectionCompanionIsland",
            zh: "对方灵动岛", ko: "상대 아일랜드", ja: "相手側の島", fr: "Île compagnon",
            en: "Companion island")
    }

    static var enableSwipeSwitchDesc: String {
        localized("enableSwipeSwitchDesc",
            zh: "仅在灵动岛收起时响应双指左右滑动，用来切换到另一个灵动岛应用",
            ko: "아일랜드가 접힌 상태일 때만 두 손가락 좌우 스와이프로 다른 아일랜드 앱으로 전환합니다.",
            ja: "島が折りたたまれているときだけ、二本指の横スワイプで別の島アプリへ切り替えます。",
            fr: "Quand l'île est réduite, utilisez un glissement horizontal à deux doigts pour basculer vers l'autre app île.",
            en: "When the island is collapsed, switch to the other island app with a two-finger horizontal swipe.")
    }

    static var switchSensitivityDesc: String {
        localized("switchSensitivityDesc",
            zh: "调整横滑切换所需的水平位移与方向判定强度",
            ko: "전환을 트리거하기 위해 필요한 수평 이동량과 방향 판정 강도를 조정합니다.",
            ja: "切替に必要な横方向の移動量と方向判定の厳しさを調整します。",
            fr: "Ajuste la distance horizontale et la fermeté nécessaires pour déclencher un basculement.",
            en: "Adjust how much horizontal movement is required before a swipe switch is triggered.")
    }

    static var startupDisplayDesc: String {
        localized("startupDisplayDesc",
            zh: "控制冷启动后默认显示哪个灵动岛；“上次使用”会记住最近一次显示的应用",
            ko: "콜드 런치 후 기본으로 표시할 아일랜드를 선택합니다. “마지막 사용”은 최근 표시한 앱을 기억합니다.",
            ja: "コールド起動後にどの島を表示するかを選びます。「前回使用」は直近で表示したアプリを覚えます。",
            fr: "Choisissez quelle île afficher après un lancement à froid. « Dernière utilisée » mémorise la dernière app affichée.",
            en: "Choose which island appears after a cold launch. “Last used” remembers the app that was shown most recently.")
    }

    static var counterpartInstalledDesc: String {
        localized("counterpartInstalledDesc",
            zh: "检查另一款灵动岛应用是否已安装在当前 Mac 上",
            ko: "다른 아일랜드 앱이 이 Mac에 설치되어 있는지 확인합니다.",
            ja: "もう一方の島アプリがこの Mac にインストールされているか確認します。",
            fr: "Vérifie si l'autre app île est installée sur ce Mac.",
            en: "Check whether the other island app is installed on this Mac.")
    }

    static var counterpartProtocolDesc: String {
        localized("counterpartProtocolDesc",
            zh: "检查切换所依赖的 URL Scheme 是否仍由另一款灵动岛正确处理",
            ko: "전환에 사용하는 URL Scheme 가 다른 아일랜드 앱으로 제대로 연결되어 있는지 확인합니다.",
            ja: "切替に使う URL Scheme がもう一方の島アプリに正しく関連付けられているか確認します。",
            fr: "Vérifie que l'URL scheme utilisé pour le basculement est toujours géré par l'autre app île.",
            en: "Check whether the URL scheme used for switching is still handled by the other island app.")
    }

    static var testSwitchDesc: String {
        localized("testSwitchDesc",
            zh: "立即请求切换到另一款灵动岛，用来验证联动配置与显示接管是否正常",
            ko: "다른 아일랜드 앱으로 즉시 전환하여 연동 설정과 표시 인계가 제대로 동작하는지 확인합니다.",
            ja: "すぐにもう一方の島へ切り替え、連携設定と表示引き継ぎが正しく動くか確認します。",
            fr: "Bascule immédiatement vers l'autre app île pour vérifier l'intégration et la reprise d'affichage.",
            en: "Immediately switch to the other island app to verify the integration settings and takeover flow.")
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

    // MARK: - Agent Flow

    static var agentFlow: String {
        localized("agentFlow",
            zh: "Agent Flow", ko: "Agent Flow", ja: "Agent Flow", fr: "Agent Flow",
            en: "Agent Flow")
    }

    static var agentFlowEmpty: String {
        localized("agentFlowEmpty",
            zh: "当前没有待处理阻塞", ko: "대기 중인 차단 없음", ja: "保留中のブロックなし", fr: "Aucun bloc en attente",
            en: "No pending blockers")
    }

    static var agentFlowGoHandle: String {
        localized("agentFlowGoHandle",
            zh: "前往处理", ko: "처리하기", ja: "対応する", fr: "Traiter",
            en: "Handle")
    }

    static var agentFlowBlockedUnit: String {
        localized("agentFlowBlockedUnit",
            zh: "阻塞", ko: "차단", ja: "ブロック", fr: "bloqués",
            en: "blocked")
    }

    static var agentFlowActiveUnit: String {
        localized("agentFlowActiveUnit",
            zh: "活跃", ko: "활성", ja: "アクティブ", fr: "actifs",
            en: "active")
    }

    /// 专用状态（permission / question / planReview）下进入 Agent Flow 总览的入口按钮文案。
    /// 紧凑表述，适配灵动岛顶部工具栏的有限横向空间。
    static var agentFlowViewEntry: String {
        localized("agentFlowViewEntry",
            zh: "查看 Agent Flow", ko: "Agent Flow 보기", ja: "Agent Flow を表示", fr: "Voir Agent Flow",
            en: "View Agent Flow")
    }

    static var agentFlowWaitingHumanInput: String {
        localized("agentFlowWaitingHumanInput",
            zh: "等待人工输入", ko: "사용자 입력 대기", ja: "入力待ち", fr: "Saisie requise",
            en: "Needs input")
    }

    static var agentFlowWaitingPermission: String {
        localized("agentFlowWaitingPermission",
            zh: "等待权限", ko: "권한 대기", ja: "権限待ち", fr: "Autorisation requise",
            en: "Needs approval")
    }

    static var agentFlowToolFailure: String {
        localized("agentFlowToolFailure",
            zh: "工具失败", ko: "도구 실패", ja: "ツール失敗", fr: "Échec outil",
            en: "Tool failed")
    }

    static var agentFlowNoBlocker: String {
        localized("agentFlowNoBlocker",
            zh: "无阻塞", ko: "차단 없음", ja: "ブロックなし", fr: "Aucun blocage",
            en: "No blocker")
    }

    static var agentFlowUngroupedSessions: String {
        localized("agentFlowUngroupedSessions",
            zh: "未分组会话", ko: "그룹 없는 세션", ja: "未グループのセッション", fr: "Sessions non groupées",
            en: "Ungrouped sessions")
    }

    static var agentFlowWaitingAnswer: String {
        localized("agentFlowWaitingAnswer",
            zh: "等待回答", ko: "답변 대기", ja: "回答待ち", fr: "Réponse attendue",
            en: "Waiting for answer")
    }

    static var agentFlowWaitingPlanReview: String {
        localized("agentFlowWaitingPlanReview",
            zh: "等待计划审核", ko: "계획 검토 대기", ja: "計画レビュー待ち", fr: "Revue du plan attendue",
            en: "Waiting for plan review")
    }

    static var agentFlowWaitingPermissionApproval: String {
        localized("agentFlowWaitingPermissionApproval",
            zh: "等待权限批准", ko: "권한 승인 대기", ja: "権限承認待ち", fr: "Autorisation attendue",
            en: "Waiting for approval")
    }

    static func agentFlowWaitingAnswerReason(_ text: String?) -> String {
        let preview = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !preview.isEmpty else { return agentFlowWaitingAnswer }
        return agentFlowReason(
            detail: preview,
            zhPrefix: "等待回答：",
            koPrefix: "답변 대기: ",
            jaPrefix: "回答待ち: ",
            frPrefix: "Réponse attendue : ",
            enPrefix: "Waiting for answer: "
        )
    }

    static func agentFlowWaitingApprovalReason(_ tool: String?) -> String {
        let name = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return agentFlowWaitingPermissionApproval }
        return agentFlowReason(
            detail: name,
            zhPrefix: "等待批准：",
            koPrefix: "승인 대기: ",
            jaPrefix: "承認待ち: ",
            frPrefix: "Autorisation attendue : ",
            enPrefix: "Waiting for approval: "
        )
    }

    static func agentFlowToolFailureReason(_ text: String) -> String {
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return agentFlowToolFailure }
        return agentFlowReason(
            detail: detail,
            zhPrefix: "工具失败：",
            koPrefix: "도구 실패: ",
            jaPrefix: "ツール失敗: ",
            frPrefix: "Échec outil : ",
            enPrefix: "Tool failed: "
        )
    }

    private static func agentFlowReason(
        detail: String,
        zhPrefix: String,
        koPrefix: String,
        jaPrefix: String,
        frPrefix: String,
        enPrefix: String
    ) -> String {
        let truncated = detail.count > 60 ? String(detail.prefix(60)) + "…" : detail
        let prefix = localized("agentFlowReasonPrefix",
            zh: zhPrefix, ko: koPrefix, ja: jaPrefix, fr: frPrefix,
            en: enPrefix)
        return prefix + truncated
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

    // MARK: - Session Grouping

    static var groupNone: String {
        localized("groupNone",
            zh: "不分组", ko: "그룹 없음", ja: "グループなし", fr: "Aucun groupement",
            en: "None")
    }

    static var groupAgentType: String {
        localized("groupAgentType",
            zh: "按代理类型", ko: "에이전트 유형별", ja: "エージェント種別別", fr: "Par type d'agent",
            en: "Agent Type")
    }

    static var groupWorkspace: String {
        localized("groupWorkspace",
            zh: "按工作区", ko: "작업 공간별", ja: "ワークスペース別", fr: "Par espace de travail",
            en: "Workspace")
    }

    static var groupStatus: String {
        localized("groupStatus",
            zh: "按状态", ko: "상태별", ja: "状態別", fr: "Par statut",
            en: "Status")
    }

    static var groupDate: String {
        localized("groupDate",
            zh: "按日期", ko: "날짜별", ja: "日付別", fr: "Par date",
            en: "Date")
    }

    static var dateGroupToday: String {
        localized("dateGroupToday",
            zh: "今天", ko: "오늘", ja: "今日", fr: "Aujourd'hui",
            en: "Today")
    }

    static var dateGroupYesterday: String {
        localized("dateGroupYesterday",
            zh: "昨天", ko: "어제", ja: "昨日", fr: "Hier",
            en: "Yesterday")
    }

    static var dateGroupThisWeek: String {
        localized("dateGroupThisWeek",
            zh: "本周", ko: "이번 주", ja: "今週", fr: "Cette semaine",
            en: "This Week")
    }

    static var dateGroupOlder: String {
        localized("dateGroupOlder",
            zh: "更早", ko: "이전", ja: "それ以前", fr: "Plus ancien",
            en: "Older")
    }

    // MARK: - Export

    static var exportSession: String {
        localized("exportSession",
            zh: "导出会话", ko: "세션 내보내기", ja: "セッション書き出し", fr: "Exporter la session",
            en: "Export Session")
    }

    static var exportFormat: String {
        localized("exportFormat",
            zh: "导出格式", ko: "내보내기 형식", ja: "書き出し形式", fr: "Format d'export",
            en: "Export Format")
    }

    static var batchExport: String {
        localized("batchExport",
            zh: "批量导出", ko: "일괄 내보내기", ja: "一括書き出し", fr: "Export groupé",
            en: "Batch Export")
    }

    static var searchSessions: String {
        localized("searchSessions",
            zh: "搜索会话...", ko: "세션 검색...", ja: "セッション検索...", fr: "Rechercher des sessions...",
            en: "Search sessions...")
    }

    // MARK: - Filter chips

    static var filterAll: String {
        localized("filterAll",
            zh: "全部", ko: "전체", ja: "すべて", fr: "Tout",
            en: "All")
    }

    // MARK: - Status display names

    static var statusActive: String {
        localized("statusActive",
            zh: "活跃", ko: "활성", ja: "アクティブ", fr: "Actif",
            en: "Active")
    }

    static var statusIdle: String {
        localized("statusIdle",
            zh: "空闲", ko: "대기", ja: "アイドル", fr: "Inactif",
            en: "Idle")
    }

    static var statusObservationUnavailable: String {
        localized("statusObservationUnavailable",
            zh: "状态未知", ko: "상태 알 수 없음", ja: "状態不明", fr: "État inconnu",
            en: "State unknown")
    }

    static var observationInterrupted: String {
        localized("observationInterrupted",
            zh: "观察中断", ko: "관찰 중단", ja: "観測中断", fr: "Observation interrompue",
            en: "Observation interrupted")
    }

    static var statusThinking: String {
        localized("statusThinking",
            zh: "思考中", ko: "생각 중", ja: "思考中", fr: "Réflexion",
            en: "Thinking")
    }

    static var statusWaitingPermission: String {
        localized("statusWaitingPermission",
            zh: "等待权限", ko: "권한 대기", ja: "権限待ち", fr: "Attente d'autorisation",
            en: "Waiting Permission")
    }

    static var statusWaitingAnswer: String {
        localized("statusWaitingAnswer",
            zh: "等待回答", ko: "답변 대기", ja: "回答待ち", fr: "Attente de réponse",
            en: "Waiting Answer")
    }

    static var statusWaitingPlanReview: String {
        localized("statusWaitingPlanReview",
            zh: "等待计划审查", ko: "계획 검토 대기", ja: "計画レビュー待ち", fr: "Révision en attente",
            en: "Waiting Plan Review")
    }

    static var statusCompleted: String {
        localized("statusCompleted",
            zh: "已完成", ko: "완료", ja: "完了", fr: "Terminé",
            en: "Completed")
    }

    static var statusError: String {
        localized("statusError",
            zh: "错误", ko: "오류", ja: "エラー", fr: "Erreur",
            en: "Error")
    }

    static var statusCompacting: String {
        localized("statusCompacting",
            zh: "压缩中", ko: "압축 중", ja: "圧縮中", fr: "Compactage",
            en: "Compacting")
    }

    // MARK: - Statistics

    static var paneStatistics: String {
        localized("paneStatistics",
            zh: "统计", ko: "통계", ja: "統計", fr: "Statistiques",
            en: "Statistics")
    }

    static var sectionStatistics: String {
        localized("sectionStatistics",
            zh: "统计分析", ko: "통계 분석", ja: "統計分析", fr: "Analyse statistique",
            en: "Statistics")
    }

    static var timeRangeWeek: String {
        localized("timeRangeWeek",
            zh: "本周", ko: "이번 주", ja: "今週", fr: "Cette semaine",
            en: "Week")
    }

    static var timeRangeMonth: String {
        localized("timeRangeMonth",
            zh: "本月", ko: "이번 달", ja: "今月", fr: "Ce mois",
            en: "Month")
    }

    static var timeRangeAll: String {
        localized("timeRangeAll",
            zh: "全部", ko: "전체", ja: "すべて", fr: "Tout",
            en: "All")
    }

    static var statTotalSessions: String {
        localized("statTotalSessions",
            zh: "总会话数", ko: "총 세션", ja: "総セッション数", fr: "Total sessions",
            en: "Sessions")
    }

    static var statTotalDuration: String {
        localized("statTotalDuration",
            zh: "总时长", ko: "총 시간", ja: "合計時間", fr: "Durée totale",
            en: "Duration")
    }

    static var statTotalCost: String {
        localized("statTotalCost",
            zh: "总费用", ko: "총 비용", ja: "合計コスト", fr: "Coût total",
            en: "Cost")
    }

    static var statTotalTokens: String {
        localized("statTotalTokens",
            zh: "总 Token", ko: "총 토큰", ja: "合計トークン", fr: "Tokens totaux",
            en: "Tokens")
    }

    static var statDailyUsage: String {
        localized("statDailyUsage",
            zh: "每日使用量", ko: "일별 사용량", ja: "日別使用量", fr: "Utilisation quotidienne",
            en: "Daily Usage")
    }

    static var statAgentDistribution: String {
        localized("statAgentDistribution",
            zh: "代理分布", ko: "에이전트 분포", ja: "エージェント分布", fr: "Répartition par agent",
            en: "Agent Distribution")
    }

    static var statTopTools: String {
        localized("statTopTools",
            zh: "常用工具 (Top 10)", ko: "자주 사용하는 도구 (Top 10)", ja: "よく使うツール (Top 10)", fr: "Outils les plus utilisés (Top 10)",
            en: "Top Tools")
    }

    static var statTokenTrend: String {
        localized("statTokenTrend",
            zh: "Token 趋势", ko: "토큰 추세", ja: "トークントレンド", fr: "Tendance des tokens",
            en: "Token Trend")
    }

    // MARK: - Keyboard Shortcuts

    static var shortcutExport: String {
        localized("shortcutExport",
            zh: "导出会话", ko: "세션 내보내기", ja: "セッション書き出し", fr: "Exporter la session",
            en: "Export Session")
    }

    static var shortcutSearch: String {
        localized("shortcutSearch",
            zh: "搜索会话", ko: "세션 검색", ja: "セッション検索", fr: "Rechercher",
            en: "Search Sessions")
    }

    static var shortcutPrevious: String {
        localized("shortcutPrevious",
            zh: "上一个会话", ko: "이전 세션", ja: "前のセッション", fr: "Session précédente",
            en: "Previous Session")
    }

    static var shortcutNext: String {
        localized("shortcutNext",
            zh: "下一个会话", ko: "다음 세션", ja: "次のセッション", fr: "Session suivante",
            en: "Next Session")
    }

    static var shortcutToggleTheme: String {
        localized("shortcutToggleTheme",
            zh: "切换主题", ko: "테마 전환", ja: "テーマ切替", fr: "Changer de thème",
            en: "Toggle Theme")
    }
}


extension L10n {
    static func sessionJumpMessage(_ result: SessionJumpResult) -> String {
        switch result {
        case .conversationRequested, .terminalFocused: return ""
        case .missingIdentity:
            return localized("jumpMissingIdentity", zh: "缺少对应聊天或终端标签的定位标识，请从原客户端重新运行一次任务。", ko: "정확한 세션 식별자가 없습니다. 클라이언트에서 작업을 다시 실행하세요.", ja: "会話やタブの識別子がありません。元のクライアントでタスクを再実行してください。", fr: "Identifiant de conversation ou d’onglet manquant. Relancez une tâche dans le client.", en: "The conversation or terminal tab identifier is missing. Run a task again in the original client.")
        case .unavailable:
            return localized("jumpUnavailable", zh: "此客户端尚无可用的精确会话跳转，请在原客户端打开该聊天。", ko: "이 클라이언트의 정확한 대화 이동은 아직 지원되지 않습니다.", ja: "このクライアントでは正確な会話への移動がまだ利用できません。", fr: "La navigation précise n’est pas encore disponible pour ce client.", en: "Precise conversation navigation is not available for this client. Open the chat in the original client.")
        case .applicationUnavailable:
            return localized("jumpApplicationUnavailable", zh: "无法打开对应客户端，未切换到其他软件或窗口。", ko: "대상 클라이언트를 열 수 없습니다.", ja: "対象のクライアントを開けませんでした。", fr: "Impossible d’ouvrir le client demandé.", en: "The target client could not be opened. No other app or window was selected.")
        case .automationDenied:
            return localized("jumpAutomationDenied", zh: "请在系统设置的“隐私与安全性 → 自动化”中允许 X Island 控制对应终端。", ko: "시스템 설정의 개인정보 보호 및 보안 → 자동화에서 터미널 제어를 허용하세요.", ja: "システム設定のプライバシーとセキュリティ → オートメーションで対象ターミナルの制御を許可してください。", fr: "Autorisez le contrôle du terminal dans Réglages système → Confidentialité et sécurité → Automatisation.", en: "Allow X Island to control this terminal in System Settings → Privacy & Security → Automation.")
        case .targetNotFound:
            return localized("jumpTargetNotFound", zh: "对应终端标签页已关闭，或无法唯一定位；未打开其他会话。", ko: "터미널 탭을 찾지 못했거나 일치 항목이 여러 개입니다.", ja: "対象のターミナルタブが閉じているか、一意に特定できませんでした。", fr: "L’onglet est fermé ou ne peut pas être identifié de façon unique.", en: "The terminal tab is closed or could not be uniquely identified. No other session was selected.")
        case .commandFailed:
            return localized("jumpCommandFailed", zh: "未能定位该终端会话，请确认标签页仍打开且客户端的远程控制可用。", ko: "터미널 세션을 찾지 못했습니다. 탭과 원격 제어를 확인하세요.", ja: "ターミナルセッションを移動できませんでした。タブとリモート制御を確認してください。", fr: "Session introuvable. Vérifiez l’onglet et le contrôle à distance du terminal.", en: "The terminal session could not be focused. Check that its tab is open and remote control is available.")
        }
        }
}
