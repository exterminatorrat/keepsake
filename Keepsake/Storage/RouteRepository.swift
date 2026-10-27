import Foundation
import Darwin

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
    case protectionFailed
    case backupExclusionFailed
    case writeFailed
    case writeOutcomeUncertain
}

actor RouteRepository {
    static let retentionDays = 90

    private var fileURL: URL
    private var trustedLocalApplicationSupportURL: URL?
    private let retentionInterval: TimeInterval
    private let protectAndVerify: @Sendable (URL, RouteStoreProtectedItem) throws -> Void
    private var directoryURL: URL {
        fileURL.deletingLastPathComponent()
    }
    private var didLoad = false
    private var samples: [RouteSample] = []
    private var sampleIDs: Set<UUID> = []
    private var fingerprints: Set<RouteSampleFingerprint> = []

    init(
        fileURL: URL,
        retentionDays: Int = 90,
        protectAndVerify: (@Sendable (URL, RouteStoreProtectedItem) throws -> Void)? = nil
    ) {
        self.fileURL = fileURL
        trustedLocalApplicationSupportURL = nil
        retentionInterval = TimeInterval(max(1, retentionDays)) * 24 * 60 * 60
        self.protectAndVerify = protectAndVerify ?? { url, item in
            try Self.protectArchiveItem(url, as: item)
        }
    }

    private init(localApplicationSupportURL: URL) {
        fileURL = localApplicationSupportURL
            .appendingPathComponent("Keepsake", isDirectory: true)
            .appendingPathComponent("route-history.jsonl")
        trustedLocalApplicationSupportURL = localApplicationSupportURL
        retentionInterval = TimeInterval(Self.retentionDays) * 24 * 60 * 60
        protectAndVerify = { url, item in
            try Self.protectArchiveItem(url, as: item)
        }
    }

    static func local() -> RouteRepository {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RouteRepository(localApplicationSupportURL: directory)
    }

    func load(now: Date = .now) throws -> RouteLoadResult {
        try resolveTrustedLocalApplicationSupportURL()
        var recoveredIncompleteTail = false

        if !didLoad {
            recoveredIncompleteTail = try readArchive()
            didLoad = true
        }

        do {
            try pruneExpired(now: now)
        } catch {
            if let storageError = error as? RouteStorageError,
               storageError == .writeOutcomeUncertain {
                didLoad = false
            }
            throw error
        }
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
            didLoad = false
            throw Self.storageError(for: error)
        }

        samples.append(sample)
        sampleIDs.insert(sample.id)
        fingerprints.insert(sample.fingerprint)
        return .stored
    }

    func clear() throws {
        try resolveTrustedLocalApplicationSupportURL()
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

        try protect(directoryURL, as: .directory)
        try protect(fileURL, as: .file)

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
        var writeAttempted = false
        do {
            try prepareDirectory()

            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: Data(),
                    attributes: [
                        .posixPermissions: 0o600,
                        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                    ]
                ) else {
                    throw RouteStorageError.writeFailed
                }
            }

            try protect(fileURL, as: .file)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            writeAttempted = true
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try protect(fileURL, as: .file)
            try protect(directoryURL, as: .directory)
        } catch {
            if writeAttempted {
                throw RouteStorageError.writeOutcomeUncertain
            }
            throw Self.storageError(for: error)
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

        try prepareDirectory()
        let temporaryURL = directoryURL.appendingPathComponent(".route-history-\(UUID().uuidString).pending")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try RouteStoreFiles.writeNewFile(
                data,
                at: temporaryURL,
                readOnly: false,
                seams: RouteStoreSeams(protectAndVerify: protectAndVerify)
            )
            try protect(temporaryURL, as: .file)
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw RouteStorageError.writeFailed
            }
            do {
                try protect(fileURL, as: .file)
                try RouteStoreFiles.synchronizeFile(fileURL)
                try RouteStoreFiles.synchronizeDirectory(directoryURL)
            } catch {
                throw RouteStorageError.writeOutcomeUncertain
            }
        } catch {
            throw Self.storageError(for: error)
        }
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw RouteStorageError.writeFailed
        }

        try protect(directoryURL, as: .directory)
    }

    private func resolveTrustedLocalApplicationSupportURL() throws {
        guard let trustedURL = trustedLocalApplicationSupportURL else {
            return
        }

        var path = trustedURL.path
        guard trustedURL.isFileURL,
              trustedURL.host == nil || trustedURL.host == "" || trustedURL.host == "localhost",
              path.hasPrefix("/"),
              !path.contains("\0"),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw RouteStorageError.writeFailed
        }

        var missingComponents: [String] = []
        while true {
            if let resolved = realpath(path, nil) {
                defer { Darwin.free(resolved) }
                var info = stat()
                guard lstat(resolved, &info) == 0,
                      (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw RouteStorageError.writeFailed
                }
                var canonicalPath = String(cString: resolved)
                for component in missingComponents.reversed() {
                    canonicalPath = (canonicalPath as NSString).appendingPathComponent(component)
                }
                fileURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
                    .appendingPathComponent("Keepsake", isDirectory: true)
                    .appendingPathComponent("route-history.jsonl")
                trustedLocalApplicationSupportURL = nil
                return
            }

            var info = stat()
            guard lstat(path, &info) != 0,
                  errno == ENOENT else {
                throw RouteStorageError.writeFailed
            }
            let component = (path as NSString).lastPathComponent
            let parentPath = (path as NSString).deletingLastPathComponent
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  parentPath != path else {
                throw RouteStorageError.writeFailed
            }
            missingComponents.append(component)
            path = parentPath
        }
    }

    private func protect(_ url: URL, as item: RouteStoreProtectedItem) throws {
        do {
            try protectAndVerify(url, item)
        } catch {
            throw Self.storageError(for: error)
        }
    }

    private static func protectArchiveItem(_ url: URL, as item: RouteStoreProtectedItem) throws {
        do {
            if item == .file {
                try RouteStoreFiles.validateOwnedRegularFile(url, requirePrivate: false)
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch {
                    throw RouteStorageError.protectionFailed
                }
            }
            try RouteStoreFiles.protectAndVerify(url, as: item)
        } catch {
            throw storageError(for: error)
        }
    }

    private static func storageError(for error: Error) -> RouteStorageError {
        if let storageError = error as? RouteStorageError {
            return storageError
        }
        guard let storeError = error as? RouteStoreError else {
            return .writeFailed
        }
        switch storeError {
        case .protectionFailed:
            return .protectionFailed
        case .backupExclusionFailed:
            return .backupExclusionFailed
        default:
            return .writeFailed
        }
    }
}
