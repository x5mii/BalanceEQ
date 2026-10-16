// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Keep partial input ("-", "0.") out of the validated, live audio configuration.
struct DecimalField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var editing: Bool

    var body: some View {
        TextField(label, text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($editing)
            .onAppear { reset() }
            .onChange(of: value) { _, _ in reset() }
            .onChange(of: editing) { wasEditing, isEditing in
                if wasEditing && !isEditing { commit() }
            }
            .onSubmit { commit() }
            .onExitCommand { reset(); editing = false }
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(invalid ? Color.red : .clear))
            .help(invalid ? "Value unchanged. Enter \(range.lowerBound.formatted()) to \(range.upperBound.formatted())." : "Type a number, then press Return or Tab. Escape cancels.")
            .accessibilityLabel(label)
            .accessibilityHint(invalid ? "Invalid value. Previous value retained." : "Press Return or Tab to apply")
    }

    private func reset() {
        draft = value.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
        invalid = false
    }

    private func commit() {
        guard let parsed = Self.parse(draft, range: range) else {
            reset()
            invalid = true
            return
        }
        if value != parsed { value = parsed }
        reset()
    }

    static func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, range.contains(value) else { return nil }
        return value
    }

    #if DEBUG
    static func check() {
        precondition(parse("0.2", range: 0.1...30) == 0.2)
        precondition(parse("0,2", range: 0.1...30) == 0.2)
        precondition(parse("-4.7", range: -60...12) == -4.7)
        for text in ["", "-", "0", "0.", "31", "nan", "inf", "0.2oops", "1,2.3"] {
            precondition(parse(text, range: 0.1...30) == nil)
        }
        precondition(parse("0.1", range: 0.1...30) == 0.1 && parse("30", range: 0.1...30) == 30)
    }
    #endif
}
