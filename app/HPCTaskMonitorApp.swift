import AppKit
import Foundation
import SwiftUI


struct Job: Codable, Identifiable, Hashable {
    var id: String { jobID }

    let jobID: String
    let jobName: String
    let status: String
    let statusKey: String
    let filters: [String]
    let stateSummary: String
    let stateCode: String
    let priority: String
    let user: String
    let submitOrStart: String
    let runWait: String
    let purpose: String
    let project: String
    let projectPath: String
    let inputPath: String
    let outputPath: String
    let scriptPath: String
    let workDir: String
    let stdout: String
    let stderr: String
    let notes: String
    let elapsed: String
    let timeLimit: String
    let partition: String
    let qos: String
    let reason: String
    let exitCode: String
    let submit: String
    let start: String
    let end: String
    let nodeList: String
    let nodes: String
    let slots: String
    let gpu: String
    let memory: String
    let arrayTasks: String
    let nodeOrReason: String
    let reqTres: String
    let allocTres: String
    let memberCount: Int

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case jobName = "job_name"
        case status
        case statusKey = "status_key"
        case filters
        case stateSummary = "state_summary"
        case stateCode = "state_code"
        case priority
        case user
        case submitOrStart = "submit_or_start"
        case runWait = "run_wait"
        case purpose
        case project
        case projectPath = "project_path"
        case inputPath = "input_path"
        case outputPath = "output_path"
        case scriptPath = "script_path"
        case workDir = "work_dir"
        case stdout
        case stderr
        case notes
        case elapsed
        case timeLimit = "time_limit"
        case partition
        case qos
        case reason
        case exitCode = "exit_code"
        case submit
        case start
        case end
        case nodeList = "node_list"
        case nodes
        case slots
        case gpu
        case memory
        case arrayTasks = "array_tasks"
        case nodeOrReason = "node_or_reason"
        case reqTres = "req_tres"
        case allocTres = "alloc_tres"
        case memberCount = "member_count"
    }

    var displaySubmit: String { submit.replacingOccurrences(of: "T", with: " ") }
    var displaySubmitOrStart: String { submitOrStart.replacingOccurrences(of: "T", with: " ") }

    var displayStatus: String {
        switch statusKey {
        case "running": return "Running"
        case "pending": return "Pending"
        case "success": return "Success"
        case "error": return "Error"
        case "cancelled": return "Cancelled"
        case "ended": return "Ended"
        default: return "Unknown"
        }
    }

    var displayPurpose: String { translatedPlaceholder(purpose) }
    var displayInputPath: String { translatedPlaceholder(inputPath) }
    var displayOutputPath: String { translatedPlaceholder(outputPath) }
    var displayScriptPath: String { translatedPlaceholder(scriptPath) }
    var displayWorkDir: String { translatedPlaceholder(workDir) }
    var queueQOS: String { "\(partition) / \(qos)" }
    var resourceSummary: String { "N\(nodes) C\(slots) G\(gpu) \(memory)" }
    var arrayNodeReason: String {
        let array = arrayTasks == "-" ? "" : "A:\(arrayTasks)  "
        return array + nodeOrReason
    }

    private func translatedPlaceholder(_ value: String) -> String {
        if value.hasPrefix("未登记") { return "Unregistered" }
        if value.hasPrefix("未记录") { return "Not recorded" }
        if value.hasPrefix("Slurm 当前查询未提供") { return "Not available from Slurm" }
        return value
    }
}


struct DashboardPayload: Codable {
    let fetchedAt: String
    let generatedAt: String
    let days: Int
    let jobs: [Job]

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case generatedAt = "generated_at"
        case days
        case jobs
    }
}


enum StatusFilter: String, CaseIterable, Identifiable {
    case all, running, pending, ended, success, error, cancelled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Jobs"
        case .running: return "Running"
        case .pending: return "Pending"
        case .ended: return "Ended"
        case .success: return "Success"
        case .error: return "Error"
        case .cancelled: return "Cancelled"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .running: return "play.circle.fill"
        case .pending: return "clock.fill"
        case .ended: return "flag.checkered"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }
}


enum TableMode: String, CaseIterable, Identifiable {
    case overview, scheduler

    var id: String { rawValue }
    var title: String { self == .overview ? "Overview" : "Scheduler" }
}


struct TagColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let defaultBlue = TagColor(red: 0.20, green: 0.48, blue: 0.95)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        red = Double(value.redComponent)
        green = Double(value.greenComponent)
        blue = Double(value.blueComponent)
    }

    var swiftUIColor: Color { Color(red: red, green: green, blue: blue) }
}


struct TaskTag: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: TagColor
}


struct JobAnnotation: Codable, Hashable {
    var isFocused = false
    var tagIDs: [UUID] = []
    var note: String?
}


enum SidebarSelection: Hashable {
    case status(StatusFilter)
    case focus
    case tag(UUID)
}


final class MonitorStore: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var fetchedAt = "Not refreshed"
    @Published var days = 14
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var settings: ConnectionSettings
    @Published var tags: [TaskTag] = []
    @Published private var annotations: [String: JobAnnotation] = [:]

    let rootURL: URL
    private var didInitialRefresh = false
    private let settingsKey = "connectionSettings.v2"

    init() {
        rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HPC Task Monitor", isDirectory: true)
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            settings = saved
            days = saved.historyDays
        } else {
            settings = ConnectionSettings()
        }
        try? ensureStorage()
        loadAnnotations()
        loadSnapshot()
    }

    var metadataURL: URL { rootURL.appendingPathComponent("job_metadata.tsv") }
    private var snapshotURL: URL { rootURL.appendingPathComponent("jobs.json") }
    private var tagsURL: URL { rootURL.appendingPathComponent("task_tags.json") }
    private var annotationsURL: URL { rootURL.appendingPathComponent("job_annotations.json") }
    var hasValidSettings: Bool { settings.isComplete }

    func initialRefresh() {
        guard !didInitialRefresh else { return }
        didInitialRefresh = true
        refresh()
    }

    func count(for filter: StatusFilter) -> Int {
        if filter == .all { return jobs.count }
        return jobs.filter { $0.filters.contains(filter.rawValue) }.count
    }

    func refresh() {
        guard !isRefreshing else { return }
        guard settings.isComplete else {
            errorMessage = "Open Connection Settings before refreshing."
            return
        }
        isRefreshing = true
        errorMessage = nil
        let activeSettings = settings

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try SlurmBackend.fetch(settings: activeSettings, metadataURL: self.metadataURL)
                try self.appendMissingMetadataRows(for: payload.jobs)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(payload).write(to: self.snapshotURL, options: .atomic)
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.jobs = payload.jobs
                    self.fetchedAt = payload.fetchedAt
                    self.days = payload.days
                    self.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func saveSettings(_ newSettings: ConnectionSettings) {
        settings = newSettings
        days = newSettings.historyDays
        if let data = try? JSONEncoder().encode(newSettings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    func loadSnapshot() {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        do {
            let payload = try JSONDecoder().decode(DashboardPayload.self, from: Data(contentsOf: snapshotURL))
            jobs = payload.jobs
            fetchedAt = payload.fetchedAt
            days = payload.days
            errorMessage = nil
        } catch {
            errorMessage = "Could not read the local job snapshot: \(error.localizedDescription)"
        }
    }

    func openMetadata() {
        try? ensureStorage()
        NSWorkspace.shared.open(metadataURL)
    }

    func annotation(for jobID: String) -> JobAnnotation {
        annotations[jobID] ?? JobAnnotation()
    }

    func note(for job: Job) -> String {
        annotation(for: job.jobID).note ?? job.notes
    }

    func isFocused(_ job: Job) -> Bool {
        annotation(for: job.jobID).isFocused
    }

    func tags(for job: Job) -> [TaskTag] {
        let ids = Set(annotation(for: job.jobID).tagIDs)
        return tags.filter { ids.contains($0.id) }
    }

    func toggleFocus(_ job: Job, enabled: Bool) {
        updateAnnotation(job.jobID) { $0.isFocused = enabled }
    }

    func setTags(_ tagIDs: [UUID], for job: Job) {
        updateAnnotation(job.jobID) { $0.tagIDs = tagIDs }
    }

    func setNote(_ note: String, for job: Job) {
        updateAnnotation(job.jobID) { $0.note = note }
    }

    func addTag(name: String, color: TagColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tags.append(TaskTag(name: trimmed, color: color))
        saveAnnotations()
    }

    func deleteTags(at offsets: IndexSet) {
        let deleted = Set(offsets.map { tags[$0].id })
        tags.remove(atOffsets: offsets)
        for jobID in annotations.keys {
            annotations[jobID]?.tagIDs.removeAll { deleted.contains($0) }
        }
        saveAnnotations()
    }

    func saveAnnotations() {
        do {
            try ensureStorage()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(tags).write(to: tagsURL, options: .atomic)
            try encoder.encode(annotations).write(to: annotationsURL, options: .atomic)
        } catch {
            errorMessage = "Could not save local task annotations: \(error.localizedDescription)"
        }
    }

    private func updateAnnotation(_ jobID: String, update: (inout JobAnnotation) -> Void) {
        var value = annotation(for: jobID)
        update(&value)
        annotations[jobID] = value
        saveAnnotations()
    }

    private func loadAnnotations() {
        if let data = try? Data(contentsOf: tagsURL), let saved = try? JSONDecoder().decode([TaskTag].self, from: data) {
            tags = saved
        }
        if let data = try? Data(contentsOf: annotationsURL), let saved = try? JSONDecoder().decode([String: JobAnnotation].self, from: data) {
            annotations = saved
        }
    }

    private func ensureStorage() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: metadataURL.path) {
            let header = "job_id\tpurpose\tproject\tinput_path\toutput_path\tscript_path\tnotes\n"
            try header.write(to: metadataURL, atomically: true, encoding: .utf8)
        }
    }

    private func appendMissingMetadataRows(for jobs: [Job]) throws {
        try ensureStorage()
        let existingText = try String(contentsOf: metadataURL, encoding: .utf8)
        let lines = existingText.split(whereSeparator: \Character.isNewline).map(String.init)
        let fields = lines.first?.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) ?? []
        let existingIDs = Set(lines.dropFirst().compactMap {
            $0.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init)
        })
        let newRows = jobs.filter { !existingIDs.contains($0.jobID) }.map { job in
            let values = [
                "job_id": job.jobID,
                "purpose": "",
                "project": job.projectPath,
                "input_path": "",
                "output_path": "",
                "script_path": job.scriptPath == "Unregistered" ? "" : job.scriptPath,
                "notes": ""
            ]
            return fields.map { tsvValue(values[$0] ?? "") }.joined(separator: "\t")
        }
        guard !newRows.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: metadataURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = (newRows.joined(separator: "\n") + "\n").data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func tsvValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}


struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MonitorStore
    @State private var draft: ConnectionSettings

    init(store: MonitorStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connection Settings")
                    .font(.title2.weight(.semibold))
                Text("The app uses your Mac's SSH configuration and keys. Passwords are never requested or stored.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("SSH Host or Alias", text: $draft.host, prompt: Text("hpc.example.edu or cluster-alias"))
                TextField("SSH Port (optional)", text: $draft.port, prompt: Text("Leave blank to use ~/.ssh/config"))
                TextField("SSH Username (optional)", text: $draft.sshUser, prompt: Text("Leave blank if configured by SSH alias"))
                TextField("Slurm Username", text: $draft.slurmUser, prompt: Text("Used by squeue and sacct"))
                Stepper("History: \(draft.historyDays) days", value: $draft.historyDays, in: 1...365)
            }
            .formStyle(.grouped)

            HStack {
                Text("Refresh runs read-only squeue and sacct commands on the login node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Refresh") {
                    store.saveSettings(draft)
                    dismiss()
                    store.refresh()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
            }
        }
        .padding(24)
        .frame(width: 570)
    }
}


struct StatusBadge: View {
    let status: String
    let key: String

    var color: Color {
        switch key {
        case "running": return .blue
        case "pending": return .orange
        case "success": return .green
        case "error": return .red
        case "cancelled": return .gray
        case "ended": return .purple
        default: return .secondary
        }
    }

    var body: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}


struct TagBadge: View {
    let tag: TaskTag

    var body: some View {
        Text(tag.name)
            .font(.caption.weight(.medium))
            .foregroundStyle(tag.color.swiftUIColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tag.color.swiftUIColor.opacity(0.14), in: Capsule())
    }
}


struct DetailValue: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.isEmpty ? "-" : value)
                    .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if !value.isEmpty && !value.hasPrefix("Unregistered") && !value.hasPrefix("Not ") && value != "-" {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
        }
    }
}


struct TagManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: MonitorStore
    @State private var newName = ""
    @State private var newColor = TagColor.defaultBlue.swiftUIColor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Manage Tags")
                    .font(.title2.weight(.semibold))
                Text("Tags are local to this Mac account and automatically create task lists in the sidebar.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                ColorPicker("Color", selection: $newColor, supportsOpacity: false)
                    .labelsHidden()
                TextField("New tag name", text: $newName)
                Button("Add") {
                    store.addTag(name: newName, color: TagColor(newColor))
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach($store.tags) { $tag in
                    HStack {
                        ColorPicker("Color", selection: Binding(
                            get: { tag.color.swiftUIColor },
                            set: {
                                tag.color = TagColor($0)
                                store.saveAnnotations()
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        TextField("Tag name", text: $tag.name)
                            .onChange(of: tag.name) { _, _ in store.saveAnnotations() }
                    }
                }
                .onDelete(perform: store.deleteTags)
            }
            .frame(height: 240)

            HStack {
                Text("Deleting a tag removes it from tasks but keeps local notes and focus flags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}


struct JobDetailView: View {
    @ObservedObject var store: MonitorStore
    let job: Job
    @State private var noteDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    StatusBadge(status: job.displayStatus, key: job.statusKey)
                    Text(job.jobName)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                    Text("JobID \(job.jobID)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                GroupBox("Task Organization") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Special Focus", isOn: Binding(
                            get: { store.isFocused(job) },
                            set: { store.toggleFocus(job, enabled: $0) }
                        ))
                        .toggleStyle(.checkbox)

                        if store.tags.isEmpty {
                            Text("Create tags from the sidebar to organize this task into custom lists.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Tags")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(store.tags) { tag in
                                Toggle(isOn: Binding(
                                    get: { store.annotation(for: job.jobID).tagIDs.contains(tag.id) },
                                    set: { enabled in
                                        var ids = store.annotation(for: job.jobID).tagIDs
                                        if enabled { ids.append(tag.id) }
                                        else { ids.removeAll { $0 == tag.id } }
                                        store.setTags(Array(Set(ids)), for: job)
                                    }
                                )) {
                                    TagBadge(tag: tag)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }

                        Text("Notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $noteDraft)
                            .font(.callout)
                            .frame(minHeight: 80)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(.quaternary)
                            }
                            .onChange(of: noteDraft) { store.setNote(noteDraft, for: job) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Task Information") {
                    VStack(alignment: .leading, spacing: 14) {
                        DetailValue(label: "Purpose", value: job.displayPurpose)
                        DetailValue(label: "Project", value: job.project)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Slurm Status") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        GridRow { Text("State Summary").foregroundStyle(.secondary); Text(job.stateSummary) }
                        GridRow { Text("State Code").foregroundStyle(.secondary); Text(job.stateCode) }
                        GridRow { Text("Priority").foregroundStyle(.secondary); Text(job.priority) }
                        GridRow { Text("User").foregroundStyle(.secondary); Text(job.user) }
                        GridRow { Text("Submit / Start").foregroundStyle(.secondary); Text(job.displaySubmitOrStart) }
                        GridRow { Text("Run / Wait").foregroundStyle(.secondary); Text(job.runWait) }
                        GridRow { Text("Submitted").foregroundStyle(.secondary); Text(job.displaySubmit) }
                        GridRow { Text("Started").foregroundStyle(.secondary); Text(job.start) }
                        GridRow { Text("Ended").foregroundStyle(.secondary); Text(job.end) }
                        GridRow { Text("Elapsed").foregroundStyle(.secondary); Text(job.elapsed) }
                        GridRow { Text("TimeLimit").foregroundStyle(.secondary); Text(job.timeLimit) }
                        GridRow { Text("Partition / QOS").foregroundStyle(.secondary); Text("\(job.partition) / \(job.qos)") }
                        GridRow { Text("Nodes / CPU Slots").foregroundStyle(.secondary); Text("\(job.nodes) / \(job.slots)") }
                        GridRow { Text("GPU / Memory").foregroundStyle(.secondary); Text("\(job.gpu) / \(job.memory)") }
                        GridRow { Text("Array Tasks").foregroundStyle(.secondary); Text(job.arrayTasks) }
                        GridRow { Text("Node / Reason").foregroundStyle(.secondary); Text(job.nodeOrReason) }
                        GridRow { Text("Node List").foregroundStyle(.secondary); Text(job.nodeList) }
                        GridRow { Text("Reason").foregroundStyle(.secondary); Text(job.reason) }
                        GridRow { Text("Exit Code").foregroundStyle(.secondary); Text(job.exitCode) }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("File Locations") {
                    VStack(alignment: .leading, spacing: 16) {
                        DetailValue(label: "Input", value: job.displayInputPath, monospaced: true)
                        Divider()
                        DetailValue(label: "Output", value: job.displayOutputPath, monospaced: true)
                        Divider()
                        DetailValue(label: "Submission Script", value: job.displayScriptPath, monospaced: true)
                        Divider()
                        DetailValue(label: "Project Path", value: job.projectPath, monospaced: true)
                        Divider()
                        DetailValue(label: "Slurm Working Directory", value: job.displayWorkDir, monospaced: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { noteDraft = store.note(for: job) }
        .onChange(of: job.jobID) { _, _ in noteDraft = store.note(for: job) }
    }
}


struct JobTableView: View {
    @ObservedObject var store: MonitorStore
    let jobs: [Job]
    @Binding var selectedJobID: String?
    @Binding var sortOrder: [KeyPathComparator<Job>]
    let mode: TableMode

    @ViewBuilder
    var body: some View {
        if mode == .overview {
            Table(jobs, selection: $selectedJobID, sortOrder: $sortOrder) {
                TableColumn("Status") { job in
                    StatusBadge(status: job.displayStatus, key: job.statusKey)
                }
                .width(min: 78, ideal: 88, max: 100)
                TableColumn("JobID", value: \.jobID)
                    .width(min: 80, ideal: 92, max: 110)
                TableColumn("Job Name", value: \.jobName)
                    .width(min: 145, ideal: 210)
                TableColumn("Tags") { job in
                    HStack(spacing: 4) {
                        if store.isFocused(job) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        ForEach(Array(store.tags(for: job).prefix(2))) { tag in
                            TagBadge(tag: tag)
                        }
                    }
                }
                .width(min: 82, ideal: 130, max: 190)
                TableColumn("Purpose", value: \.displayPurpose)
                    .width(min: 175, ideal: 260)
                TableColumn("Project", value: \.project)
                    .width(min: 150, ideal: 210)
                TableColumn("Submit / Start", value: \.displaySubmitOrStart)
                    .width(min: 125, ideal: 145, max: 170)
                TableColumn("Elapsed", value: \.elapsed)
                    .width(min: 75, ideal: 90, max: 110)
                TableColumn("Partition", value: \.partition)
                    .width(min: 82, ideal: 95, max: 115)
                TableColumn("QOS", value: \.qos)
                    .width(min: 75, ideal: 88, max: 110)
            }
        } else {
            Table(jobs, selection: $selectedJobID, sortOrder: $sortOrder) {
                TableColumn("JobID", value: \.jobID)
                    .width(min: 78, ideal: 90, max: 105)
                TableColumn("Prior", value: \.priority)
                    .width(min: 56, ideal: 64, max: 76)
                TableColumn("Job Name", value: \.jobName)
                    .width(min: 140, ideal: 190)
                TableColumn("User", value: \.user)
                    .width(min: 72, ideal: 82, max: 100)
                TableColumn("Submit / Start", value: \.displaySubmitOrStart)
                    .width(min: 125, ideal: 145, max: 170)
                TableColumn("ST", value: \.stateCode)
                    .width(min: 38, ideal: 44, max: 54)
                TableColumn("Run / Wait", value: \.runWait)
                    .width(min: 76, ideal: 88, max: 105)
                TableColumn("Queue / QOS", value: \.queueQOS)
                    .width(min: 125, ideal: 145)
                TableColumn("Resources", value: \.resourceSummary)
                    .width(min: 100, ideal: 120)
                TableColumn("Array · Node / Reason", value: \.arrayNodeReason)
                    .width(min: 150, ideal: 230)
            }
        }
    }
}


struct ContentView: View {
    @StateObject private var store = MonitorStore()
    @State private var selection: SidebarSelection = .status(.all)
    @State private var selectedJobID: String?
    @State private var searchText = ""
    @State private var tableMode: TableMode = .overview
    @State private var showSettings = false
    @State private var showTagManager = false
    @State private var showModeHelp = false
    @State private var sortOrder = [KeyPathComparator(\Job.submitOrStart, order: .reverse)]

    private var activeTitle: String {
        switch selection {
        case .status(let filter): return filter.title
        case .focus: return "Special Focus"
        case .tag(let id): return store.tags.first(where: { $0.id == id })?.name ?? "Tag"
        }
    }

    private var filteredJobs: [Job] {
        let matches = store.jobs.filter { job in
            let listMatches: Bool
            switch selection {
            case .status(let filter): listMatches = filter == .all || job.filters.contains(filter.rawValue)
            case .focus: listMatches = store.isFocused(job)
            case .tag(let id): listMatches = store.annotation(for: job.jobID).tagIDs.contains(id)
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let searchable = [
                job.jobID, job.jobName, job.displayPurpose, job.project,
                job.user, job.partition, job.qos, job.arrayTasks, job.nodeOrReason,
                job.projectPath, job.inputPath, job.outputPath, job.scriptPath,
                store.note(for: job), store.tags(for: job).map(\.name).joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return listMatches && (query.isEmpty || searchable.contains(query))
        }
        return matches.sorted(using: sortOrder)
    }

    private var selectedJob: Job? {
        guard let selectedJobID else { return nil }
        return store.jobs.first(where: { $0.jobID == selectedJobID })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Job Status") {
                        ForEach(StatusFilter.allCases) { item in
                            Label(item.title, systemImage: item.symbol)
                                .badge(store.count(for: item))
                                .tag(SidebarSelection.status(item))
                        }
                    }
                    Section("Task Lists") {
                        Label("Special Focus", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                            .badge(store.jobs.filter { store.isFocused($0) }.count)
                            .tag(SidebarSelection.focus)
                        ForEach(store.tags) { tag in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(tag.color.swiftUIColor)
                                    .frame(width: 9, height: 9)
                                Text(tag.name)
                            }
                            .badge(store.jobs.filter { store.annotation(for: $0.jobID).tagIDs.contains(tag.id) }.count)
                            .tag(SidebarSelection.tag(tag.id))
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button("Manage Tags", systemImage: "tag") {
                        showTagManager = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Button("Open Metadata Table", systemImage: "tablecells") {
                        store.openMetadata()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    Text("Local metadata: purpose and paths")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
            .navigationTitle("HPC Jobs")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            VStack(spacing: 0) {
                if let message = store.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(message).lineLimit(2)
                        Spacer()
                    }
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.08))
                }
                HStack {
                    Picker("Table Mode", selection: $tableMode) {
                        ForEach(TableMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    Button("About Table Modes", systemImage: "info.circle") {
                        showModeHelp.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .popover(isPresented: $showModeHelp, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Table Modes")
                                .font(.headline)
                            Text("Overview")
                                .fontWeight(.semibold)
                            Text("Workflow context: status, labels, purpose, project and basic timing.")
                                .foregroundStyle(.secondary)
                            Text("Scheduler")
                                .fontWeight(.semibold)
                            Text("Slurm details: priority, state code, queue/QOS, requested resources, array tasks and node/reason.")
                                .foregroundStyle(.secondary)
                            Divider()
                            Text("Click a column header to sort. Click it again to reverse the order.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 330, alignment: .leading)
                        .padding(16)
                    }
                    Text("Click a column header to sort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

                JobTableView(store: store, jobs: filteredJobs, selectedJobID: $selectedJobID, sortOrder: $sortOrder, mode: tableMode)
                .overlay {
                    if filteredJobs.isEmpty && !store.isRefreshing {
                        ContentUnavailableView("No Matching Jobs", systemImage: "tray")
                    }
                }
                HStack {
                    Text("Showing \(filteredJobs.count) of \(store.jobs.count) jobs")
                    Spacer()
                    Text("Cluster time: \(store.fetchedAt)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.bar)
            }
            .navigationSplitViewColumnWidth(min: 650, ideal: 780)
            .navigationTitle(activeTitle)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search jobs or paths")
            .toolbar {
                ToolbarItemGroup {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        if store.hasValidSettings { store.refresh() }
                        else { showSettings = true }
                    }
                    .disabled(store.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)
                    Button("Connection Settings", systemImage: "gearshape") {
                        showSettings = true
                    }
                }
            }
        } detail: {
            if let selectedJob {
                JobDetailView(store: store, job: selectedJob)
                    .navigationSplitViewColumnWidth(min: 330, ideal: 410, max: 520)
            } else {
                ContentUnavailableView("Select a Job", systemImage: "sidebar.right", description: Text("View its purpose, status, and file locations"))
                    .navigationSplitViewColumnWidth(min: 330, ideal: 410, max: 520)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear {
            if store.hasValidSettings { store.initialRefresh() }
            else { showSettings = true }
        }
        .sheet(isPresented: $showSettings) {
            ConnectionSettingsView(store: store)
        }
        .sheet(isPresented: $showTagManager) {
            TagManagerView(store: store)
        }
    }
}


@main
struct HPCTaskMonitorApp: App {
    var body: some Scene {
        WindowGroup("HPC Task Monitor") {
            ContentView()
        }
        .defaultSize(width: 1420, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
