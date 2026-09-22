import SwiftUI

struct DownloadInspectorTags: View {
    let item: DownloadItem
    let center: DownloadCenter
    @State private var isEditing = false
    @State private var tagName = ""

    var body: some View {
        TagFlowLayout {
            ForEach(item.tags, id: \.self) { tag in
                HStack(spacing: 5) {
                    Text("#" + tag)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        center.setTags(item.tags.filter { $0 != tag }, for: item.id)
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
        let applied = Set(item.tags.map(DownloadTags.key))
        return center.availableTags.filter {
            !applied.contains(DownloadTags.key($0)) && (query.isEmpty || $0.localizedStandardContains(query))
        }
    }

    private func addTag() {
        guard let tag = DownloadTags.normalized([tagName]).first else { return }
        center.setTags(item.tags + [tag], for: item.id)
        isEditing = false
    }

}
