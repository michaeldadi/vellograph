import AppKit
import DiffCore
import SyntaxCore
import SwiftUI
import UniformTypeIdentifiers

struct TextComparisonView: View {
    let comparison: TextComparison
    let workspace: WorkspaceModel
    let tabID: UUID
    @State private var sourceComparison: TextComparison
    @State private var displayed: TextComparison
    @State private var displayedVersion = UUID()
    @State private var scrollRequest: UUID?
    @State private var sourceVersion = UUID()
    @State private var sourceStamps: [TextSourceStamp?] = []
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var liveUpdatesPaused = false
    @State private var layout: Layout = .blocks
    @State private var showLineNumbers = true
    @State private var showInvisibles = false
    @State private var wrapLines = false
    @State private var syntaxLanguage: SyntaxLanguage = .automatic
    @State private var leftSyntaxScopes: [[SyntaxScope]] = []
    @State private var rightSyntaxScopes: [[SyntaxScope]] = []
    @State private var syntaxVersion = UUID()
    @AppStorage("syntaxTheme.v1") private var syntaxThemeName = SyntaxTheme.adaptive.rawValue
    @State private var search = ""
    @State private var currentHunk = -1
    @State private var ignoreWhitespace = false
    @State private var ignoreLineEndings = false
    @State private var normalizeJSON = false
    @State private var filters: [TextReplacementFilter] = []
    @State private var showFilters = false
    @State private var showResolution = false
    @State private var processing = false
    @State private var errorMessage: String?

    init(comparison: TextComparison, workspace: WorkspaceModel, tabID: UUID) {
        self.comparison = comparison
        self.workspace = workspace
        self.tabID = tabID
        _sourceComparison = State(initialValue: comparison)
        _displayed = State(initialValue: comparison)
    }

    private var filterSignature: String {
        "\(ignoreWhitespace):\(ignoreLineEndings):\(normalizeJSON):" +
        filters.map { "\($0.id):\($0.enabled):\($0.pattern):\($0.replacement)" }.joined(separator: "\u{0}")
    }

    private var effectiveSyntaxLanguage: SyntaxLanguage {
        syntaxLanguage == .automatic
            ? SyntaxLanguage.detect(path: sourceComparison.syntaxHint ?? sourceComparison.sources.last?.path)
            : syntaxLanguage
    }

    private var syntaxTheme: SyntaxTheme {
        SyntaxTheme(rawValue: syntaxThemeName) ?? .adaptive
    }

    private var syntaxWithinLimit: Bool {
        sourceComparison.left.originalData.count <= 1_048_576 &&
        sourceComparison.right.originalData.count <= 1_048_576
    }

    private var usesVirtualRows: Bool {
        max(displayed.rows.count, displayed.diff.operations.count) > 2_000
    }

    private var virtualTargetRow: Int? {
        guard displayed.diff.hunks.indices.contains(currentHunk) else { return nil }
        switch layout {
        case .blocks: return displayed.changeRowIDs[currentHunk]
        case .unified: return displayed.changeOperationIDs[currentHunk]
        case .fluid:
            let hunk = displayed.diff.hunks[currentHunk]
            return min(hunk.oldRange.lowerBound, hunk.newRange.lowerBound)
        }
    }

    private func styledLine(_ text: String, side: Side, index: Int) -> Text {
        guard syntaxWithinLimit else { return Text(verbatim: visible(text)) }
        let scopes = side == .left ? leftSyntaxScopes : rightSyntaxScopes
        return SyntaxColoring.text(visible(text), language: effectiveSyntaxLanguage,
                                   theme: syntaxTheme,
                                   scopes: scopes.indices.contains(index) ? scopes[index] : [])
    }

    enum Layout: String, CaseIterable {
        case blocks = "Blocks", fluid = "Fluid", unified = "Unified"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !displayed.extractionNotes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(displayed.extractionNotes, id: \.self) { note in
                        Label(note, systemImage: "text.document")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.35))
            }
            VStack(spacing: 7) {
                HStack {
                    Picker("Layout", selection: $layout) {
                        ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                    Spacer()
                    TextField("Find", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .accessibilityLabel("Find in comparison")
                    if !comparison.sources.isEmpty {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await refreshSources(force: true) }
                        }
                        .labelStyle(.iconOnly)
                        .help("Refresh source files")
                        Button(liveUpdatesPaused ? "Resume Live Updates" : "Pause Live Updates",
                               systemImage: liveUpdatesPaused ? "play.fill" : "pause.fill") {
                            liveUpdatesPaused.toggle()
                            if !liveUpdatesPaused { Task { await refreshSources(force: false) } }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                HStack(spacing: 14) {
                    Toggle("Line Numbers", isOn: $showLineNumbers).toggleStyle(.checkbox)
                    Toggle("Wrap", isOn: $wrapLines)
                        .toggleStyle(.checkbox)
                        .disabled(usesVirtualRows)
                        .help(usesVirtualRows ? "Wrapping for large comparisons is still in development" : "Wrap long lines")
                    Toggle("Invisibles", isOn: $showInvisibles).toggleStyle(.checkbox)
                    Spacer()
                    Menu("Syntax: \(effectiveSyntaxLanguage.rawValue)") {
                        Picker("Language", selection: $syntaxLanguage) {
                            ForEach(SyntaxLanguage.allCases, id: \.self) { language in
                                Text(language.rawValue).tag(language)
                            }
                        }
                        Picker("Theme", selection: Binding(
                            get: { syntaxTheme },
                            set: { syntaxThemeName = $0.rawValue }
                        )) {
                            ForEach(SyntaxTheme.allCases, id: \.self) { theme in
                                Text(theme.rawValue).tag(theme)
                            }
                        }
                        if !syntaxWithinLimit {
                            Divider()
                            Text("Coloring is off above 1 MiB per source")
                        }
                    }
                    if !sourceComparison.sources.isEmpty {
                        Menu("Open Source") {
                            ForEach(Array(sourceComparison.sources.enumerated()), id: \.offset) { index, url in
                                Menu("\(index == 0 ? "A" : "B"): \(url.lastPathComponent)") {
                                    Button("Default App") { openExternal(index: index, app: nil) }
                                    Button("Choose App…") { chooseExternalApp(index: index) }
                                }
                            }
                        }
                    }
                    Menu("Compare Options") {
                        Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                        Toggle("Ignore Line Endings", isOn: $ignoreLineEndings)
                        Toggle("Normalize JSON", isOn: $normalizeJSON)
                        Divider()
                        Button("Text Filters…") { showFilters = true }
                    }
                }
            }
            .padding(10)
            Divider()
            if usesVirtualRows {
                VirtualTextComparisonView(
                    comparison: displayed, layout: layout,
                    showLineNumbers: showLineNumbers, showInvisibles: showInvisibles,
                    syntaxLanguage: effectiveSyntaxLanguage, syntaxTheme: syntaxTheme,
                    colorSyntax: syntaxWithinLimit,
                    leftSyntaxScopes: leftSyntaxScopes, rightSyntaxScopes: rightSyntaxScopes,
                    syntaxVersion: syntaxVersion,
                    search: search, contentVersion: displayedVersion,
                    scrollRequest: scrollRequest, targetRow: virtualTargetRow
                )
                .id(layout)
            } else {
                switch layout {
                case .blocks: alignedView
                case .fluid: continuousView
                case .unified: unifiedView
                }
            }
            Divider()
            HStack {
                Text(displayed.diff.hunks.count == 1
                     ? "1 change" : "\(displayed.diff.hunks.count) changes")
                    .foregroundStyle(.secondary)
                if processing { ProgressView().controlSize(.small) }
                if let range = sourceComparison.gitRange {
                    Button("Previous File", systemImage: "arrow.left") {
                        workspace.navigateGitRange(in: tabID, by: -1)
                    }
                    .disabled(range.index == 0 || workspace.isLoading)
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Text("\(range.index + 1) of \(range.changes.count) files")
                        .foregroundStyle(.secondary)
                    Button("Next File", systemImage: "arrow.right") {
                        workspace.navigateGitRange(in: tabID, by: 1)
                    }
                    .disabled(range.index + 1 >= range.changes.count || workspace.isLoading)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                }
                Spacer()
                Menu("Patch") {
                    Button("Copy Patch") { copyPatch() }
                    Button("Save Patch…") { savePatch() }
                }
                Menu("Print & PDF") {
                    Button("Print Comparison…") { printComparison() }
                    Button("Export PDF…") { savePDF() }
                }
                Button("Resolve…") { showResolution = true }
                    .disabled(!sourceComparison.allowsTextResolution || processing ||
                              ignoreWhitespace || ignoreLineEndings || normalizeJSON ||
                              filters.contains { $0.enabled && !$0.pattern.isEmpty })
                    .help(sourceComparison.allowsTextResolution
                          ? "Choose changes from the original, unfiltered sources"
                          : "Git pointers and binary summaries cannot be resolved as text")
                Button("Previous", systemImage: "chevron.up") {
                    currentHunk = max(0, currentHunk - 1)
                    if usesVirtualRows { scrollRequest = UUID() }
                }
                .disabled(displayed.diff.hunks.isEmpty || currentHunk <= 0)
                Button("Next", systemImage: "chevron.down") {
                    currentHunk = min(displayed.diff.hunks.count - 1, currentHunk + 1)
                    if usesVirtualRows { scrollRequest = UUID() }
                }
                .disabled(displayed.diff.hunks.isEmpty || currentHunk >= displayed.diff.hunks.count - 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .task(id: "\(sourceVersion):\(filterSignature)") { await prepareComparison() }
        .task(id: "\(displayedVersion):\(effectiveSyntaxLanguage.rawValue)") {
            await prepareSyntaxScopes()
        }
        .task { await watchSources() }
        .onChange(of: usesVirtualRows) { _, large in
            if large { wrapLines = false }
        }
        .onDisappear { liveRefreshTask?.cancel() }
        .sheet(isPresented: $showFilters) { filterEditor }
        .sheet(isPresented: $showResolution) {
            TextResolutionView(comparison: sourceComparison) { showResolution = false }
        }
        .alert("Comparison Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var filterEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text Filters").font(.title2.bold())
            Text("Enabled filters run in order on display-only copies of both sources. Patterns use regular expressions. Source files stay unchanged.")
                .foregroundStyle(.secondary)
            List {
                ForEach($filters) { $filter in
                    HStack {
                        Toggle("Enabled", isOn: $filter.enabled).labelsHidden()
                        TextField("Pattern", text: $filter.pattern)
                        TextField("Replacement", text: $filter.replacement)
                        Button("Remove", systemImage: "minus.circle") {
                            filters.removeAll { $0.id == filter.id }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                .onMove { indices, destination in filters.move(fromOffsets: indices, toOffset: destination) }
            }
            HStack {
                Button("Add Filter", systemImage: "plus") {
                    filters.append(TextReplacementFilter(pattern: ""))
                }
                Spacer()
                Button("Done") { showFilters = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 360)
    }

    private func prepareComparison() async {
        guard !Task.isCancelled else { return }
        let active = normalizeJSON || filters.contains { $0.enabled && !$0.pattern.isEmpty }
        if !active && !ignoreWhitespace && !ignoreLineEndings {
            displayed = sourceComparison
            displayedVersion = UUID()
            processing = false
            currentHunk = -1
            return
        }
        processing = true
        let original = sourceComparison
        let preparation = TextPreparationOptions(normalizeJSON: normalizeJSON, filters: filters)
        let diffOptions = DiffOptions(ignoreWhitespace: ignoreWhitespace,
                                      ignoreLineEndings: ignoreLineEndings)
        let worker = Task.detached(priority: .userInitiated) { () throws -> TextComparison in
            let left = active ? try TextPreparation.prepare(original.left, options: preparation) : original.left
            let right = active ? try TextPreparation.prepare(original.right, options: preparation) : original.right
            let diff = try DiffEngine.compare(left.lines, right.lines, options: diffOptions)
            let notes = original.extractionNotes + (active ? ["Filters change this view only; original files remain unchanged."] : [])
            return TextComparison(sources: original.sources, left: left, right: right,
                                  diff: diff, extractionNotes: notes, gitRange: original.gitRange,
                                  syntaxHint: original.syntaxHint,
                                  allowsTextResolution: original.allowsTextResolution)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            displayed = result
            displayedVersion = UUID()
            currentHunk = -1
            processing = false
        } catch {
            guard !Task.isCancelled else { return }
            processing = false
            errorMessage = error.localizedDescription
        }
    }

    private func prepareSyntaxScopes() async {
        guard syntaxWithinLimit, effectiveSyntaxLanguage != .plain else {
            leftSyntaxScopes = []
            rightSyntaxScopes = []
            syntaxVersion = UUID()
            return
        }
        let left = displayed.left.lines.map(\.content)
        let right = displayed.right.lines.map(\.content)
        let dialect = effectiveSyntaxLanguage.dialect
        let worker = Task.detached(priority: .userInitiated) {
            (SyntaxScanner.scan(left, dialect: dialect), SyntaxScanner.scan(right, dialect: dialect))
        }
        let scopes = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        leftSyntaxScopes = scopes.0
        rightSyntaxScopes = scopes.1
        syntaxVersion = UUID()
    }

    private func watchSources() async {
        let urls = comparison.sources
        guard !urls.isEmpty else { return }
        sourceStamps = urls.map(TextSourceStamp.init)
        let monitor: FileTreeMonitor
        do {
            monitor = try FileTreeMonitor(directories: urls.map { $0.deletingLastPathComponent() })
        } catch {
            errorMessage = "Live text updates are unavailable: \(error.localizedDescription)"
            return
        }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        await withTaskCancellationHandler {
            for await events in monitor.events {
                guard !Task.isCancelled else { break }
                guard !liveUpdatesPaused else { continue }
                guard events.isEmpty || events.contains(where: { paths.contains($0) || parents.contains($0) }) else {
                    continue
                }
                liveRefreshTask?.cancel()
                liveRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await refreshSources(force: false)
                }
            }
        } onCancel: {
            monitor.stop()
        }
        liveRefreshTask?.cancel()
        monitor.stop()
    }

    private func refreshSources(force: Bool) async {
        let urls = comparison.sources
        guard !urls.isEmpty else { return }
        let stamps = urls.map(TextSourceStamp.init)
        guard force || stamps != sourceStamps else { return }
        processing = true
        do {
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try TextComparison.load(sources: urls)
            }.value
            guard !Task.isCancelled else { return }
            sourceStamps = stamps
            sourceComparison = refreshed
            sourceVersion = UUID()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Unable to refresh the comparison: \(error.localizedDescription)"
        }
        processing = false
    }

    private func patchText() -> String {
        UnifiedPatch.generate(
            oldLabel: displayed.sources.first?.lastPathComponent ?? "before",
            newLabel: displayed.sources.dropFirst().first?.lastPathComponent ?? "after",
            old: displayed.left.lines,
            new: displayed.right.lines,
            diff: displayed.diff
        )
    }

    private func copyPatch() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(patchText(), forType: .string)
    }

    private func savePatch() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "comparison.patch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(patchText().utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func printComparison() {
        do { try TextPrintExport.printComparison(displayed) }
        catch { errorMessage = error.localizedDescription }
    }

    private func savePDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "comparison.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TextPrintExport.exportPDF(displayed, to: url) }
        catch { errorMessage = error.localizedDescription }
    }

    private func chooseExternalApp(index: Int) {
        let panel = NSOpenPanel()
        panel.message = "Choose an app to open this source file"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        openExternal(index: index, app: appURL)
    }

    private func openExternal(index: Int, app: URL?) {
        guard sourceComparison.sources.indices.contains(index) else { return }
        let url = sourceComparison.sources[index]
        Task {
            do {
                if let app {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app,
                                                          configuration: .init())
                } else {
                    _ = try await NSWorkspace.shared.open(url, configuration: .init())
                }
            } catch {
                errorMessage = "Unable to open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private enum Side { case left, right }

    /// A single vertical scroller keeps rows aligned. Each fixed-width pane has
    /// its own horizontal scroller when wrapping is off.
    private var alignedView: some View {
        GeometryReader { geometry in
            let paneWidth = max(320, (geometry.size.width - 1) / 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    if wrapLines {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(displayed.rows) { row in
                                let words = wordDifference(for: row)
                                HStack(alignment: .top, spacing: 0) {
                                    lineCell(index: row.oldIndex, side: .left, changed: row.isChanged,
                                             segments: words?.old, width: paneWidth)
                                    Divider()
                                    lineCell(index: row.newIndex, side: .right, changed: row.isChanged,
                                             segments: words?.new, width: paneWidth)
                                }
                                .id(row.id)
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            horizontalAlignedPane(side: .left, paneWidth: paneWidth,
                                                  contentWidth: max(paneWidth, displayed.leftContentWidth))
                            Divider()
                            horizontalAlignedPane(side: .right, paneWidth: paneWidth,
                                                  contentWidth: max(paneWidth, displayed.rightContentWidth))
                        }
                    }
                }
                .onChange(of: currentHunk) { _, value in
                    guard displayed.changeRowIDs.indices.contains(value) else { return }
                    withAnimation { proxy.scrollTo(displayed.changeRowIDs[value], anchor: .center) }
                }
            }
        }
    }

    private func horizontalAlignedPane(side: Side, paneWidth: CGFloat, contentWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(displayed.rows) { row in
                    let words = wordDifference(for: row)
                    lineCell(index: side == .left ? row.oldIndex : row.newIndex,
                             side: side, changed: row.isChanged,
                             segments: side == .left ? words?.old : words?.new,
                             width: contentWidth)
                        .frame(height: 22, alignment: .top)
                        .id(side == .left ? row.id : -row.id - 1)
                }
            }
        }
        .frame(width: paneWidth)
        .clipped()
    }

    private func wordDifference(for row: DiffDisplayRow) -> WordDifference? {
        guard let old = row.oldIndex, let new = row.newIndex, row.isChanged else { return nil }
        return WordDiff.compare(displayed.left.lines[old].content, displayed.right.lines[new].content)
    }

    /// Continuous panes preserve their original line spacing.
    private var continuousView: some View {
        GeometryReader { geometry in
            let paneWidth = max(320, (geometry.size.width - 1) / 2)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView(.horizontal) {
                        continuousPane(lines: displayed.left.lines, side: .left,
                                       width: wrapLines ? paneWidth : max(paneWidth, displayed.leftContentWidth))
                    }.frame(width: paneWidth).clipped()
                    Divider()
                    ScrollView(.horizontal) {
                        continuousPane(lines: displayed.right.lines, side: .right,
                                       width: wrapLines ? paneWidth : max(paneWidth, displayed.rightContentWidth))
                    }.frame(width: paneWidth).clipped()
                }
            }
        }
    }

    private func continuousPane(lines: [TextLine], side: Side, width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                lineCell(index: index, side: side, changed: isChanged(index: index, side: side),
                         segments: nil, width: width)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var unifiedView: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayed.diff.operations.indices, id: \.self) { index in
                        let operation = displayed.diff.operations[index]
                        let (marker, line, side, sourceIndex, color): (String, TextLine, Side, Int, Color) = switch operation {
                        case .equal(let old, _): (" ", displayed.left.lines[old], .left, old, .clear)
                        case .delete(let old): ("−", displayed.left.lines[old], .left, old, .red.opacity(0.12))
                        case .insert(let new): ("+", displayed.right.lines[new], .right, new, .green.opacity(0.12))
                        }
                        Text("\(Text(verbatim: marker + " "))\(styledLine(line.content, side: side, index: sourceIndex))")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(wrapLines ? nil : 1)
                            .fixedSize(horizontal: !wrapLines, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 12)
                            .background(color)
                            .id(index)
                    }
                }
                .frame(minWidth: 900, maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentHunk) { _, value in
                guard displayed.changeOperationIDs.indices.contains(value) else { return }
                withAnimation { proxy.scrollTo(displayed.changeOperationIDs[value], anchor: .center) }
            }
        }
    }

    private func lineCell(index: Int?, side: Side, changed: Bool,
                          segments: [WordSegment]?, width: CGFloat) -> some View {
        let lines = side == .left ? displayed.left.lines : displayed.right.lines
        let color: Color = side == .left ? .red.opacity(0.12) : .green.opacity(0.12)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if showLineNumbers {
                Text(index.map { String($0 + 1) } ?? " ")
                    .frame(width: 54, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            }
            if let index {
                (segments.map { wordText($0, side: side) } ??
                    styledLine(lines[index].content.isEmpty ? " " : lines[index].content,
                               side: side, index: index))
                    .textSelection(.enabled)
                    .lineLimit(wrapLines ? nil : 1)
                    .fixedSize(horizontal: false, vertical: wrapLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(" ").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .frame(width: width, alignment: .leading)
        .background(index.map { searchMatches(lines[$0]) ? Color.yellow.opacity(0.22) : changed ? color : .clear } ?? .clear)
        .clipped()
    }

    private func wordText(_ segments: [WordSegment], side: Side) -> Text {
        var value = AttributedString()
        for segment in segments {
            var piece = AttributedString(visible(segment.text))
            piece.foregroundColor = segment.changed ? (side == .left ? .red : .green) : .primary
            value += piece
        }
        return Text(value)
    }

    private func isChanged(index: Int, side: Side) -> Bool {
        let hunks = displayed.diff.hunks
        var lower = 0
        var upper = hunks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = side == .left ? hunks[middle].oldRange : hunks[middle].newRange
            if range.lowerBound <= index { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return false }
        let range = side == .left ? hunks[lower - 1].oldRange : hunks[lower - 1].newRange
        return range.contains(index)
    }

    private func searchMatches(_ line: TextLine) -> Bool {
        !search.isEmpty && line.content.localizedCaseInsensitiveContains(search)
    }

    private func visible(_ text: String) -> String {
        guard showInvisibles else { return text }
        return text.replacingOccurrences(of: " ", with: "·")
            .replacingOccurrences(of: "\t", with: "→")
    }
}

private struct TextSourceStamp: Equatable {
    let modified: Date?
    let size: UInt64?
    let fileNumber: UInt64?

    init(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        modified = attributes?[.modificationDate] as? Date
        size = (attributes?[.size] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
