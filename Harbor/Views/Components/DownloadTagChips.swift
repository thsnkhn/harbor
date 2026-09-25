import SwiftUI

struct DownloadTagChips: View {
    @Binding var tags: [String]
    let availableTags: [String]
    var showsAvailableTags = false
    @State private var isEditing = false
    @State private var tagName = ""

    var body: some View {
        TagFlowLayout {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Text("#" + tag)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .modifier(DownloadTagStyle())
                .help("#" + tag)
            }

            if showsAvailableTags {
                ForEach(unappliedTags, id: \.self) { tag in
                    Button {
                        tags = DownloadTags.normalized(tags + [tag])
                    } label: {
                        Text("#" + tag)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .modifier(DownloadTagStyle())
                    }
                    .buttonStyle(.plain)
                    .help("Add #" + tag)
                    .accessibilityLabel("Add tag \(tag)")
                }
            }

            Button { tagName = ""; isEditing = true } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.medium))
                    .modifier(DownloadTagStyle(isSquare: true))
            }
            .buttonStyle(.plain)
            .help("Add Tags")
            .accessibilityLabel("Add Tags")
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField("Add Tag", text: $tagName)
                            .onSubmit(addTag)
                        Button("Add", action: addTag)
                            .disabled(DownloadTags.normalized([tagName]).isEmpty)
                    }
                    if !suggestedTags.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(suggestedTags, id: \.self) { tag in
                                    Button {
                                        tagName = tag
                                        addTag()
                                    } label: {
                                        Text("#" + tag)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(suggestedTags.count) * 28 - 4, 140))
                    }
                    if !tagName.isEmpty && DownloadTags.normalized([tagName]).isEmpty {
                        Text("Use one word, with hyphens or underscores if needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(width: 280)
                .foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    private var suggestedTags: [String] {
        let query = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return unappliedTags.filter {
            query.isEmpty || $0.localizedStandardContains(query)
        }
    }

    private var unappliedTags: [String] {
        let applied = Set(tags.map(DownloadTags.key))
        return availableTags.filter {
            !applied.contains(DownloadTags.key($0))
        }
    }

    private func addTag() {
        guard let tag = DownloadTags.normalized([tagName]).first else { return }
        tags = DownloadTags.normalized(tags + [tag])
        isEditing = false
    }

}
