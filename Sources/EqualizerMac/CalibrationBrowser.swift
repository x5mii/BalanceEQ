// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import EQCore

struct CalibrationBrowser: View {
    @ObservedObject var model: AppModel
    var linkOnly = false
    var onSelect: ((CalibrationProfile) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @State private var error: String?
    @State private var busy = false
    private var matches: [CalibrationProfile] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return model.calibrationProfiles.filter { profile in
            words.allSatisfy { (profile.name + " " + profile.source + " " + profile.variant).localizedStandardContains(String($0)) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(linkOnly ? "Link a headphone measurement" : "Choose your headphones").font(.title2.bold())
            Text(linkOnly ? "Choose the exact model and pad variant. Linking keeps your current EQ unchanged." : "Choose the exact model and pad variant. Your sound changes only when you apply the correction.")
                .foregroundStyle(.secondary)
            TextField("Search headphones, measurement author or variant", text: $search).textFieldStyle(.roundedBorder)
            List(matches, selection: $selection) { profile in
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).fontWeight(.medium)
                    Text("\(profile.source) · \(profile.variant) · Measurement available").font(.caption).foregroundStyle(.secondary)
                }.tag(profile.id).padding(.vertical, 3)
            }.overlay { if model.calibrationProfiles.isEmpty && error == nil { ProgressView() } }
            if let selected = model.calibrationProfiles.first(where: { $0.id == selection }) {
                Text(selected.targetName).font(.caption)
                Link("Measurement, target and correction source", destination: selected.sourceURL).font(.caption)
            }
            Text("Predicted model response, not a measurement of your pair. AutoEq · MIT · original measurement authors credited. All bundled data works offline.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Text("\(matches.count) measured profiles").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button(linkOnly ? "Link Measurement" : "Choose Headphones") {
                    guard let profile = model.calibrationProfiles.first(where: { $0.id == selection }) else { return }
                    if let onSelect { onSelect(profile); dismiss(); return }
                    busy = true
                    Task {
                        do { try await model.useCalibration(profile, linkOnly: linkOnly); dismiss() }
                        catch { self.error = error.localizedDescription; busy = false }
                    }
                }.buttonStyle(.borderedProminent).disabled(selection == nil || busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 600)
            .task { do { try await model.loadCalibrationCatalog() } catch { self.error = error.localizedDescription } }
            .onChange(of: search) { _, _ in if !matches.contains(where: { $0.id == selection }) { selection = nil } }
    }
}
