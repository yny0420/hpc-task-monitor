import Foundation


struct ConnectionSettings: Codable, Equatable {
    var host = ""
    var port = ""
    var sshUser = ""
    var slurmUser = ""
    var historyDays = 14

    var isComplete: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !slurmUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (port.isEmpty || Int(port).map { (1...65535).contains($0) } == true)
    }

    var target: String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanUser.isEmpty || cleanHost.contains("@") { return cleanHost }
        return "\(cleanUser)@\(cleanHost)"
    }
}


enum SlurmBackendError: LocalizedError {
    case invalidSettings
    case sshFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Connection settings are incomplete or invalid."
        case .sshFailed(let message):
            return message
        case .malformedResponse:
            return "The cluster returned an unexpected response. Check that Slurm is available on the login node."
        }
    }
}


private typealias SlurmRecord = [String: String]


enum SlurmBackend {
    private static let squeueFields = [
        "job_id", "priority", "job_name", "user", "submit", "start", "state_code",
        "state", "elapsed", "time_limit", "partition", "qos", "nodes", "cpus", "gres",
        "memory", "array_job_id", "array_task_id", "reason", "work_dir", "command"
    ]

    private static let sacctFields = [
        "job_id_raw", "job_id", "job_name", "user", "priority", "state", "exit_code",
        "elapsed", "time_limit", "partition", "qos", "submit", "start", "end", "nodes",
        "alloc_cpus", "req_cpus", "memory", "node_list", "work_dir", "req_tres", "alloc_tres"
    ]

    private static let terminalStates: Set<String> = [
        "COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL",
        "PREEMPTED", "BOOT_FAIL", "DEADLINE", "REVOKED"
    ]
    private static let errorStates: Set<String> = [
        "FAILED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED", "BOOT_FAIL",
        "DEADLINE", "REVOKED"
    ]
    private static let runningStates: Set<String> = ["RUNNING", "COMPLETING", "CONFIGURING", "STAGE_OUT"]
    private static let pendingStates: Set<String> = ["PENDING", "SUSPENDED", "RESIZING"]

    static func fetch(settings: ConnectionSettings, metadataURL: URL) throws -> DashboardPayload {
        guard settings.isComplete else { throw SlurmBackendError.invalidSettings }

        let startDate = Calendar.current.date(byAdding: .day, value: -settings.historyDays, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: startDate)
        let user = shellQuote(settings.slurmUser.trimmingCharacters(in: .whitespacesAndNewlines))

        let remoteCommand = """
        set -e
        printf '__HPC_MONITOR_SQUEUE__\\n'
        squeue -u \(user) -h -o "%i|%Q|%j|%u|%V|%S|%t|%T|%M|%l|%P|%q|%D|%C|%b|%m|%F|%K|%R|%Z|%o"
        printf '__HPC_MONITOR_SACCT__\\n'
        sacct -u \(user) -S \(start) -n -P -X --format=JobIDRaw,JobID,JobName%64,User,Priority,State,ExitCode,Elapsed,Timelimit,Partition,QOS,Submit,Start,End,NNodes,AllocCPUS,ReqCPUS,ReqMem,NodeList,WorkDir%200,ReqTRES%120,AllocTRES%120
        printf '__HPC_MONITOR_TIME__\\n'
        date '+%Y-%m-%d %H:%M:%S %Z'
        """

        let output = try runSSH(settings: settings, command: remoteCommand)
        guard
            let queueRange = output.range(of: "__HPC_MONITOR_SQUEUE__\n"),
            let accountingRange = output.range(of: "__HPC_MONITOR_SACCT__\n"),
            let timeRange = output.range(of: "__HPC_MONITOR_TIME__\n"),
            queueRange.upperBound <= accountingRange.lowerBound,
            accountingRange.upperBound <= timeRange.lowerBound
        else { throw SlurmBackendError.malformedResponse }

        let queueText = String(output[queueRange.upperBound..<accountingRange.lowerBound])
        let accountingText = String(output[accountingRange.upperBound..<timeRange.lowerBound])
        let fetchedAt = String(output[timeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var merged: [String: SlurmRecord] = [:]

        for var row in parsePipeRows(accountingText, fields: sacctFields) {
            let jobID = row["job_id", default: ""]
            guard !jobID.isEmpty, !jobID.contains(".") else { continue }
            row["source"] = "sacct"
            row["state"] = normalizeState(row["state"])
            merged[jobID] = row
        }
        for var row in parsePipeRows(queueText, fields: squeueFields) {
            let jobID = row["job_id", default: ""]
            guard !jobID.isEmpty else { continue }
            row["source"] = "squeue"
            row["state"] = normalizeState(row["state"])
            row["reason"] = row["reason", default: ""].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if runningStates.contains(row["state", default: ""]) {
                row["node_list"] = row["reason"]
                row["reason"] = ""
            }
            merged[jobID] = (merged[jobID] ?? [:]).merging(row) { _, new in new }
        }

        let metadata = readMetadata(at: metadataURL)
        let jobs = groupRecords(Array(merged.values), metadata: metadata)
        let now = ISO8601DateFormatter().string(from: Date())
        return DashboardPayload(fetchedAt: fetchedAt, generatedAt: now, days: settings.historyDays, jobs: jobs)
    }

    private static func runSSH(settings: ConnectionSettings, command: String) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        var arguments = [
            "-n", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2"
        ]
        if !settings.port.isEmpty {
            arguments += ["-p", settings.port]
        }
        arguments += [settings.target, "bash", "-lc", shellQuote(command)]

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        var outputData = Data()
        var errorData = Data()
        do {
            try process.run()
            let readers = DispatchGroup()
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
            process.waitUntilExit()
            readers.wait()
        } catch {
            throw SlurmBackendError.sshFailed("Could not start SSH: \(error.localizedDescription)")
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = error.isEmpty ? "SSH exited with status \(process.terminationStatus)." : error
            throw SlurmBackendError.sshFailed(detail)
        }
        return output
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parsePipeRows(_ text: String, fields: [String]) -> [SlurmRecord] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var values = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if values.count < fields.count {
                values += Array(repeating: "", count: fields.count - values.count)
            }
            return Dictionary(uniqueKeysWithValues: zip(fields, values.prefix(fields.count)))
        }
    }

    private static func normalizeState(_ value: String?) -> String {
        let state = (value ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? "UNKNOWN"
        return state.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
    }

    private static func rootJobID(_ value: String) -> String {
        String(value.prefix(while: { $0.isNumber })).isEmpty ? value : String(value.prefix(while: { $0.isNumber }))
    }

    private static func categories(_ record: SlurmRecord) -> Set<String> {
        let state = normalizeState(record["state"])
        let reason = record["reason", default: ""]
        let exitCode = record["exit_code", default: ""]
        var result: Set<String> = []
        if runningStates.contains(state) { result.insert("running") }
        if pendingStates.contains(state) { result.insert("pending") }
        if reason.contains("DependencyNeverSatisfied") { result.insert("error") }
        if state == "COMPLETED" && (exitCode.isEmpty || exitCode == "0:0") { result.insert("completed_ok") }
        if state == "CANCELLED" { result.insert("cancelled") }
        if errorStates.contains(state) || (state == "COMPLETED" && !exitCode.isEmpty && exitCode != "0:0") {
            result.insert("error")
        }
        if terminalStates.contains(state) { result.insert("terminal") }
        return result
    }

    private static func readMetadata(at url: URL) -> [String: SlurmRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        guard let header = lines.first else { return [:] }
        let fields = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        var result: [String: SlurmRecord] = [:]
        for line in lines.dropFirst() {
            var values = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if values.count < fields.count { values += Array(repeating: "", count: fields.count - values.count) }
            let row = Dictionary(uniqueKeysWithValues: zip(fields, values.prefix(fields.count)))
            if let jobID = row["job_id"], !jobID.isEmpty { result[jobID] = row }
        }
        return result
    }

    private static func groupRecords(_ records: [SlurmRecord], metadata: [String: SlurmRecord]) -> [Job] {
        let groups = Dictionary(grouping: records) { rootJobID($0["job_id", default: "UNKNOWN"]) }
        let severity = ["error": 0, "running": 1, "pending": 2, "unknown": 3, "cancelled": 4, "ended": 5, "success": 6]
        return groups.map { summarize(jobID: $0.key, records: $0.value, metadata: metadata[$0.key] ?? [:]) }
            .sorted {
                let left = severity[$0.statusKey, default: 9]
                let right = severity[$1.statusKey, default: 9]
                if left != right { return left < right }
                return $0.submit > $1.submit
            }
    }

    private static func summarize(jobID: String, records input: [SlurmRecord], metadata: SlurmRecord) -> Job {
        let records = input.sorted {
            ($0["submit", default: ""], $0["job_id", default: ""]) >
            ($1["submit", default: ""], $1["job_id", default: ""])
        }
        let categorySets = records.map(categories)
        let hasRunning = categorySets.contains { $0.contains("running") }
        let hasPending = categorySets.contains { $0.contains("pending") }
        let hasError = categorySets.contains { $0.contains("error") }
        let hasCancelled = categorySets.contains { $0.contains("cancelled") }
        let allTerminal = !records.isEmpty && categorySets.allSatisfy { $0.contains("terminal") }
        let allSuccess = !records.isEmpty && categorySets.allSatisfy { $0.contains("completed_ok") }
        var filters: [String] = []
        if hasRunning { filters.append("running") }
        if hasPending { filters.append("pending") }
        if hasError { filters.append("error") }
        if hasCancelled { filters.append("cancelled") }
        if allTerminal { filters.append("ended") }
        if allSuccess { filters.append("success") }

        let status: (String, String)
        if hasError { status = ("Error", "error") }
        else if hasRunning { status = ("Running", "running") }
        else if hasPending { status = ("Pending", "pending") }
        else if allSuccess { status = ("Success", "success") }
        else if hasCancelled { status = ("Cancelled", "cancelled") }
        else if allTerminal { status = ("Ended", "ended") }
        else { status = ("Unknown", "unknown") }

        let states = records.map { normalizeState($0["state"]) }
        let stateCounts = Dictionary(grouping: states, by: { $0 }).mapValues(\.count)
        let stateSummary = stateCounts.keys.sorted().map { "\($0) × \(stateCounts[$0]!)" }.joined(separator: " · ")
        let projectPath = clean(metadata["project"]) ?? chooseProjectPath(records)
        let rawStates = states
        let representative: String
        if hasError { representative = rawStates.first(where: errorStates.contains) ?? rawStates.first ?? "UNKNOWN" }
        else if hasRunning { representative = "RUNNING" }
        else if hasPending { representative = "PENDING" }
        else if allSuccess { representative = "COMPLETED" }
        else if hasCancelled { representative = "CANCELLED" }
        else { representative = rawStates.first ?? "UNKNOWN" }

        let activeRecords = records.filter { runningStates.contains(normalizeState($0["state"])) }
        let activeNodes = uniqueValues(activeRecords, key: "node_list")
        let nodeValues = uniqueValues(records, key: "node_list")
        let reasons = uniqueValues(records, key: "reason")
        let nodes = activeNodes.isEmpty ? (chooseValue(records, key: "nodes") ?? "-") : String(activeNodes.count)
        let slots = chooseValue(records, key: "req_cpus") ?? chooseValue(records, key: "cpus") ?? chooseValue(records, key: "alloc_cpus") ?? "-"
        let scriptPath = clean(metadata["script_path"]) ?? chooseValue(records, key: "command") ?? "Unregistered"

        return Job(
            jobID: jobID,
            jobName: chooseValue(records, key: "job_name") ?? "Unnamed",
            status: status.0,
            statusKey: status.1,
            filters: filters,
            stateSummary: stateSummary,
            stateCode: stateCode(representative),
            priority: chooseValue(records, key: "priority") ?? "-",
            user: chooseValue(records, key: "user") ?? "-",
            submitOrStart: submitOrStart(records, hasRunning: hasRunning),
            runWait: runWait(records, hasRunning: hasRunning, hasPending: hasPending),
            purpose: clean(metadata["purpose"]) ?? "Unregistered",
            project: projectPath.isEmpty ? "Unidentified" : URL(fileURLWithPath: projectPath).lastPathComponent,
            projectPath: projectPath,
            inputPath: clean(metadata["input_path"]) ?? "Unregistered",
            outputPath: clean(metadata["output_path"]) ?? "Unregistered",
            scriptPath: scriptPath,
            workDir: chooseValue(records, key: "work_dir") ?? "Not recorded",
            stdout: clean(metadata["stdout"]) ?? "Not available from Slurm",
            stderr: clean(metadata["stderr"]) ?? "Not available from Slurm",
            notes: clean(metadata["notes"]) ?? "",
            elapsed: chooseValue(records, key: "elapsed") ?? "-",
            timeLimit: chooseValue(records, key: "time_limit") ?? "-",
            partition: chooseValue(records, key: "partition") ?? "-",
            qos: chooseValue(records, key: "qos") ?? "-",
            reason: reasons.isEmpty ? "-" : reasons.joined(separator: ", "),
            exitCode: chooseValue(records, key: "exit_code") ?? "-",
            submit: chooseValue(records, key: "submit") ?? "-",
            start: chooseValue(records, key: "start") ?? "-",
            end: chooseValue(records, key: "end") ?? "-",
            nodeList: (activeNodes.isEmpty ? nodeValues : activeNodes).joined(separator: ", ").nilIfEmpty ?? "-",
            nodes: nodes,
            slots: slots,
            gpu: requestedGPU(records),
            memory: requestedMemory(records),
            arrayTasks: arrayTaskSummary(jobID: jobID, records: records),
            nodeOrReason: (hasRunning ? activeNodes : (!reasons.isEmpty ? reasons : nodeValues)).joined(separator: ", ").nilIfEmpty ?? "-",
            reqTres: chooseValue(records, key: "req_tres") ?? "-",
            allocTres: chooseValue(records, key: "alloc_tres") ?? "-",
            memberCount: records.count
        )
    }

    private static func clean(_ value: String?) -> String? {
        let result = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func chooseValue(_ records: [SlurmRecord], key: String) -> String? {
        records.compactMap { clean($0[key]) }.first { !["N/A", "Unknown"].contains($0) }
    }

    private static func uniqueValues(_ records: [SlurmRecord], key: String) -> [String] {
        var seen: Set<String> = []
        return records.compactMap { clean($0[key]) }.filter {
            !["N/A", "Unknown", "-", "None", "None assigned"].contains($0) && seen.insert($0).inserted
        }
    }

    private static func chooseProjectPath(_ records: [SlurmRecord]) -> String {
        let paths = records.flatMap { [$0["command", default: ""], $0["work_dir", default: ""]] }
            .filter { !$0.isEmpty && !["Unknown", "N/A"].contains($0) }
        let preferred = paths.filter { !$0.contains("/software/") }
        guard var path = (preferred.isEmpty ? paths : preferred).first else { return "" }
        for marker in ["/slurm/", "/scripts/", "/logs/", "/outputs/"] {
            if let range = path.range(of: marker) { path = String(path[..<range.lowerBound]); break }
        }
        let url = URL(fileURLWithPath: path)
        if ["slurm", "scripts", "logs", "outputs"].contains(url.lastPathComponent) {
            return url.deletingLastPathComponent().path
        }
        return url.pathExtension.isEmpty ? path : url.deletingLastPathComponent().path
    }

    private static func stateCode(_ state: String) -> String {
        let codes = ["RUNNING": "R", "PENDING": "PD", "COMPLETED": "CD", "COMPLETING": "CG", "CONFIGURING": "CF", "FAILED": "F", "CANCELLED": "CA", "TIMEOUT": "TO", "OUT_OF_MEMORY": "OOM", "NODE_FAIL": "NF", "PREEMPTED": "PR", "SUSPENDED": "S"]
        let value = normalizeState(state)
        return codes[value] ?? String(value.prefix(3))
    }

    private static func submitOrStart(_ records: [SlurmRecord], hasRunning: Bool) -> String {
        if hasRunning {
            let starts = records.filter { runningStates.contains(normalizeState($0["state"])) }
                .compactMap { clean($0["start"]) }.filter { !["N/A", "Unknown", "-"].contains($0) }.sorted()
            if let first = starts.first { return first }
        }
        return chooseValue(records, key: "submit") ?? "-"
    }

    private static func runWait(_ records: [SlurmRecord], hasRunning: Bool, hasPending: Bool) -> String {
        if hasRunning {
            return records.first(where: { runningStates.contains(normalizeState($0["state"])) })?["elapsed"] ?? chooseValue(records, key: "elapsed") ?? "-"
        }
        if hasPending {
            let dates = records.filter { pendingStates.contains(normalizeState($0["state"])) }.compactMap { parseISO($0["submit"]) }
            if let earliest = dates.min() { return formatDuration(Int(Date().timeIntervalSince(earliest))) }
        }
        return chooseValue(records, key: "elapsed") ?? "-"
    }

    private static func parseISO(_ value: String?) -> Date? {
        guard let value, value.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: String(value.prefix(19)))
    }

    private static func formatDuration(_ input: Int) -> String {
        var seconds = max(0, input)
        let days = seconds / 86_400; seconds %= 86_400
        let hours = seconds / 3_600; seconds %= 3_600
        let minutes = seconds / 60; let secs = seconds % 60
        return days > 0 ? String(format: "%d-%02d:%02d:%02d", days, hours, minutes, secs) : String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    private static func requestedGPU(_ records: [SlurmRecord]) -> String {
        let patterns = [#"gres/gpu(?:/[^=,]+)?=(\d+)"#, #"gpu(?::[^:,=]+)?[:=](\d+)"#]
        var counts: [Int] = []
        for record in records {
            for key in ["gres", "req_tres", "alloc_tres"] {
                let value = record[key, default: ""] as NSString
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value as String, range: NSRange(location: 0, length: value.length)), match.numberOfRanges > 1 else { continue }
                    counts.append(Int(value.substring(with: match.range(at: 1))) ?? 0)
                }
            }
        }
        return counts.max().map(String.init) ?? "-"
    }

    private static func requestedMemory(_ records: [SlurmRecord]) -> String {
        guard var value = chooseValue(records, key: "memory") else { return "-" }
        if value.hasSuffix("n") || value.hasSuffix("c") { value.removeLast() }
        return value
    }

    private static func arrayTaskSummary(jobID: String, records: [SlurmRecord]) -> String {
        var values: [String] = []
        for record in records {
            if let task = clean(record["array_task_id"]), !["N/A", "Unknown"].contains(task) { values.append(task) }
            else {
                let recordID = record["job_id", default: ""]
                if recordID.hasPrefix("\(jobID)_") { values.append(String(recordID.dropFirst(jobID.count + 1))) }
            }
        }
        values = Array(NSOrderedSet(array: values)) as? [String] ?? values
        guard !values.isEmpty else { return "-" }
        let numeric = values.compactMap(Int.init).sorted()
        let nonnumeric = values.filter { Int($0) == nil }
        if !numeric.isEmpty && nonnumeric.isEmpty && numeric.count > 12 {
            return "\(numeric.first!)–\(numeric.last!) (\(numeric.count) tasks)"
        }
        let display = numeric.map(String.init) + nonnumeric
        return display.prefix(12).joined(separator: ", ") + (display.count > 12 ? " +\(display.count - 12) more" : "")
    }
}


private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
