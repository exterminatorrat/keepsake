import Foundation

enum SampleIngestResult: Equatable, Sendable {
    case stored
    case duplicate
    case outOfOrder
    case invalid
    case expired
}

struct RouteLoadResult: Sendable {
    let samples: [RouteSample]
    let recoveredIncompleteTail: Bool
}

enum RouteStorageError: Error, Equatable, Sendable {
    case unreadableArchive
    case corruptArchive
    case backupExclusionFailed
    case writeFailed
}

actor RouteRepository {
    static let retentionDays = 90

    private let fileURL: URL
    private let retentionInterval: TimeInterval
    private var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }
    private var didLoad = false
    private var samples: [RouteSample] = []
    private var sampleIDs: Set<UUID> = []
    private var fingerprints: Set<RouteSampleFingerprint> = []

    init(fileURL: URL, retentionDays: Int = 90) {
        self.fileURL = fileURL
        retentionInterval = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
    }

    static func local() -> RouteRepository {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepsake", isDirectory: true)
        return RouteRepository(fileURL: directory.appendingPathComponent("route-history.jsonl"))
    }

    func load(now: Date = .now) throws -> RouteLoadResult {
        var recoveredIncompleteTail = false

        if !didLoad {
            recoveredIncompleteTail = try readArchive()
            didLoad = true
        }

        try pruneExpired(now: now)
        return RouteLoadResult(samples: samples, recoveredIncompleteTail: recoveredIncompleteTail)
    }

    func append(_ sample: RouteSample, now: Date = .now) throws -> SampleIngestResult {
        _ = try load(now: now)

        guard sample.isValid else {
            return .invalid
        }

        guard sample.observedAt <= now.addingTimeInterval(60) else {
            return .invalid
        }

        guard sample.observedAt >= now.addingTimeInterval(-retentionInterval) else {
            return .expired
        }

        guard !sampleIDs.contains(sample.id), !fingerprints.contains(sample.fingerprint) else {
            return .duplicate
        }

        if let latest = samples.last, sample.observedAt <= latest.observedAt {
            return .outOfOrder
        }

        var line = try JSONEncoder().encode(sample)
        line.append(0x0A)
        do {
            try appendLine(line)
        } catch {
            throw RouteStorageError.writeFailed
        }

        samples.append(sample)
        sampleIDs.insert(sample.id)
        fingerprints.insert(sample.fingerprint)
        try pruneExpired(now: now)
        return .stored
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                throw RouteStorageError.writeFailed
            }
        }

        samples.removeAll()
        sampleIDs.removeAll()
        fingerprints.removeAll()
        didLoad = true
    }

    private func readArchive() throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        try excludeDirectoryFromBackup()

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RouteStorageError.unreadableArchive
        }

        let hasTrailingNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var loadedSamples: [RouteSample] = []
        var loadedIDs: Set<UUID> = []
        var loadedFingerprints: Set<RouteSampleFingerprint> = []
        var recoveredIncompleteTail = false

        for (index, line) in lines.enumerated() {
            let sample: RouteSample
            do {
                sample = try JSONDecoder().decode(RouteSample.self, from: Data(line))
            } catch {
                if !hasTrailingNewline && index == lines.count - 1 {
                    recoveredIncompleteTail = true
                    break
                }
                throw RouteStorageError.corruptArchive
            }

            guard sample.isValid,
                  !loadedIDs.contains(sample.id),
                  !loadedFingerprints.contains(sample.fingerprint),
                  loadedSamples.last.map({ sample.observedAt > $0.observedAt }) ?? true else {
                throw RouteStorageError.corruptArchive
            }

            loadedSamples.append(sample)
            loadedIDs.insert(sample.id)
            loadedFingerprints.insert(sample.fingerprint)
        }

        samples = loadedSamples
        sampleIDs = loadedIDs
        fingerprints = loadedFingerprints

        if recoveredIncompleteTail || (!data.isEmpty && !hasTrailingNewline) {
            try rewriteArchive(samples)
        }

        return recoveredIncompleteTail
    }

    private func appendLine(_ data: Data) throws {
        do {
            try prepareDirectory()

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                ) else {
                    throw RouteStorageError.writeFailed
                }
            }

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch let error as RouteStorageError {
            throw error
        } catch {
            throw RouteStorageError.writeFailed
        }
    }

    private func pruneExpired(now: Date) throws {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        guard samples.contains(where: { $0.observedAt < cutoff }) else {
            return
        }

        let retainedSamples = RouteHistory.retainedSamples(samples, after: cutoff)
        try rewriteArchive(retainedSamples)
        samples = retainedSamples
        sampleIDs = Set(retainedSamples.map(\.id))
        fingerprints = Set(retainedSamples.map(\.fingerprint))
    }

    private func rewriteArchive(_ samples: [RouteSample]) throws {
        if samples.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch {
                    throw RouteStorageError.writeFailed
                }
            }
            return
        }

        var data = Data()
        for sample in samples {
            do {
                data.append(try JSONEncoder().encode(sample))
            } catch {
                throw RouteStorageError.writeFailed
            }
            data.append(0x0A)
        }

        do {
            try prepareDirectory()
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch let error as RouteStorageError {
            throw error
        } catch {
            throw RouteStorageError.writeFailed
        }
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw RouteStorageError.writeFailed
        }

        try excludeDirectoryFromBackup()
    }

    private func excludeDirectoryFromBackup() throws {
        do {
            var directory = directoryURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try directory.setResourceValues(resourceValues)
        } catch {
            throw RouteStorageError.backupExclusionFailed
        }
    }
}
