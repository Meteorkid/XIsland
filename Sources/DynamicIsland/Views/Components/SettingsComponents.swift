import SwiftUI

// MARK: - AppStorage 驱动的无级滑块（支持手动输入）

struct AppStorageSlider: View {
    @AppStorage private var value: Double
    @State private var inputText: String = ""
    @State private var isEditing = false

    private let range: ClosedRange<Double>
    private let step: Double?
    private let format: String

    /// 无级调节（不传 step）
    init(key: String, range: ClosedRange<Double>, format: String = "%.0f") {
        _value = AppStorage(wrappedValue: range.lowerBound, key)
        self.range = range
        self.step = nil
        self.format = format
    }

    /// 带步长调节
    init(key: String, range: ClosedRange<Double>, step: Double, format: String = "%.0f") {
        _value = AppStorage(wrappedValue: range.lowerBound, key)
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 8) {
            if let step {
                Slider(value: $value, in: range, step: step)
                    .frame(width: 140)
            } else {
                Slider(value: $value, in: range)
                    .frame(width: 140)
            }
            if isEditing {
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commitInput() }
                    .onExitCommand { commitInput() }
            } else {
                Button(action: {
                    inputText = String(format: format, value)
                    isEditing = true
                }) {
                    Text(String(format: format, value))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 65, alignment: .trailing)
            }
        }
    }

    private func commitInput() {
        isEditing = false
        let cleaned = inputText.filter { "0123456789.".contains($0) }
        if let v = Double(cleaned) {
            value = min(max(v, range.lowerBound), range.upperBound)
        }
    }
}
