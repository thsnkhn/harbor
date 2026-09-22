import Foundation
import SwiftUI

struct RootView: View {
    let center: DownloadCenter
    let settings: AppSettingsStore
    @AppStorage("downloads.sidebar.isVisible")
    private var isSidebarVisible = false
    @AppStorage("downloads.sidebar.width")
    private var storedSidebarWidth = Double(Layout.sidebarIdealWidth)
    @AppStorage("downloads.inspector.width")
    private var storedInspectorWidth = Double(Layout.inspectorIdealWidth)
    @State private var sidebarColumns: NavigationSplitViewVisibility
    @State private var sidebarWidthSaveTask: Task<Void, Never>?
    @State private var isDownloadDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    init(center: DownloadCenter, settings: AppSettingsStore) {
        self.center = center
        self.settings = settings
        _sidebarColumns = State(initialValue:
            HarborTestRuntime.userDefaults.bool(forKey: "downloads.sidebar.isVisible") ? .all : .detailOnly
        )
    }

    private enum Layout {
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarIdealWidth: CGFloat = 230
        static let sidebarMaxWidth: CGFloat = 280
        static let inspectorIdealWidth: CGFloat = 340
    }

    var body: some View {
        @Bindable var center = center

        NavigationSplitView(columnVisibility: $sidebarColumns.animation(.default)) {
            SidebarView(center: center)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    persistSidebarWidth(width)
                }
                .navigationSplitViewColumnWidth(
                    min: Layout.sidebarMinWidth,
                    ideal: restoredSidebarWidth,
                    max: Layout.sidebarMaxWidth
                )
        } detail: {
            // The table's fixed columns must not set the split view's minimum width.
            // Only its viewport shrinks; overflow stays in the table's native scroll view.
            GeometryReader { geometry in
                DownloadsContentView(center: center)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
                .inspector(isPresented: inspectorPresentation) {
                    DownloadDetailView(center: center)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            // Closing geometry must not overwrite the last open width.
                            guard center.selectedDownload != nil,
                                  width >= 300, width <= 600,
                                  abs(storedInspectorWidth - Double(width)) >= 1 else { return }
                            storedInspectorWidth = Double(width)
                        }
                        .inspectorColumnWidth(min: 300, ideal: min(max(storedInspectorWidth, 300), 600), max: 600)
                }
                // Keep app controls in the navigation toolbar, above both content panes.
                .searchable(text: $center.searchText, placement: .toolbar, prompt: "Search downloads")
                .searchFocused($isSearchFocused)
                // TODO: Revisit customizable toolbars after macOS 26 stops crashing while restoring toolbar items during file opens.
                .toolbar {
                    DownloadToolbarContent(center: center, settings: settings)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onDisappear {
            sidebarWidthSaveTask?.cancel()
        }
        .onChange(of: sidebarColumns) { _, visibility in
            if visibility == .detailOnly {
                isSidebarVisible = false
            } else if visibility == .all || visibility == .doubleColumn {
                isSidebarVisible = true
            }
        }
        .accessibilityIdentifier(HarborAccessibility.root)
        .focusedSceneValue(\.focusDownloadSearch, focusSearch)
        .focusedSceneValue(\.sidebarVisibility, $sidebarColumns)
        .sheet(item: $center.addSheetDraft, onDismiss: {
            center.handleAddSheetDismissal()
        }) { draft in
            AddDownloadSheet(
                settings: settings,
                availableTags: center.availableTags,
                draft: draft,
                mediaPreviewProvider: { url in
                    try await center.previewMediaDownload(for: url)
                },
                torrentPreviewProvider: { sourceKind, url, requestHeaders in
                    try await center.previewTorrentContents(
                        sourceKind: sourceKind,
                        sourceURL: url,
                        requestHeaders: requestHeaders
                    )
                }
            ) { requests in
                center.queueDownloads(requests)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { center.activeBrowserSession != nil },
                set: { isPresented in
                    if isPresented == false {
                        center.dismissBrowserSession()
                    }
                }
            )
        ) {
            if let session = center.activeBrowserSession {
                BrowserDownloadSheet(center: center, session: session)
            }
        }
        .alert(
            center.activeAlert?.title ?? "Alert",
            isPresented: Binding(
                get: { center.activeAlert != nil },
                set: { isPresented in
                    if isPresented == false {
                        center.activeAlert = nil
                    }
                }
            )
        ) {
            if center.canRetryInitialization {
                Button("Retry") {
                    center.activeAlert = nil
                    Task {
                        await center.initializeIfNeeded()
                    }
                }
            } else {
                Button("OK", role: .cancel) {
                    center.activeAlert = nil
                }
            }
        } message: {
            Text(center.activeAlert?.message ?? "")
        }
        .onDrop(
            of: DownloadSourceImportService.supportedContentTypes,
            isTargeted: $isDownloadDropTargeted,
            perform: loadExternalAddSources
        )
        .onPasteCommand(of: DownloadSourceImportService.supportedContentTypes) { providers in
            _ = loadExternalAddSources(providers)
        }
        .overlay {
            if isDownloadDropTargeted {
                DownloadDropTargetOverlay()
                    .allowsHitTesting(false)
            }
        }
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { center.selectedDownload != nil },
            set: { isPresented in
                if isPresented == false { center.selectedDownloadIDs = [] }
            }
        )
    }

    private var restoredSidebarWidth: CGFloat {
        min(max(CGFloat(storedSidebarWidth), Layout.sidebarMinWidth), Layout.sidebarMaxWidth)
    }

    private func persistSidebarWidth(_ width: CGFloat) {
        sidebarWidthSaveTask?.cancel()
        // Ignore collapsed geometry so hiding the sidebar preserves its open width.
        guard isSidebarVisible,
              width.isFinite,
              width >= Layout.sidebarMinWidth - 1,
              width <= Layout.sidebarMaxWidth + 1 else { return }

        let clampedWidth = min(max(width, Layout.sidebarMinWidth), Layout.sidebarMaxWidth)
        guard abs(storedSidebarWidth - Double(clampedWidth)) >= 0.5 else { return }
        sidebarWidthSaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            storedSidebarWidth = Double(clampedWidth)
        }
    }

    private func loadExternalAddSources(_ providers: [NSItemProvider]) -> Bool {
        DownloadSourceImportService.loadSupportedURLs(from: providers) { urls in
            center.receiveExternalAddSources(urls)
        }
    }

    private func focusSearch() {
        isSearchFocused = true
    }
}

private struct DownloadDropTargetOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.04))

            Label("Drop to Add Download", systemImage: "arrow.down.doc")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.quaternary)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
        }
    }
}

private struct DownloadToolbarContent: ToolbarContent {
    @Bindable var center: DownloadCenter
    @Bindable var settings: AppSettingsStore

    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .primaryAction) {
                ToolbarTransferSpeeds(center: center)
                    .padding(.horizontal, 8)
            }
            .sharedBackgroundVisibility(.visible)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .primaryAction) {
                ToolbarTransferSpeeds(center: center)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("New Download", systemImage: "plus") {
                center.presentAddSheet()
            }
            .accessibilityIdentifier(HarborAccessibility.newDownload)
            .disabled(center.canAddDownloads == false)
        }

        ToolbarItem(placement: .primaryAction) {
            Button(
                center.hasActiveDownloads ? "Pause All" : "Resume All",
                systemImage: center.hasActiveDownloads ? "pause.fill" : "play.fill"
            ) {
                if center.hasActiveDownloads {
                    center.pauseAll()
                } else {
                    center.resumeAll()
                }
            }
            .accessibilityIdentifier(HarborAccessibility.pauseResumeAll)
            .disabled(
                center.hasActiveDownloads
                    ? center.hasPausableDownloads == false
                    : center.hasResumableDownloads == false
            )
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(TrafficMode.allCases) { mode in
                    Toggle(
                        mode.title,
                        isOn: Binding(
                            get: { settings.trafficMode == mode },
                            set: { isSelected in
                                if isSelected {
                                    settings.trafficMode = mode
                                }
                            }
                        )
                    )
                }

                Divider()

                SettingsLink {
                    Label("Edit Limits…", systemImage: "gearshape")
                }
            } label: {
                Label(settings.trafficMode.title, systemImage: settings.trafficMode.systemImage)
                    .labelStyle(.titleAndIcon)
            }
            .help("Traffic Mode")
        }

    }

}

private struct ToolbarTransferSpeeds: View {
    let center: DownloadCenter

    var body: some View {
        HStack(spacing: 12) {
            throughputMetric(
                systemImage: "arrow.down",
                value: DownloadFormatting.throughputString(center.totalDownloadSpeed),
                title: "Total download speed"
            )
            throughputMetric(
                systemImage: "arrow.up",
                value: DownloadFormatting.throughputString(center.totalUploadSpeed),
                title: "Total upload speed"
            )
        }
        .font(.callout)
        .frame(width: 164)
    }

    private func throughputMetric(
        systemImage: String,
        value: String,
        title: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 60, alignment: .leading)
        }
        .frame(width: 76, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(value)
        .help(Text(title))
    }

}

#Preview("Harbor Window") {
    let settings = HarborPreviewFixtures.makeSettings()
    let center = HarborPreviewFixtures.makeCenter()

    RootView(center: center, settings: settings)
        .frame(width: 1_320, height: 820)
}
