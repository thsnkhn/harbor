import SwiftUI

struct DownloadTagBrowser: View {
    let center: DownloadCenter
    @State private var tagToRename: String?
    @State private var newName = ""
    @State private var tagToDelete: String?

    var body: some View {
        TagFlowLayout {
            ForEach(center.availableTags, id: \.self) { tag in
                let key = DownloadTags.key(tag)
                let selected = center.selectedTags.contains(key)
                Button {
                    if selected { center.selectedTags.remove(key) }
                    else { center.selectedTags.insert(key) }
                } label: {
                    Text("#" + tag)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .modifier(DownloadTagStyle(isSelected: selected))
                }
                .buttonStyle(.plain)
                .help("#" + tag)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    Button("Rename Tag…") { newName = tag; tagToRename = tag }
                    Button("Delete Tag…", role: .destructive) { tagToDelete = tag }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .alert("Rename Tag", isPresented: Binding(
            get: { tagToRename != nil }, set: { if !$0 { tagToRename = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { tagToRename = nil }
            Button("Rename") {
                if let tagToRename { center.renameTag(tagToRename, to: newName) }
                tagToRename = nil
            }
            .disabled(DownloadTags.normalized([newName]).isEmpty)
        } message: {
            Text("Use one word, with hyphens or underscores if needed. An existing name merges the tags.")
        }
        .alert("Delete Tag?", isPresented: Binding(
            get: { tagToDelete != nil }, set: { if !$0 { tagToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { tagToDelete = nil }
            Button("Delete", role: .destructive) {
                if let tagToDelete { center.deleteTag(tagToDelete) }
                tagToDelete = nil
            }
        } message: {
            Text("Remove #\(tagToDelete ?? "") from all downloads? Downloaded files will stay in place.")
        }
    }
}

struct DownloadTagFilterBar: View {
    let center: DownloadCenter

    var body: some View {
        @Bindable var center = center
        HStack(spacing: 12) {
            Label(center.selectedTags.sorted().map { "#" + $0 }.joined(separator: ", "), systemImage: "tag")
                .lineLimit(1)
                .help(center.selectedTags.sorted().joined(separator: ", "))
            Spacer(minLength: 0)
            if center.selectedTags.count > 1 {
                Picker("Match tags", selection: $center.matchesAllTags) {
                    Text("All Selected").tag(true)
                    Text("Any Selected").tag(false)
                }
                .labelsHidden()
                .fixedSize()
            }
            Button("Clear Tags") { center.selectedTags = [] }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        Divider()
    }
}

struct TagFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 230).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + 6
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + 6
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}

struct DownloadTagStyle: ViewModifier {
    var isSelected = false
    var isSquare = false

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .frame(width: isSquare ? 22 : nil, height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)))
            }
    }
}
