import Foundation
import Testing
@testable import Keepsake

struct LocalCaptureExperimentTests {
    @Test(.timeLimit(.minutes(1)))
    func experimentalEntryRequiresAnExplicitBuildCondition() {
        #if KEEPSAKE_EXPERIMENTAL_LOCAL_CAPTURE
        #expect(LocalCaptureExperiment.isEnabled)
        #else
        #expect(!LocalCaptureExperiment.isEnabled)
        #endif
    }

    @Test(.timeLimit(.minutes(1)))
    func isolatedNamespaceIsASeparateChildWithoutCreatingAnything() throws {
        let parent = try makeExperimentFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = LocalCaptureExperiment.storeURL(in: parent)

        #expect(root.deletingLastPathComponent() == parent)
        #expect(root.lastPathComponent == "Keepsake-Isolated-Capture-v2")
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitOpenNeverCreatesAMissingStore() async throws {
        let parent = try makeExperimentFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = LocalCaptureExperiment.storeURL(in: parent)
        do {
            _ = try await LocalCaptureExperimentStore.open(in: parent, mode: .openExisting, seams: experimentSeams())
            Issue.record("Opening a missing experimental store must fail")
        } catch let error as RouteStoreError {
            #expect(error == .unsafePath)
        } catch {
            Issue.record("Unexpected open error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitCreateCannotOverwriteAndNeverReadsLegacyHistory() async throws {
        let parent = try makeExperimentFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let legacy = parent.appendingPathComponent("legacy.jsonl")
        let original = Data("legacy fixture remains unchanged\n".utf8)
        try original.write(to: legacy)
        let session = try await LocalCaptureExperimentStore.open(in: parent, mode: .createEmpty, seams: experimentSeams())

        let snapshot = try await session.readControl()
        #expect(snapshot.revision == 0)
        #expect(snapshot.activeEpoch == nil)
        #expect(try Data(contentsOf: legacy) == original)
        await session.close()

        do {
            _ = try await LocalCaptureExperimentStore.open(in: parent, mode: .createEmpty, seams: experimentSeams())
            Issue.record("Creating over an existing store must fail")
        } catch let error as RouteStoreError {
            #expect(error == .destinationExists)
        } catch {
            Issue.record("Unexpected creation error: \(error)")
        }
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test(.timeLimit(.minutes(1)))
    func closedSessionCannotBeRevivedByAStaleReconciliationHandle() async throws {
        let parent = try makeExperimentFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try await LocalCaptureExperimentStore.open(in: parent, mode: .createEmpty, seams: experimentSeams())
        await session.close()

        do {
            _ = try await session.reopenVerified()
            Issue.record("An explicitly closed experiment session must remain closed")
        } catch let error as CapturePersistenceError {
            #expect(error == .unavailable(.storeClosed))
        } catch {
            Issue.record("Unexpected reopen error: \(error)")
        }
        do {
            _ = try await session.readControl()
            Issue.record("The stale session must not retain a readable handle")
        } catch let error as CapturePersistenceError {
            #expect(error == .unavailable(.storeClosed))
        } catch {
            Issue.record("Unexpected read error: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedVerifiedReopenKeepsOneCurrentCaptureAndHistoryHandle() async throws {
        let parent = try makeExperimentFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try await LocalCaptureExperimentStore.open(in: parent, mode: .createEmpty, seams: experimentSeams())
        let begin = try await session.beginRecording(recordingID: UUID(), expectedControlRevision: 0, operationID: UUID())
        let stop = try await session.stopRecording(epoch: begin.epoch, expectedControlRevision: 1, operationID: UUID())

        _ = try await session.reopenVerified()
        _ = try await session.reopenVerified()
        let snapshot = try await session.readControl()
        let page = try await session.readPage(
            interval: CapturePageInterval(start: Date(timeIntervalSinceReferenceDate: 0), end: Date(timeIntervalSinceReferenceDate: 200)),
            now: Date(timeIntervalSinceReferenceDate: 100),
            limit: 128,
            cursor: nil
        )
        #expect(snapshot.revision == stop.controlRevision)
        #expect(snapshot.activeEpoch == nil)
        #expect(snapshot.lastControlReceipt == stop)
        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        await session.close()
    }
}

private func makeExperimentFixture() throws -> URL {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("LocalCaptureExperiment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: parent,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return parent
}

private func experimentSeams() -> RouteStoreSeams {
    RouteStoreSeams(protectAndVerify: { url, item in
        #if targetEnvironment(simulator)
        try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
            .completeUntilFirstUserAuthentication
        })
        #else
        try RouteStoreFiles.protectAndVerify(url, as: item)
        #endif
    })
}
