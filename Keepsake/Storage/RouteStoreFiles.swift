import Foundation
import Darwin

enum RouteStoreProtectedItem: Equatable, Sendable {
    case directory
    case file
    case sidecar
}

enum RouteStoreCapacityCheck: Equatable, Sendable {
    case create
    case openExisting
    case migration
    case append
    case retention
    case clear
    case export
}

struct RouteStoreFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ info: stat) {
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

struct RouteStoreSeams: Sendable {
    let protectAndVerify: @Sendable (URL, RouteStoreProtectedItem) throws -> Void
    let requireCapacity: @Sendable (URL, Int64, RouteStoreCapacityCheck) throws -> Void
    let fault: @Sendable (RouteStoreFaultPoint) throws -> Void
    let readProtection: @Sendable (URL) throws -> FileProtectionType?

    init(
        protectAndVerify: @escaping @Sendable (URL, RouteStoreProtectedItem) throws -> Void = {
            try RouteStoreFiles.protectAndVerify($0, as: $1)
        },
        requireCapacity: @escaping @Sendable (URL, Int64, RouteStoreCapacityCheck) throws -> Void = { url, bytes, _ in
            try RouteStoreFiles.requireCapacity(at: url, requiredBytes: bytes)
        },
        fault: @escaping @Sendable (RouteStoreFaultPoint) throws -> Void = { _ in },
        readProtection: @escaping @Sendable (URL) throws -> FileProtectionType? = {
            try RouteStoreFiles.readProtection(at: $0)
        }
    ) {
        self.protectAndVerify = protectAndVerify
        self.requireCapacity = requireCapacity
        self.fault = fault
        self.readProtection = readProtection
    }
}

enum RouteStoreFiles {
    static let databaseName = "route.sqlite"
    static let manifestName = "manifest.json"
    static let snapshotName = "source-snapshot.jsonl"
    static let lockName = ".route-store.lock"
    static let maximumLegacySourceBytes = 64 * 1_024 * 1_024

    struct FileSignature: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    struct StableFile: Sendable {
        let data: Data
        let signature: FileSignature
    }

    static func prepareNewRoot(_ rootURL: URL, seams: RouteStoreSeams) throws -> RouteStoreFileIdentity {
        let parentURL = rootURL.deletingLastPathComponent()
        try validateNewRoot(rootURL)
        try seams.requireCapacity(parentURL, 1_048_576, .create)

        guard mkdir(posixPath(rootURL), mode_t(0o700)) == 0 else {
            if errno == EEXIST {
                throw RouteStoreError.destinationExists
            }
            throw RouteStoreError.writeFailed
        }

        guard chmod(posixPath(rootURL), mode_t(0o700)) == 0 else {
            throw RouteStoreError.protectionFailed
        }

        try validateOwnedDirectory(parentURL, requirePrivate: false)
        try validateOwnedDirectory(rootURL, requirePrivate: true)
        let identity = try captureIdentity(at: rootURL, directory: true)
        try seams.protectAndVerify(rootURL, .directory)
        try verifyIdentity(at: rootURL, matches: identity, directory: true)
        try synchronizeDirectory(parentURL)
        return identity
    }

    static func validateExistingRoot(_ rootURL: URL, seams: RouteStoreSeams) throws -> RouteStoreFileIdentity {
        let parentURL = rootURL.deletingLastPathComponent()
        try validateOwnedDirectory(parentURL, requirePrivate: false)
        try validateOwnedDirectory(rootURL, requirePrivate: true)
        let identity = try captureIdentity(at: rootURL, directory: true)
        try seams.protectAndVerify(rootURL, .directory)
        try verifyIdentity(at: rootURL, matches: identity, directory: true)
        return identity
    }

    static func acquireExclusiveLock(at rootURL: URL, seams: RouteStoreSeams) throws -> Int32 {
        let lockURL = rootURL.appendingPathComponent(lockName, isDirectory: false)
        let descriptor = open(posixPath(lockURL), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw RouteStoreError.unsafePath
        }

        do {
            try validateOwnedRegularFile(lockURL, requirePrivate: true, requireReadOnly: false)
            try seams.protectAndVerify(lockURL, .file)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw RouteStoreError.lockUnavailable
            }
            var openedInfo = stat()
            var namedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0,
                  lstat(posixPath(lockURL), &namedInfo) == 0,
                  openedInfo.st_dev == namedInfo.st_dev,
                  openedInfo.st_ino == namedInfo.st_ino else {
                throw RouteStoreError.unsafePath
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func createDatabaseFile(at url: URL, seams: RouteStoreSeams) throws -> RouteStoreFileIdentity {
        let descriptor = open(posixPath(url), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw RouteStoreError.unsafePath
            }
            throw RouteStoreError.writeFailed
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegularFile(info.st_mode),
              info.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw RouteStoreError.unsafePath
        }
        let identity = RouteStoreFileIdentity(info)
        do {
            try validateOwnedRegularFile(url, requirePrivate: true, requireReadOnly: false)
            try verifyIdentity(at: url, matches: identity, directory: false, descriptor: descriptor)
            try seams.protectAndVerify(url, .file)
            try verifyIdentity(at: url, matches: identity, directory: false, descriptor: descriptor)
            guard fsync(descriptor) == 0 else {
                throw RouteStoreError.writeFailed
            }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw RouteStoreError.writeFailed
        }
        try verifyIdentity(at: url, matches: identity, directory: false)
        return identity
    }

    static func validateOwnedDirectory(_ url: URL, requirePrivate: Bool) throws {
        try validateCanonicalPath(url, allowMissingFinal: false)
        var info = stat()
        guard lstat(posixPath(url), &info) == 0,
              isDirectory(info.st_mode),
              info.st_uid == geteuid(),
              (info.st_mode & mode_t(0o022)) == 0 else {
            throw RouteStoreError.unsafePath
        }
        if requirePrivate && (info.st_mode & mode_t(0o077)) != 0 {
            throw RouteStoreError.unsafePath
        }
    }

    static func validateOwnedRegularFile(
        _ url: URL,
        requirePrivate: Bool,
        requireReadOnly: Bool = false
    ) throws {
        try validateCanonicalPath(url, allowMissingFinal: false)
        var info = stat()
        guard lstat(posixPath(url), &info) == 0,
              isRegularFile(info.st_mode),
              info.st_uid == geteuid() else {
            throw RouteStoreError.unsafePath
        }
        if requirePrivate && (info.st_mode & mode_t(0o077)) != 0 {
            throw RouteStoreError.unsafePath
        }
        if requireReadOnly && (info.st_mode & mode_t(0o222)) != 0 {
            throw RouteStoreError.unsafePath
        }
    }

    static func captureIdentity(at url: URL, directory: Bool) throws -> RouteStoreFileIdentity {
        if directory {
            try validateOwnedDirectory(url, requirePrivate: true)
        } else {
            try validateOwnedRegularFile(url, requirePrivate: true)
        }
        var info = stat()
        guard lstat(posixPath(url), &info) == 0 else {
            throw RouteStoreError.unsafePath
        }
        return RouteStoreFileIdentity(info)
    }

    static func verifyIdentity(
        at url: URL,
        matches expected: RouteStoreFileIdentity,
        directory: Bool,
        descriptor: Int32? = nil
    ) throws {
        guard try captureIdentity(at: url, directory: directory) == expected else {
            throw RouteStoreError.unsafePath
        }
        if let descriptor {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  RouteStoreFileIdentity(info) == expected,
                  info.st_uid == geteuid(),
                  directory ? isDirectory(info.st_mode) : isRegularFile(info.st_mode) else {
                throw RouteStoreError.unsafePath
            }
        }
    }

    static func openIdentityDescriptor(
        at url: URL,
        directory: Bool = false,
        matching expected: RouteStoreFileIdentity? = nil
    ) throws -> (descriptor: Int32, identity: RouteStoreFileIdentity) {
        if directory {
            try validateOwnedDirectory(url, requirePrivate: true)
        } else {
            try validateOwnedRegularFile(url, requirePrivate: true)
        }
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)
        let descriptor = open(posixPath(url), flags)
        guard descriptor >= 0 else {
            throw RouteStoreError.unsafePath
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              directory ? isDirectory(info.st_mode) : isRegularFile(info.st_mode),
              info.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw RouteStoreError.unsafePath
        }
        let identity = RouteStoreFileIdentity(info)
        do {
            guard expected == nil || identity == expected else {
                throw RouteStoreError.unsafePath
            }
            try verifyIdentity(at: url, matches: identity, directory: directory, descriptor: descriptor)
            return (descriptor, identity)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func readStableRegularFile(
        at url: URL,
        maximumBytes: Int? = nil,
        maximumSizeError: RouteStoreError = .sourceTooLarge
    ) throws -> StableFile {
        try validateCanonicalPath(url, allowMissingFinal: false)
        let descriptor = open(posixPath(url), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RouteStoreError.unreadableSource
        }
        defer { _ = Darwin.close(descriptor) }

        var initialInfo = stat()
        guard fstat(descriptor, &initialInfo) == 0,
              isRegularFile(initialInfo.st_mode),
              initialInfo.st_uid == geteuid(),
              initialInfo.st_size >= 0,
              initialInfo.st_size <= Int64(Int.max) else {
            throw RouteStoreError.unsafePath
        }

        if let maximumBytes {
            guard maximumBytes >= 0, initialInfo.st_size <= Int64(maximumBytes) else {
                throw maximumSizeError
            }
        }

        var data = Data()
        data.reserveCapacity(Int(initialInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 {
                break
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw RouteStoreError.unreadableSource
            }
            if let maximumBytes {
                let (newCount, overflow) = data.count.addingReportingOverflow(readCount)
                guard !overflow, newCount <= maximumBytes else {
                    throw maximumSizeError
                }
            }
            data.append(contentsOf: buffer.prefix(readCount))
        }

        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              FileSignature(initialInfo) == FileSignature(finalInfo),
              Int64(data.count) == finalInfo.st_size else {
            throw RouteStoreError.sourceChanged
        }
        return StableFile(data: data, signature: FileSignature(finalInfo))
    }

    static func verifyUnchanged(_ file: StableFile, at url: URL, maximumBytes: Int? = nil) throws {
        let current = try readStableRegularFile(at: url, maximumBytes: maximumBytes)
        guard current.signature == file.signature, current.data == file.data else {
            throw RouteStoreError.sourceChanged
        }
    }

    static func readManifest(at url: URL) throws -> Data {
        do {
            try validateOwnedRegularFile(url, requirePrivate: true, requireReadOnly: true)
            return try readStableRegularFile(at: url, maximumBytes: 65_536, maximumSizeError: .invalidManifest).data
        } catch let error as RouteStoreError {
            throw error
        } catch {
            throw RouteStoreError.invalidManifest
        }
    }

    static func writeNewFile(
        _ data: Data,
        at url: URL,
        readOnly: Bool,
        seams: RouteStoreSeams,
        protectedItem: RouteStoreProtectedItem = .file
    ) throws {
        let parentURL = url.deletingLastPathComponent()
        try validateOwnedDirectory(parentURL, requirePrivate: false)
        try validateCanonicalPath(url, allowMissingFinal: true)

        let descriptor = open(posixPath(url), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw RouteStoreError.unsafePath
            }
            throw RouteStoreError.writeFailed
        }

        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              isRegularFile(openedInfo.st_mode),
              openedInfo.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw RouteStoreError.unsafePath
        }
        let identity = RouteStoreFileIdentity(openedInfo)
        do {
            try validateOwnedRegularFile(url, requirePrivate: true)
            try verifyIdentity(at: url, matches: identity, directory: false, descriptor: descriptor)
            try seams.protectAndVerify(url, protectedItem)
            try verifyIdentity(at: url, matches: identity, directory: false, descriptor: descriptor)

            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let result = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: written), bytes.count - written)
                    if result < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw RouteStoreError.writeFailed
                    }
                    guard result > 0 else {
                        throw RouteStoreError.writeFailed
                    }
                    written += result
                }
            }

            if readOnly && fchmod(descriptor, mode_t(0o400)) != 0 {
                throw RouteStoreError.protectionFailed
            }
            guard fsync(descriptor) == 0 else {
                throw RouteStoreError.writeFailed
            }
            try validateOwnedRegularFile(url, requirePrivate: true, requireReadOnly: readOnly)
            try verifyIdentity(at: url, matches: identity, directory: false, descriptor: descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else {
            throw RouteStoreError.writeFailed
        }
        try synchronizeDirectory(parentURL)
    }

    static func publishManifest(
        _ data: Data,
        in rootURL: URL,
        seams: RouteStoreSeams,
        verifyStoreIdentities: () throws -> Void
    ) throws {
        let finalURL = rootURL.appendingPathComponent(manifestName, isDirectory: false)
        var info = stat()
        if lstat(posixPath(finalURL), &info) == 0 || errno != ENOENT {
            throw RouteStoreError.invalidManifest
        }

        let temporaryURL = rootURL.appendingPathComponent(".manifest-\(UUID().uuidString).pending", isDirectory: false)
        try writeNewFile(data, at: temporaryURL, readOnly: true, seams: seams)
        if lstat(posixPath(finalURL), &info) == 0 || errno != ENOENT {
            throw RouteStoreError.invalidManifest
        }
        try verifyStoreIdentities()
        try publishStagedFile(temporaryURL, at: finalURL, collision: .invalidManifest)
    }

    static func writeCompatibleExport(_ data: Data, to destinationURL: URL, seams: RouteStoreSeams) throws {
        let parentURL = destinationURL.deletingLastPathComponent()
        try validateOwnedDirectory(parentURL, requirePrivate: false)
        try validateCanonicalPath(destinationURL, allowMissingFinal: true)
        var info = stat()
        if lstat(posixPath(destinationURL), &info) == 0 || errno != ENOENT {
            throw RouteStoreError.destinationExists
        }
        let (twiceDataSize, overflow) = Int64(data.count).multipliedReportingOverflow(by: 2)
        guard !overflow else {
            throw RouteStoreError.insufficientSpace
        }
        try seams.requireCapacity(parentURL, max(1_048_576, twiceDataSize), .export)

        let temporaryURL = parentURL.appendingPathComponent(".route-export-\(UUID().uuidString).pending", isDirectory: false)
        try writeNewFile(data, at: temporaryURL, readOnly: true, seams: seams)
        if lstat(posixPath(destinationURL), &info) == 0 || errno != ENOENT {
            throw RouteStoreError.destinationExists
        }
        try publishStagedFile(temporaryURL, at: destinationURL, collision: .destinationExists)
    }

    static func requireCapacity(at url: URL, requiredBytes: Int64) throws {
        let available: Int?
        do {
            available = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        } catch {
            throw RouteStoreError.insufficientSpace
        }
        guard let available, available >= 0, requiredBytes >= 0 else {
            throw RouteStoreError.insufficientSpace
        }
        let capacity = Int64(available)
        let (doubled, overflow) = requiredBytes.multipliedReportingOverflow(by: 2)
        guard !overflow, capacity >= max(1_048_576, doubled) else {
            throw RouteStoreError.insufficientSpace
        }
    }

    static func readProtection(at url: URL) throws -> FileProtectionType? {
        let attributes = try FileManager.default.attributesOfItem(atPath: posixPath(url))
        return attributes[.protectionKey] as? FileProtectionType
    }

    static func protectAndVerify(
        _ url: URL,
        as item: RouteStoreProtectedItem,
        readProtection: (URL) throws -> FileProtectionType? = { url in
            try RouteStoreFiles.readProtection(at: url)
        }
    ) throws {
        switch item {
        case .directory:
            try validateOwnedDirectory(url, requirePrivate: false)
        case .file, .sidecar:
            try validateOwnedRegularFile(url, requirePrivate: true)
        }

        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: posixPath(url)
            )
        } catch {
            throw RouteStoreError.protectionFailed
        }

        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            // A previously sealed manifest/snapshot may be read-only. Verify
            // existing exclusion rather than trying to rewrite identical metadata.
            mutableURL.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
            if try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true {
                try mutableURL.setResourceValues(resourceValues)
            }
            mutableURL.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        } catch {
            throw RouteStoreError.backupExclusionFailed
        }

        do {
            guard try readProtection(url) == .completeUntilFirstUserAuthentication else {
                throw RouteStoreError.protectionFailed
            }
            let excluded = try mutableURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            guard excluded == true else {
                throw RouteStoreError.backupExclusionFailed
            }
        } catch let error as RouteStoreError {
            throw error
        } catch {
            throw RouteStoreError.protectionFailed
        }
    }

    static func existingDatabaseSidecars(in rootURL: URL) throws -> [URL] {
        let databaseURL = rootURL.appendingPathComponent(databaseName, isDirectory: false)
        let sidecars = ["-journal", "-wal", "-shm"].map {
            URL(fileURLWithPath: databaseURL.path + $0, isDirectory: false)
        }
        var existing: [URL] = []
        for sidecar in sidecars {
            var info = stat()
            if lstat(posixPath(sidecar), &info) == 0 {
                guard isRegularFile(info.st_mode), info.st_uid == geteuid() else {
                    throw RouteStoreError.unsafePath
                }
                existing.append(sidecar)
            } else if errno != ENOENT {
                throw RouteStoreError.unsafePath
            }
        }
        return existing
    }

    static func synchronizeFile(_ url: URL) throws {
        try validateOwnedRegularFile(url, requirePrivate: true)
        let descriptor = open(posixPath(url), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RouteStoreError.writeFailed
        }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RouteStoreError.writeFailed
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        try validateOwnedDirectory(url, requirePrivate: false)
        let descriptor = open(posixPath(url), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw RouteStoreError.writeFailed
        }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RouteStoreError.writeFailed
        }
    }

    private static func publishStagedFile(_ temporaryURL: URL, at finalURL: URL, collision: RouteStoreError) throws {
        guard link(posixPath(temporaryURL), posixPath(finalURL)) == 0 else {
            if errno == EEXIST {
                throw collision
            }
            throw RouteStoreError.writeFailed
        }
        try synchronizeDirectory(finalURL.deletingLastPathComponent())
        guard unlink(posixPath(temporaryURL)) == 0 else {
            throw RouteStoreError.writeFailed
        }
        try synchronizeDirectory(finalURL.deletingLastPathComponent())
    }

    static func exactSampleEquality(_ lhs: RouteSample, _ rhs: RouteSample) -> Bool {
        lhs.id == rhs.id
            && lhs.recordingID == rhs.recordingID
            && lhs.observedAt.timeIntervalSinceReferenceDate.bitPattern == rhs.observedAt.timeIntervalSinceReferenceDate.bitPattern
            && lhs.latitude.bitPattern == rhs.latitude.bitPattern
            && lhs.longitude.bitPattern == rhs.longitude.bitPattern
            && lhs.horizontalAccuracy.bitPattern == rhs.horizontalAccuracy.bitPattern
            && optionalBitsEqual(lhs.altitude, rhs.altitude)
            && optionalBitsEqual(lhs.verticalAccuracy, rhs.verticalAccuracy)
            && optionalBitsEqual(lhs.speed, rhs.speed)
            && optionalBitsEqual(lhs.speedAccuracy, rhs.speedAccuracy)
            && optionalBitsEqual(lhs.course, rhs.course)
            && optionalBitsEqual(lhs.courseAccuracy, rhs.courseAccuracy)
            && lhs.isStationary == rhs.isStationary
    }

    static func exactSamplesEquality(_ lhs: [RouteSample], _ rhs: [RouteSample]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { exactSampleEquality($0.0, $0.1) }
    }

    static func legacyRepresentable(_ samples: [RouteSample]) -> Bool {
        var ids: Set<UUID> = []
        var fingerprints: Set<RouteSampleFingerprint> = []
        var previousDate: Date?

        for sample in samples {
            guard sample.isValid,
                  ids.insert(sample.id).inserted,
                  fingerprints.insert(sample.fingerprint).inserted,
                  previousDate.map({ sample.observedAt > $0 }) ?? true else {
                return false
            }
            previousDate = sample.observedAt
            do {
                let encoded = try JSONEncoder().encode(sample)
                let decoded = try JSONDecoder().decode(RouteSample.self, from: encoded)
                guard exactSampleEquality(sample, decoded) else {
                    return false
                }
            } catch {
                return false
            }
        }
        return true
    }

    private static func optionalBitsEqual(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.bitPattern == right.bitPattern
        default:
            return false
        }
    }

    static func validatedRootURL(_ url: URL) throws -> URL {
        // Validate the caller's scheme, authority and literal path before a new
        // file URL could discard them. Initialization still rechecks identity.
        try validateCanonicalPath(url, allowMissingFinal: true)
        return URL(fileURLWithPath: posixPath(url), isDirectory: false)
    }

    static func validateNewRoot(_ url: URL) throws {
        try validateCanonicalPath(url, allowMissingFinal: true)
        let parentURL = url.deletingLastPathComponent()
        try validateOwnedDirectory(parentURL, requirePrivate: false)
        var info = stat()
        if lstat(posixPath(url), &info) == 0 {
            if isSymbolicLink(info.st_mode) {
                throw RouteStoreError.unsafePath
            }
            throw RouteStoreError.destinationExists
        }
        guard errno == ENOENT else {
            throw RouteStoreError.unsafePath
        }
    }

    static func validateNewFileDestination(_ url: URL) throws {
        let parentURL = url.deletingLastPathComponent()
        try validateOwnedDirectory(parentURL, requirePrivate: false)
        try validateCanonicalPath(url, allowMissingFinal: true)
        var info = stat()
        if lstat(posixPath(url), &info) == 0 {
            if isSymbolicLink(info.st_mode) {
                throw RouteStoreError.unsafePath
            }
            throw RouteStoreError.destinationExists
        }
        guard errno == ENOENT else {
            throw RouteStoreError.unsafePath
        }
    }

    private static func validateCanonicalPath(_ url: URL, allowMissingFinal: Bool) throws {
        let path = posixPath(url)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost",
              path.hasPrefix("/"),
              !path.contains("\0"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RouteStoreError.unsafePath
        }

        // Foundation can rewrite iOS's canonical /private/var prefix back to its
        // /var alias. Validate the literal POSIX path, never a rewritten URL.
        var cursor = ""
        for (index, component) in components.enumerated() {
            cursor += "/" + component
            var info = stat()
            if lstat(cursor, &info) != 0 {
                if allowMissingFinal && index == components.count - 1 && errno == ENOENT {
                    continue
                }
                throw RouteStoreError.unsafePath
            }
            guard !isSymbolicLink(info.st_mode) else {
                throw RouteStoreError.unsafePath
            }
            if index < components.count - 1 && !isDirectory(info.st_mode) {
                throw RouteStoreError.unsafePath
            }
        }

        if !allowMissingFinal {
            guard let resolved = realpath(path, nil) else {
                throw RouteStoreError.unsafePath
            }
            defer { Darwin.free(resolved) }
            guard String(cString: resolved) == path else {
                throw RouteStoreError.unsafePath
            }
        }
    }

    private static func isDirectory(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func isSymbolicLink(_ mode: mode_t) -> Bool {
        (mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
    }

    private static func posixPath(_ url: URL) -> String {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
