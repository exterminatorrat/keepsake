import Foundation
import Testing
@testable import Keepsake

@MainActor
struct LocationAuthorizationObserverTests {
    @Test func authorizationChangesAndRequestsUseTheInjectedClient() {
        let client = TestAuthorizationClient(authorization: .notDetermined, fullAccuracy: false)
        let observer = LocationAuthorizationObserver(
            authorizationClient: client,
            servicesStatusSource: FixedLocationServicesStatusSource(enabled: false)
        )
        var changeCount = 0
        observer.onChange = { changeCount += 1 }

        client.updateAuthorization(.whileInUse)
        observer.requestWhenInUseAuthorization()

        #expect(observer.capabilities.authorization == .whileInUse)
        #expect(!observer.capabilities.fullAccuracy)
        #expect(changeCount == 1)
        #expect(client.authorizationRequestCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func serviceRefreshesCoalesceAndApplyOnlyTheNewestResult() async {
        let client = TestAuthorizationClient(authorization: .whileInUse, fullAccuracy: true)
        let services = GatedLocationServicesStatusSource()
        let observer = LocationAuthorizationObserver(
            authorizationClient: client,
            servicesStatusSource: services
        )

        await services.waitForCall(1)
        client.updateAuthorization(.always)
        client.updateAuthorization(.whileInUse)
        await services.resolve(call: 1, enabled: true)
        await services.waitForCall(2)
        #expect(!observer.capabilities.servicesEnabled)
        #expect(await services.callCount == 2)

        await confirmation("applies the newest service status", expectedCount: 1) { confirm in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                observer.onChange = {
                    confirm()
                    continuation.resume()
                }
                Task {
                    await services.resolve(call: 2, enabled: true)
                }
            }
        }

        #expect(observer.capabilities.servicesEnabled)
        #expect(await services.callCount == 2)
    }
}

@MainActor
private final class TestAuthorizationClient: LocationAuthorizationClient {
    private(set) var authorization: LocationAuthorization
    let fullAccuracy: Bool
    var onChange: (() -> Void)?
    private(set) var authorizationRequestCount = 0

    init(authorization: LocationAuthorization, fullAccuracy: Bool) {
        self.authorization = authorization
        self.fullAccuracy = fullAccuracy
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func updateAuthorization(_ authorization: LocationAuthorization) {
        self.authorization = authorization
        onChange?()
    }
}

private struct FixedLocationServicesStatusSource: LocationServicesStatusSource {
    let enabled: Bool

    func servicesEnabled() async -> Bool {
        enabled
    }
}

private actor GatedLocationServicesStatusSource: LocationServicesStatusSource {
    private var callCountStorage = 0
    private var continuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var callCount: Int {
        callCountStorage
    }

    func servicesEnabled() async -> Bool {
        callCountStorage += 1
        let call = callCountStorage
        resumeCallWaiters()
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func waitForCall(_ expected: Int) async {
        guard callCountStorage < expected else {
            return
        }

        await withCheckedContinuation { continuation in
            callWaiters.append((expected, continuation))
        }
    }

    func resolve(call: Int, enabled: Bool) {
        continuations.removeValue(forKey: call)?.resume(returning: enabled)
    }

    private func resumeCallWaiters() {
        let ready = callWaiters.filter { $0.0 <= callCountStorage }
        callWaiters.removeAll { $0.0 <= callCountStorage }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}
