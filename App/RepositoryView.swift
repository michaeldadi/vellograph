import GitCore
import SwiftUI

struct RepositoryView: View {
    let repository: GitRepository
    let workspace: WorkspaceModel
    let initialRange: Bool

    @State private var viewMode: ViewMode = .workingCopy
    @State private var status: [GitStatusEntry]
    @State private var branch: String?
    @State private var commits: [GitCommit] = []
    @State private var graphRows: [GitGraphRow] = []
    @State private var refs: [GitRef] = []
    @State private var selectedCommitID: String?
    @State private var changedPaths: [String] = []
    @State private var isLoading = false
    @State private var fromRef = "HEAD~1"
    @State private var toRef = "HEAD"
    @State private var revisionChanges: [GitPathChange] = []
    @State private var resolvedFrom: String?
    @State private var resolvedTo: String?
    @State private var showFileHistory = false
    @State private var fileHistoryPath = ""
    @State private var fileRevisions: [GitFileRevision] = []
    @State private var fileHistoryLoading = false
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var liveUpdatesPaused = false
    @State private var worktrees: [GitWorktree] = []
    @State private var workingSearch = ""
    @State private var revisionSearch = ""
    @State private var workingFilter: WorkingFilter = .all
    @State private var revisionFilter: RevisionFilter = .all
    @State private var listLayout: ListLayout = .flat

    private enum ViewMode: String, CaseIterable {
        case workingCopy = "Working Copy", history = "History", revisions = "Compare Revisions"
    }

    private enum ListLayout: String, CaseIterable {
        case flat = "Flat", outline = "Outline"
    }

    private enum WorkingFilter: String, CaseIterable {
        case all = "All", staged = "Staged", working = "Working", conflicts = "Conflicts"
        case untracked = "Untracked", deleted = "Deleted", renamed = "Renamed"
    }

    private enum RevisionFilter: String, CaseIterable {
        case all = "All", added = "Added", modified = "Modified", deleted = "Deleted"
        case renamed = "Renamed", other = "Other"
    }

    private var filteredStatus: [GitStatusEntry] {
        status.filter { entry in
            guard workingSearch.isEmpty ||
                    entry.path.localizedCaseInsensitiveContains(workingSearch) else { return false }
            switch workingFilter {
            case .all: return true
            case .staged: return !entry.isUntracked && !entry.isUnmerged && entry.indexStatus != "."
            case .working: return !entry.isUntracked && !entry.isUnmerged && entry.worktreeStatus != "."
            case .conflicts: return entry.isUnmerged
            case .untracked: return entry.isUntracked
            case .deleted: return entry.indexStatus == "D" || entry.worktreeStatus == "D"
            case .renamed: return entry.indexStatus == "R" || entry.worktreeStatus == "R"
            }
        }
    }

    private var filteredRevisionChanges: [GitPathChange] {
        revisionChanges.filter { change in
            guard revisionSearch.isEmpty ||
                    change.path.localizedCaseInsensitiveContains(revisionSearch) else { return false }
            let kind = change.status.first
            switch revisionFilter {
            case .all: return true
            case .added: return kind == "A"
            case .modified: return kind == "M"
            case .deleted: return kind == "D"
            case .renamed: return kind == "R"
            case .other: return kind.map { !"AMDR".contains($0) } ?? true
            }
        }
    }

    private var graphLaneSpacing: CGFloat {
        let maximum = max(graphRows.map(\.laneCount).max() ?? 1, 1)
        return min(15, 210 / CGFloat(maximum))
    }

    private var graphWidth: CGFloat {
        let maximum = max(graphRows.map(\.laneCount).max() ?? 1, 1)
        return CGFloat(maximum) * graphLaneSpacing + 12
    }

    init(session: RepositoryComparison, workspace: WorkspaceModel) {
        self.repository = session.repository
        self.workspace = workspace
        initialRange = session.fromRef != nil && session.toRef != nil
        _viewMode = State(initialValue: initialRange ? .revisions :
                          session.startInHistory ? .history : .workingCopy)
        _status = State(initialValue: session.repository.status)
        _branch = State(initialValue: session.repository.branch)
        _fromRef = State(initialValue: session.fromRef ?? "HEAD~1")
        _toRef = State(initialValue: session.toRef ?? "HEAD")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repository.root.lastPathComponent).font(.title2.bold())
                        Text(branch ?? "Detached HEAD").foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                    Picker("Repository View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 410)
                }
                HStack(spacing: 10) {
                    Menu("Worktrees", systemImage: "square.stack.3d.up") {
                        if worktrees.isEmpty {
                            Button("No worktrees found") {}.disabled(true)
                        }
                        ForEach(worktrees) { tree in
                            Button {
                                Task { await workspace.open(urls: [tree.root]) }
                            } label: {
                                Label(tree.root.lastPathComponent,
                                      systemImage: tree.isDetached ? "point.3.connected.trianglepath.dotted" : "arrow.triangle.branch")
                            }
                            .help("\(tree.branch ?? (tree.isDetached ? "Detached HEAD" : "Bare")) · \(tree.root.path)")
                        }
                        if let current = worktrees.first(where: {
                            $0.root.standardizedFileURL == repository.root.standardizedFileURL
                        }) {
                            let others = worktrees.filter { $0.root != current.root }
                            if !others.isEmpty {
                                Divider()
                                Menu("Compare Committed HEADs") {
                                    ForEach(others) { tree in
                                        Button(tree.root.lastPathComponent) {
                                            workspace.openWorktreeHeads(from: current, to: tree,
                                                                        in: repository)
                                        }
                                        .disabled(current.head == nil || tree.head == nil)
                                    }
                                }
                                Menu("Compare Working Files") {
                                    ForEach(others) { tree in
                                        Button(tree.root.lastPathComponent) {
                                            Task { await workspace.open(urls: [current.root, tree.root]) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refresh() }
                    }
                    Button(liveUpdatesPaused ? "Resume" : "Pause",
                           systemImage: liveUpdatesPaused ? "play.fill" : "pause.fill") {
                        liveUpdatesPaused.toggle()
                        if !liveUpdatesPaused { Task { await refresh() } }
                    }
                    .help(liveUpdatesPaused ? "Resume live Git updates" : "Pause live Git updates")
                    Spacer()
                }
            }
            .padding()
            Divider()
            switch viewMode {
            case .workingCopy: workingCopyView
            case .history: historyView
            case .revisions: revisionView
            }
        }
        .task { await loadHistory() }
        .task { await loadWorktrees() }
        .task { if initialRange { await compareRevisions() } }
        .task { await watchRepository() }
        .onDisappear { liveRefreshTask?.cancel() }
        .sheet(isPresented: $showFileHistory) { fileHistorySheet }
    }

    private var workingCopyView: some View {
        let entries = filteredStatus
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(spacing: 0) {
            HStack {
                Text("\(entries.count) of \(status.count) changed items").font(.headline)
                Spacer()
                Text("Compare staged or working-copy changes")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            changeControls(search: $workingSearch) {
                Picker("Status", selection: $workingFilter) {
                    ForEach(WorkingFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            List {
                if listLayout == .flat {
                    ForEach(entries) { entry in workingRow(entry, label: entry.path) }
                } else {
                    OutlineGroup(GitPathTree.build(paths: entries.map(\.path)),
                                 children: \.children) { node in
                        if let entry = byPath[node.path] {
                            workingRow(entry, label: node.name)
                        } else {
                            Label(node.name, systemImage: "folder")
                        }
                    }
                }
            }
        }
    }

    private func workingRow(_ entry: GitStatusEntry, label: String) -> some View {
        HStack {
            Text(String(entry.indexStatus) + String(entry.worktreeStatus))
                .font(.system(.body, design: .monospaced))
                .frame(width: 35)
            Text(label).font(.system(.body, design: .monospaced))
            Spacer()
            if entry.isPartiallyStaged { Text("Partial").foregroundStyle(.secondary) }
            if entry.isUnmerged {
                Button("Resolve Conflict") { workspace.openGitConflict(entry, in: repository) }
            } else if entry.indexStatus != ".", !entry.isUntracked {
                Button("Staged") { workspace.openWorkingCopyFile(entry, staged: true, in: repository) }
            }
            if !entry.isUnmerged && (entry.worktreeStatus != "." || entry.isUntracked) {
                Button(entry.isUntracked ? "Untracked" : "Working") {
                    workspace.openWorkingCopyFile(entry, staged: false, in: repository)
                }
            }
            if !entry.isUntracked {
                Button("History") { openFileHistory(entry.originalPath ?? entry.path, at: "HEAD") }
            }
        }
        .help(entry.path)
    }

    private func changeControls<Filter: View>(search: Binding<String>,
                                              @ViewBuilder filter: () -> Filter) -> some View {
        HStack(spacing: 10) {
            TextField("Filter paths", text: search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Filter change paths")
            filter()
                .frame(width: 125)
            Picker("Layout", selection: $listLayout) {
                ForEach(ListLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 165)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var historyView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Commits").font(.headline).padding(12)
                Divider()
                if isLoading && commits.isEmpty {
                    ProgressView("Loading history…").padding()
                } else if commits.isEmpty {
                    ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
                } else {
                    List(Array(commits.enumerated()), id: \.element.id) { index, commit in
                        Button { selectedCommitID = commit.id } label: {
                            HStack(spacing: 8) {
                                if graphRows.indices.contains(index) {
                                    GitCommitGraphView(row: graphRows[index],
                                                       width: graphWidth,
                                                       laneSpacing: graphLaneSpacing)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(commit.subject).lineLimit(2)
                                    HStack {
                                        Text(String(commit.id.prefix(8)))
                                            .font(.system(.caption, design: .monospaced))
                                        Text(commit.timestamp, style: .date)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    let labels = refs.filter { $0.commitID == commit.id }
                                    if !labels.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(labels) { ref in
                                                Text(ref.displayName)
                                                    .font(.caption2)
                                                    .lineLimit(1)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(ref.kind == .tag ? Color.orange.opacity(0.18) :
                                                                    Color.accentColor.opacity(0.14),
                                                                in: RoundedRectangle(cornerRadius: 4))
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(5)
                            .background(selectedCommitID == commit.id ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Commit \(commit.subject), \(commit.id.prefix(8))")
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 420, maxWidth: 560)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if let commit = commits.first(where: { $0.id == selectedCommitID }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(commit.subject).font(.headline)
                        Text(commit.id).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(changedPaths.count) changed files")
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    Divider()
                    List(changedPaths, id: \.self) { path in
                        HStack {
                            Button { workspace.openGitFile(path, from: commit, in: repository) } label: {
                                Label(path, systemImage: "doc.text.magnifyingglass")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button("File History") { openFileHistory(path, at: commit.id) }
                        }
                        .help("Compare with its version in the first parent commit")
                    }
                } else {
                    ContentUnavailableView("Select a Commit", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: selectedCommitID) { await loadChangedPaths() }
    }

    private var fileHistorySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File History · \(fileHistoryPath)").font(.title2.bold())
            Text("Follow renames and open a commit's file against its first parent.")
                .foregroundStyle(.secondary)
            if fileHistoryLoading {
                ProgressView("Loading file history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileRevisions.isEmpty {
                ContentUnavailableView("No File History", systemImage: "clock.arrow.circlepath")
            } else {
                List(fileRevisions) { revision in
                    Button {
                        showFileHistory = false
                        workspace.openGitFileRevision(revision, in: repository)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(revision.commit.subject)
                            HStack {
                                Text(String(revision.commit.id.prefix(8)))
                                Text(revision.commit.timestamp, style: .date)
                                if revision.path != revision.parentPath {
                                    Text("Renamed from \(revision.parentPath)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Done") { showFileHistory = false }
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 480)
    }

    private func openFileHistory(_ path: String, at ref: String) {
        fileHistoryPath = path
        fileRevisions = []
        showFileHistory = true
        fileHistoryLoading = true
        let root = repository.root
        Task {
            defer { fileHistoryLoading = false }
            do {
                fileRevisions = try await Task.detached(priority: .userInitiated) {
                    try GitClient().fileRevisions(in: root, path: path, at: ref)
                }.value
            } catch {
                workspace.errorMessage = "Unable to load file history: \(error.localizedDescription)"
            }
        }
    }

    private var revisionView: some View {
        let entries = filteredRevisionChanges
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                TextField("From branch, tag, or commit", text: $fromRef)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .accessibilityLabel("From revision")
                refMenu("From…") { fromRef = $0.name }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("To branch, tag, or commit", text: $toRef)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .accessibilityLabel("To revision")
                refMenu("To…") { toRef = $0.name }
                Button("Compare Revisions") { Task { await compareRevisions() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || fromRef.isEmpty || toRef.isEmpty)
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(12)
            Text("Compare two commits, branches, or tags. Renamed files retain their original path for the before side.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            Divider().padding(.top, 8)
            if let resolvedFrom, let resolvedTo {
                Text("\(entries.count) of \(revisionChanges.count) changes · \(resolvedFrom.prefix(8)) → \(resolvedTo.prefix(8))")
                    .font(.headline)
                    .padding(12)
                changeControls(search: $revisionSearch) {
                    Picker("Kind", selection: $revisionFilter) {
                        ForEach(RevisionFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                List {
                    if listLayout == .flat {
                        ForEach(entries) { change in
                            revisionRow(change, label: change.path, from: resolvedFrom, to: resolvedTo,
                                        changes: entries)
                        }
                    } else {
                        OutlineGroup(GitPathTree.build(paths: entries.map(\.path)),
                                     children: \.children) { node in
                            if let change = byPath[node.path] {
                                revisionRow(change, label: node.name, from: resolvedFrom, to: resolvedTo,
                                            changes: entries)
                            } else {
                                Label(node.name, systemImage: "folder")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Choose two revisions", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private func revisionRow(_ change: GitPathChange, label: String,
                             from: String, to: String, changes: [GitPathChange]) -> some View {
        Button {
            guard let index = changes.firstIndex(where: { $0.path == change.path }) else { return }
            let navigation = GitRangeNavigation(repositoryRoot: repository.root, fromID: from,
                                                toID: to, changes: changes, index: index)
            workspace.openGitRangeFile(change, from: from, to: to, in: repository.root,
                                       navigation: navigation)
        } label: {
            HStack {
                Text(change.status)
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 44, alignment: .leading)
                Text(label).font(.system(.body, design: .monospaced))
                if let original = change.originalPath {
                    Text("from \(original)").foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .help(change.path)
    }

    private func refMenu(_ title: String, choose: @escaping (GitRef) -> Void) -> some View {
        Menu(title) {
            ForEach([GitRef.Kind.branch, .remote, .tag], id: \.self) { kind in
                let available = refs.filter { $0.kind == kind }
                if !available.isEmpty {
                    Section(kind == .branch ? "Branches" : kind == .remote ? "Remotes" : "Tags") {
                        ForEach(available) { ref in
                            Button(ref.displayName) { choose(ref) }
                        }
                    }
                }
            }
        }
        .disabled(refs.isEmpty)
    }

    private func compareRevisions() async {
        let root = repository.root
        let from = fromRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = toRef.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> (String, String, [GitPathChange]) in
                let git = GitClient()
                let left = try git.resolveCommit(in: root, ref: from)
                let right = try git.resolveCommit(in: root, ref: to)
                return (left, right, try git.changes(in: root, from: left, to: right))
            }.value
            resolvedFrom = result.0
            resolvedTo = result.1
            revisionChanges = result.2
        } catch {
            resolvedFrom = nil
            resolvedTo = nil
            revisionChanges = []
            workspace.errorMessage = "Unable to compare Git revisions: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        await refresh(reloadHistory: true)
    }

    private func refresh(reloadHistory: Bool) async {
        let root = repository.root
        do {
            let current = try await Task.detached(priority: .userInitiated) {
                try GitClient().repository(at: root)
            }.value
            guard !Task.isCancelled else { return }
            status = current.status
            branch = current.branch
            if reloadHistory {
                await loadHistory()
                await loadWorktrees()
            }
        } catch {
            workspace.errorMessage = "Unable to refresh Git status: \(error.localizedDescription)"
        }
    }

    private func watchRepository() async {
        let monitor: FileTreeMonitor
        do {
            monitor = try FileTreeMonitor(directories: [repository.root, repository.gitDirectory])
        } catch {
            workspace.errorMessage = "Live Git updates are unavailable: \(error.localizedDescription)"
            return
        }
        let gitPath = repository.gitDirectory.standardizedFileURL.path
        await withTaskCancellationHandler {
            for await paths in monitor.events {
                guard !Task.isCancelled else { break }
                guard !liveUpdatesPaused else { continue }
                let metadataChanged = paths.isEmpty || paths.contains {
                    $0 == gitPath || $0.hasPrefix(gitPath + "/")
                }
                liveRefreshTask?.cancel()
                liveRefreshTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await refresh(reloadHistory: metadataChanged)
                }
            }
        } onCancel: {
            monitor.stop()
        }
        liveRefreshTask?.cancel()
        monitor.stop()
    }

    private func loadHistory() async {
        let root = repository.root
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let git = GitClient()
                return (try git.commitHistory(in: root), try git.refs(in: root))
            }.value
            commits = result.0
            graphRows = GitHistoryGraph.rows(for: result.0)
            refs = result.1
            if selectedCommitID == nil { selectedCommitID = commits.first?.id }
        } catch {
            workspace.errorMessage = "Unable to load Git history: \(error.localizedDescription)"
        }
    }

    private func loadWorktrees() async {
        let root = repository.root
        do {
            worktrees = try await Task.detached(priority: .userInitiated) {
                try GitClient().worktrees(in: root)
            }.value
        } catch {
            workspace.errorMessage = "Unable to list Git worktrees: \(error.localizedDescription)"
        }
    }

    private func loadChangedPaths() async {
        guard let commit = commits.first(where: { $0.id == selectedCommitID }) else { return }
        let root = repository.root
        changedPaths = []
        do {
            let paths = try await Task.detached(priority: .userInitiated) {
                try GitClient().changedPaths(in: root, for: commit)
            }.value
            if selectedCommitID == commit.id { changedPaths = paths }
        } catch {
            workspace.errorMessage = "Unable to load commit changes: \(error.localizedDescription)"
        }
    }
}

private struct GitCommitGraphView: View {
    let row: GitGraphRow
    let width: CGFloat
    let laneSpacing: CGFloat

    var body: some View {
        Canvas { context, size in
            let x: (Int) -> CGFloat = { 7 + CGFloat($0) * laneSpacing }
            for segment in row.segments {
                var path = Path()
                path.move(to: CGPoint(x: x(segment.fromLane),
                                      y: size.height * segment.fromRowFraction))
                path.addLine(to: CGPoint(x: x(segment.toLane),
                                         y: size.height * segment.toRowFraction))
                context.stroke(path, with: .color(.accentColor.opacity(0.62)), lineWidth: 1.5)
            }
            let node = CGRect(x: x(row.nodeLane) - 4, y: size.height / 2 - 4,
                              width: 8, height: 8)
            context.fill(Path(ellipseIn: node), with: .color(.accentColor))
        }
        .frame(width: width, height: 42)
        .accessibilityHidden(true)
    }
}

