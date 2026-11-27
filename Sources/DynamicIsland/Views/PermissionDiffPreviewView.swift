import SwiftUI

/// 文件修改审批的只读 diff 预览；只使用 hook 提供的 tool_input，不读取磁盘文件。
struct PermissionDiffPreviewView: View {
    let preview: PermissionDiffPreview
    let expanded: Bool
    let scheme: ColorScheme
    let requestID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(preview.kind.rawValue) · \(L10n.permissionDiffPreview)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("+\(preview.addedLineCount) −\(preview.removedLineCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(IslandStyle.secondaryText)
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(IslandStyle.secondaryText)
                    .help(L10n.permissionDiffPartialHint)
                Spacer(minLength: 4)
            }
            Text(preview.filePath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(IslandStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(preview.filePath)

            if preview.kind == .write {
                Text(L10n.permissionDiffWriteHint)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preview.hunks) { hunk in
                        if preview.hunks.count > 1 {
                            Text(L10n.permissionDiffHunk(hunk.id + 1))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(IslandStyle.secondaryText)
                                .padding(.top, 2)
                        }
                        if hunk.replaceAll {
                            Text(L10n.permissionDiffReplaceAll)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { _, line in
                            diffLine(line, prefix: "-", color: .red)
                        }
                        ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { _, line in
                            diffLine(line, prefix: "+", color: .green)
                        }
                    }
                    if preview.omittedHunkCount > 0 {
                        Text(L10n.permissionDiffMoreHunks(preview.omittedHunkCount))
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.secondaryText)
                    }
                    if preview.kind == .notebook, preview.notebookMode == "delete" {
                        Text(L10n.permissionDiffNotebookDelete)
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.secondaryText)
                    } else if preview.addedLineCount == 0 && preview.removedLineCount == 0 {
                        Text(preview.kind == .write
                             ? L10n.permissionDiffEmptyWrite
                             : L10n.permissionDiffNoChanges)
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.secondaryText)
                    }
                    if preview.isTruncated {
                        Text(L10n.permissionDiffTruncated)
                            .font(.system(size: 9))
                            .foregroundStyle(IslandStyle.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: expanded ? 190 : 82)
        }
        .padding(8)
        .background(IslandStyle.codeWell(for: scheme))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preview.filePath) +\(preview.addedLineCount) −\(preview.removedLineCount)")
        .accessibilityIdentifier("island.permission-diff-preview-\(requestID.uuidString)")
    }

    private func diffLine(_ text: String, prefix: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(prefix)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 8, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(IslandStyle.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
