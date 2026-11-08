import FolderCore
import QuickLook
import SwiftUI

struct FolderComparisonView: View {
    let session: FolderComparisonSession
    let workspace: WorkspaceModel
    @State private var entries: [FolderDifference]
    @State private var selectedPaths: Set<String> = []
    @State private var collapsedPaths: Set<String> = []
    @State private var query = ""
    @State private var showEqual = false
    @State private var includeHidden = false
    @State private var ignoredNames = ".DS_Store"
    @State private var ignoredPatterns = ""
    @State private var stateFilter: StateFilter = .all
    @State private var sourceIsLeft = true
    @State private var plan: FolderOperationPlan?
    @State private var showPreview = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var lastRecovery: URL?
    @State private var previewURL: URL?
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var liveUpdatesPaused = false

    private enum StateFilter: String, CaseIterable {
        case all = "All", different = "Changed", left = "Only A", right = "Only B"
    }

    init(session: FolderComparisonSession, workspace: WorkspaceModel) {
        self.session = session
        self.workspace = workspace
        _entries = State(initialValue: session.entries)
    }

    private var filtered: [FolderDifference] {
        entries.filter { entry in
            (showEqual || entry.state != .equal) &&
            (query.isEmpty || entry.relativePath.localizedCaseInsensitiveContains(query)) &&
            matchesState(entry) &&
            !collapsedPaths.contains(where: { entry.relativePath.hasPrefix($0 + "/") })
        }
    }

    private var options: FolderOptions {
        FolderOptions(includeHidden: includeHidden,
                      ignoredNames: Set(ignoredNames.split(separator: ",").map {
                          $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      }).filter { !$0.isEmpty },
                      ignoredPathPatterns: ignoredPatterns.split(separator: "\n").map(String.init))
    }

    private var filterSignature: String { ignoredNames + "\u{0}" + ignoredPatterns }

    private func matchesState(_ entry: FolderDifference) -> Bool {
        switch stateFilter {
        case .all: true
        case .different: entry.state == .different
        case .left: entry.state == .onlyLeft
        case .right: entry.state == .onlyRight
        }
    }

    private func hasSource(_ entry: FolderDifference) -> Bool {
        sourceIsLeft ? entry.state != .onlyRight : entry.state != .onlyLeft
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(entries.filter { $0.state != .equal }.count) differences")
                    .font(.headline)
                Spacer()
                Picker("Direction", selection: $sourceIsLeft) {
                    Text("A → B").tag(true)
                    Text("B → A").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Button("Preview Copy Selected") { prepare(.copy) }
                    .disabled(selectedPaths.isEmpty || isBusy)
                Button("Preview Clone") { prepare(.clone) }
                    .disabled(isBusy)
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isBusy)
                Button(liveUpdatesPaused ? "Resume Live Updates" : "Pause Live Updates",
                       systemImage: liveUpdatesPaused ? "play.fill" : "pause.fill") {
                    liveUpdatesPaused.toggle()
                    if !liveUpdatesPaused { refresh() }
                }
                Toggle("Show Equal", isOn: $showEqual).toggleStyle(.checkbox)
                TextField("Filter paths", text: $query).frame(width: 220)
            }.padding(12)
            HStack {
                Text("Copy keeps destination-only items. Clone mirrors the scanned scope after review; path and state filters do not narrow the clone.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select Visible Differences") {
                    selectedPaths.formUnion(filtered.filter { $0.state != .equal && hasSource($0) }
                        .map(\.relativePath))
                }
                Button("Clear Selection") { selectedPaths.removeAll() }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            HStack(spacing: 10) {
                Picker("State", selection: $stateFilter) {
                    ForEach(StateFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 180)
                Toggle("Hidden Files", isOn: $includeHidden).toggleStyle(.checkbox)
                TextField("Ignore names (comma separated)", text: $ignoredNames)
                    .frame(width: 220)
                TextField("Ignore path regex (one per line)", text: $ignoredPatterns)
                    .frame(width: 240)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            List(filtered) { entry in
                HStack {
                    Toggle("Select \(entry.relativePath)", isOn: Binding(
                        get: { selectedPaths.contains(entry.relativePath) },
                        set: { enabled in
                            if enabled { selectedPaths.insert(entry.relativePath) }
                            else { selectedPaths.remove(entry.relativePath) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(entry.state == .equal || !hasSource(entry))
                    HStack {
                        if entry.kind == .directory {
                            Button {
                                if !collapsedPaths.insert(entry.relativePath).inserted {
                                    collapsedPaths.remove(entry.relativePath)
                                }
                            } label: {
                                Image(systemName: collapsedPaths.contains(entry.relativePath)
                                      ? "chevron.right" : "chevron.down")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(collapsedPaths.contains(entry.relativePath) ? "Expand" : "Collapse") \(entry.relativePath)")
                        } else {
                            Color.clear.frame(width: 12, height: 12)
                        }
                        Image(systemName: entry.kind == .directory ? "folder" :
                                entry.kind == .symbolicLink ? "link" : "doc")
                        Text(entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .help(entry.relativePath)
                        Spacer()
                        Text(stateName(entry.state)).foregroundStyle(.secondary)
                        if entry.kind == .file, entry.state == .different {
                            Button("Compare") { comparePair(entry.relativePath) }
                                .buttonStyle(.borderless)
                        }
                        Menu("Quick Look") {
                            if entry.state != .onlyRight {
                                Button("Preview A") {
                                    previewURL = session.left.appendingPathComponent(entry.relativePath)
                                }
                            }
                            if entry.state != .onlyLeft {
                                Button("Preview B") {
                                    previewURL = session.right.appendingPathComponent(entry.relativePath)
                                }
                            }
                        }
                    }
                    .padding(.leading, CGFloat(max(0, entry.relativePath.split(separator: "/").count - 1)) * 16)
                }
            }
            if isBusy { ProgressView("Checking folders…").padding(8) }
            if let lastRecovery {
                Text("Previous destination items are recoverable at \(lastRecovery.path)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .sheet(isPresented: $showPreview) {
            if let plan {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review \(plan.mode.rawValue)").font(.title2.bold())
                    Text("From: \(plan.sourceRoot.path)")
                    Text("To: \(plan.destinationRoot.path)")
                    Text("\(plan.actions.count) actions. Replaced or removed destination items are kept in a recovery folder.")
                        .foregroundStyle(.secondary)
                    List(plan.actions) { action in
                        HStack {
                            Text(action.kind.rawValue).frame(width: 120, alignment: .leading)
                            Text(action.path).font(.system(.body, design: .monospaced))
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { showPreview = false }
                        Button("Apply Reviewed Changes", role: .destructive) {
                            showPreview = false
                            apply(plan)
                        }
                        .disabled(plan.actions.isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .frame(minWidth: 720, minHeight: 480)
            }
        }
        .alert("Folder Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .quickLookPreview($previewURL)
        .onChange(of: sourceIsLeft) { _, _ in selectedPaths.removeAll() }
        .onChange(of: includeHidden) { _, _ in refresh() }
        .task(id: filterSignature) {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { refresh() }
        }
        .task { await watchFolders() }
        .onDisappear { liveRefreshTask?.cancel() }
    }

    private func stateName(_ state: FolderState) -> String {
        switch state {
        case .equal: "Equal"
        case .different: "Different"
        case .onlyLeft: "Only A"
        case .onlyRight: "Only B"
        }
    }

    private func comparePair(_ path: String) {
        Task { await workspace.open(urls: [session.left.appendingPathComponent(path),
                                           session.right.appendingPathComponent(path)]) }
    }

    private func refresh() {
        guard !isBusy else { return }
        let currentOptions = options
        isBusy = true
        plan = nil
        Task {
            defer { isBusy = false }
            do {
                let left = session.left
                let right = session.right
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try FolderComparison.compare(left: left, right: right, options: currentOptions)
                }.value
                entries = refreshed
                selectedPaths.formIntersection(Set(refreshed.map(\.relativePath)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func watchFolders() async {
        let monitor: FileTreeMonitor
        do {
            monitor = try FileTreeMonitor(directories: [session.left, session.right])
        } catch {
            errorMessage = "Live folder updates are unavailable: \(error.localizedDescription)"
            return
        }
        await withTaskCancellationHandler {
            for await _ in monitor.events {
                guard !Task.isCancelled else { break }
                guard !liveUpdatesPaused else { continue }
                liveRefreshTask?.cancel()
                liveRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    refresh()
                }
            }
        } onCancel: {
            monitor.stop()
        }
        liveRefreshTask?.cancel()
        monitor.stop()
    }

    private func prepare(_ mode: FolderOperationMode) {
        let source = sourceIsLeft ? session.left : session.right
        let destination = sourceIsLeft ? session.right : session.left
        let selected = selectedPaths
        let currentOptions = options
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    if mode == .clone {
                        try FolderOperationPlan.makeClone(from: source, to: destination,
                                                         options: currentOptions)
                    } else {
                        try FolderOperationPlan.makeCopy(from: source, to: destination,
                                                         selectedPaths: selected,
                                                         options: currentOptions)
                    }
                }.value
                plan = prepared
                showPreview = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ prepared: FolderOperationPlan) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try prepared.apply()
                }.value
                lastRecovery = result.recoveryFolder
                selectedPaths.removeAll()
                let left = session.left
                let right = session.right
                let currentOptions = options
                entries = try await Task.detached(priority: .userInitiated) {
                    try FolderComparison.compare(left: left, right: right, options: currentOptions)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

