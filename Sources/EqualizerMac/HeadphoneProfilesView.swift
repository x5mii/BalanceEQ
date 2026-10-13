import AppKit
import EQCore
import SwiftUI

struct HeadphoneProfilesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [HeadphoneProfile] = []
    @State private var search = ""
    @State private var selection: String?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var matches: [HeadphoneProfile] {
        let words = search.split(whereSeparator: \.isWhitespace)
        return profiles.filter { profile in
            words.allSatisfy { word in
                (profile.name + " " + profile.creator + " " + profile.description).localizedStandardContains(String(word))
            }
        }
    }
    private var selected: HeadphoneProfile? { profiles.first { $0.id == selection } }

    var body: some View {
        let results = matches
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "headphones").font(.system(size: 28)).foregroundStyle(.teal).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Headphone Profiles").font(.title2.bold())
                    Text("Find your exact model and choose a tuning. All included profiles work offline.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            TextField("Search brand, model, or creator", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search headphone profiles")
            HStack {
                Text(isLoading ? "Loading profiles…" : "\(results.count.formatted()) profiles").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import EQ File…") {
                    do { if try model.pickImportedPreset() { dismiss() } }
                    catch { errorMessage = error.localizedDescription }
                }.help("Import Equalizer APO parametric text, including AutoEQ ParametricEQ.txt files.")
            }
            List(results, selection: $selection) { profile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).fontWeight(.medium)
                    Text(profile.creator).font(.caption).foregroundStyle(.secondary)
                    Text(profile.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }.padding(.vertical, 3).tag(profile.id)
            }
            .overlay {
                if isLoading { ProgressView("Loading headphone profiles…") }
                else if results.isEmpty {
                    ContentUnavailableView("No matching headphones", systemImage: "headphones",
                                           description: Text("Try a shorter model name, or import a parametric EQ file."))
                }
            }
            .frame(minHeight: 235)

            if let selected {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tuning by \(selected.creator)").font(.callout.weight(.semibold))
                    if !selected.description.isEmpty {
                        Text(selected.description).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).help(selected.description)
                    }
                    if let url = selected.sourceURL { Link("Profile source", destination: url).font(.caption) }
                }
            } else {
                Text("Choose the exact variant, pad type, and listening mode for your headphones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                if let url = HeadphoneCatalog.logoURL, let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.primary).frame(width: 100, height: 32)
                        .accessibilityLabel("OPRA")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Link("OPRA · Open Profiles for Revealing Audio", destination: HeadphoneCatalog.upstreamURL)
                    Text("Community headphone tunings · CC BY-SA 4.0. Profiles outside this app’s supported filter limits are omitted.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.font(.caption)
            HStack {
                Text("Applied profiles are saved in your preset menu.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Profile") {
                    guard let selected else { return }
                    do { try model.installProfile(selected.preset()); dismiss() }
                    catch { errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(24).frame(width: 640, height: 660).tint(.teal)
        .task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try HeadphoneCatalog.bundled() }.value
                try Task.checkCancellation()
                profiles = loaded
                isLoading = false
            } catch is CancellationError { }
            catch { isLoading = false; errorMessage = "Could not load headphone profiles: \(error.localizedDescription)" }
        }
        .onChange(of: search) { _, _ in
            if let selection, !matches.contains(where: { $0.id == selection }) { self.selection = nil }
        }
        .alert("Could not load profile", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
