import Foundation
import Supabase

typealias BackendFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

struct BackendConfiguration: Sendable {
    let url: URL
    let publishableKey: String
    let namespace: String
    static let sessionKey = "keepsake.auth.session.v1"

    init(info: [String: Any]) throws {
        guard let rawURL = info["KeepsakeSupabaseURL"] as? String,
              let url = URL(string: rawURL), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              let key = info["KeepsakeSupabasePublishableKey"] as? String,
              key.hasPrefix("sb_publishable_"), key.count > "sb_publishable_".count,
              !key.contains(where: { $0.isWhitespace }),
              let bundle = info["CFBundleIdentifier"] as? String, !bundle.contains("$("),
              let environment = info["KeepsakeEnvironment"] as? String,
              !environment.isEmpty, environment.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            throw AppServiceError.configurationUnavailable
        }
        self.url = url
        publishableKey = key
        let port = url.port.map { $0 == 443 ? "" : ".port-\($0)" } ?? ""
        namespace = "\(bundle).\(environment).\(host.lowercased())\(port)"
    }
}

struct AuthCredentialStore: Sendable {
    let storage: any AuthLocalStorage
    static let markerKey = "keepsake.auth.local-signout.v1"
    static let ownedKeys = [BackendConfiguration.sessionKey, BackendConfiguration.sessionKey + "-code-verifier", "supabase.session"]

    func isLocked() throws -> Bool {
        do { return try storage.retrieve(key: Self.markerKey) != nil }
        catch { throw AppServiceError.localStorage }
    }

    private struct Marker: Codable { let accountID: UUID? }

    func lock(accountID: UUID? = nil) throws {
        do {
            if try isLocked(), try lockedAccount() != nil || accountID == nil { return }
            try storage.store(key: Self.markerKey, value: JSONEncoder().encode(Marker(accountID: accountID)))
            guard try isLocked() else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }

    func lockedAccount() throws -> AccountID? {
        do {
            guard let data = try storage.retrieve(key: Self.markerKey) else { return nil }
            return try JSONDecoder().decode(Marker.self, from: data).accountID.map { AccountID(rawValue: $0) }
        } catch { throw AppServiceError.localStorage }
    }

    func clearCredentials() throws {
        do {
            for key in Self.ownedKeys { try storage.remove(key: key) }
            for key in Self.ownedKeys {
                guard try storage.retrieve(key: key) == nil else { throw AppServiceError.localStorage }
            }
        } catch { throw AppServiceError.localStorage }
    }

    func unlock() throws {
        do {
            try storage.remove(key: Self.markerKey)
            guard try !isLocked() else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }

    func storedSession() throws -> Session? {
        do {
            guard let data = try storage.retrieve(key: BackendConfiguration.sessionKey) else { return nil }
            return try JSONDecoder().decode(Session.self, from: data)
        } catch { throw AppServiceError.localStorage }
    }
}

actor SupabaseBackend: IdentityService, IdentityEventSource, GroupService {
    private struct Clients: Sendable {
        let auth: AuthClient
        let databaseURL: URL
        let publishableKey: String
        let fetch: BackendFetch

        init(configuration: BackendConfiguration, storage: any AuthLocalStorage, fetch: @escaping BackendFetch) {
            databaseURL = configuration.url.appendingPathComponent("rest/v1")
            publishableKey = configuration.publishableKey
            self.fetch = fetch
            auth = AuthClient(configuration: .init(
                url: configuration.url.appendingPathComponent("auth/v1"),
                headers: ["apikey": configuration.publishableKey],
                storageKey: BackendConfiguration.sessionKey,
                localStorage: storage,
                logger: nil,
                fetch: fetch,
                autoRefreshToken: false,
                emitLocalSessionAsInitialSession: false
            ))
        }

        func database(session: Session) -> PostgrestClient {
            PostgrestClient(url: databaseURL, headers: [
                "apikey": publishableKey, "Authorization": "Bearer \(session.accessToken)"
            ], logger: nil, fetch: fetch, retryEnabled: false)
        }
    }

    private let client: Clients
    private let credentials: AuthCredentialStore
    private let cache: any AccountGroupCaching
    private let latch: LocalSignOutLatch
    private let effects = SerializedEffects()
    private var events: AsyncStream<Void>?
    private var registration: (any AuthStateChangeListenerRegistration)?

    init(configuration: BackendConfiguration, cache: any AccountGroupCaching, latch: LocalSignOutLatch, storage: (any AuthLocalStorage)? = nil,
         fetch: @escaping BackendFetch = { try await URLSession.shared.data(for: $0) }) {
        self.cache = cache
        self.latch = latch
        let storage = storage ?? KeychainLocalStorage(service: configuration.namespace, accessGroup: nil)
        credentials = AuthCredentialStore(storage: storage)
        client = Clients(configuration: configuration, storage: storage, fetch: fetch)
    }

    nonisolated func prepareForSignOut(account: AccountID?) throws {
        try latch.lock(account: account)
        try credentials.lock(accountID: account?.rawValue)
    }

    private func serialized<T: Sendable>(_ operation: @escaping @Sendable (Clients, AuthCredentialStore, LocalSignOutLatch) async throws -> T) async throws -> T {
        let client = client
        let credentials = credentials
        let latch = latch
        let effect = await effects.submit { try await operation(client, credentials, latch) }
        return try await effect.value
    }

    func changes() async throws -> AsyncStream<Void> {
        if let events { return events }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = try await serialized { client, credentials, latch in
            guard try latch.read() == nil, !credentials.isLocked() else { throw AppServiceError.localStorage }
            return await client.auth.onAuthStateChange { _, _ in pair.continuation.yield(()) }
        }
        registration = handle
        events = pair.stream
        return pair.stream
    }

    func restore() async throws -> AccountIdentity? {
        let cache = cache
        return try await serialized { client, credentials, latch in
            let marker = try latch.read()
            if try marker != nil || credentials.isLocked() {
                let account = try marker?.account ?? credentials.lockedAccount()
                    ?? (try? credentials.storedSession()).map { AccountID(rawValue: $0.user.id) }
                try latch.lock(account: account)
                try credentials.lock(accountID: account?.rawValue)
                _ = try? await client.auth.signOut(scope: .local)
                try credentials.clearCredentials()
                if let account { try cache.invalidate(account) }
                try credentials.unlock()
                try latch.unlock()
                return nil
            }
            let stored = try credentials.storedSession()
            do { return Self.identity(try await client.auth.session) }
            catch AuthError.sessionMissing {
                if stored != nil { throw AppServiceError.localStorage }
                return nil
            } catch {
                if Self.isConnectionError(error), let stored { return Self.identity(stored) }
                if let auth = error as? AuthError,
                   ["refresh_token_not_found", "refresh_token_already_used", "session_not_found", "session_expired", "user_banned"].contains(auth.errorCode.rawValue) {
                    try credentials.lock(accountID: stored?.user.id)
                    try latch.lock(account: stored.map { AccountID(rawValue: $0.user.id) })
                    _ = try? await client.auth.signOut(scope: .local)
                    try credentials.clearCredentials()
                    if let account = try credentials.lockedAccount() { try cache.invalidate(account) }
                    try credentials.unlock()
                    try latch.unlock()
                    return nil
                }
                throw Self.safeError(error)
            }
        }
    }

    func sendEmailCode(to email: String) async throws {
        try await serialized { client, credentials, latch in
            guard try latch.read() == nil, !credentials.isLocked() else { throw AppServiceError.localStorage }
            do { try await client.auth.signInWithOTP(email: email, shouldCreateUser: true) }
            catch { throw Self.safeError(error) }
        }
    }

    func verifyEmailCode(_ code: String, email: String) async throws -> AccountIdentity {
        try await serialized { client, credentials, latch in
            guard try latch.read() == nil, !credentials.isLocked() else { throw AppServiceError.localStorage }
            do {
                let response = try await client.auth.verifyOTP(email: email, token: code, type: .email)
                guard let session = response.session, !session.isExpired,
                      let stored = try credentials.storedSession(),
                      stored.user.id == session.user.id, stored.refreshToken == session.refreshToken else { throw AppServiceError.localStorage }
                return Self.identity(session)
            } catch { throw Self.safeError(error) }
        }
    }

    func signOutOnThisDevice() async throws {
        let cache = cache
        try await serialized { client, credentials, latch in
            let account = try latch.read()?.account ?? credentials.lockedAccount()
                ?? (try? credentials.storedSession()).map { AccountID(rawValue: $0.user.id) }
            try latch.lock(account: account)
            try credentials.lock(accountID: account?.rawValue)
            var remoteFailed = false
            do { try await client.auth.signOut(scope: .local) }
            catch { remoteFailed = true }
            try credentials.clearCredentials()
            if let account { try cache.invalidate(account) }
            try credentials.unlock()
            try latch.unlock()
            if remoteFailed { throw AppServiceError.remoteSignOutUnconfirmed }
        }
    }

    func loadSoloGroup(for context: AccountContext) async throws -> SoloGroup? {
        try await serialized { client, credentials, latch in
            let database = try await Self.authorize(client, credentials, latch, context)
            do { return try await Self.readGroup(database, account: context.accountID) }
            catch { throw Self.safeError(error) }
        }
    }

    func createSoloGroup(_ intent: GroupCreateIntent, for context: AccountContext) async throws -> SoloGroup {
        try await serialized { client, credentials, latch in
            let database = try await Self.authorize(client, credentials, latch, context)
            guard GroupNameInput.normalize(intent.normalizedName) == intent.normalizedName else { throw AppServiceError.rejected("Use a valid group name.") }
            struct Parameters: Encodable { let p_operation_id: UUID; let p_name: String }
            struct Response: Decodable { let outcome: String; let group: GroupRow }
            do {
                let response: Response = try await database.rpc("create_solo_group", params: Parameters(p_operation_id: intent.operationID, p_name: intent.normalizedName)).execute().value
                guard ["created", "replayed"].contains(response.outcome) else { throw AppServiceError.invalidResponse }
                let group = try response.group.domain(account: context.accountID)
                guard let confirmed = try await Self.readGroup(database, account: context.accountID), confirmed == group else { throw AppServiceError.invalidResponse }
                return confirmed
            } catch let error as PostgrestError {
                if error.code == "KSG01" { throw AppServiceError.rejected("Use a group name of 1–80 characters without control characters.") }
                if error.code == "KSG02" { throw AppServiceError.groupExists }
                throw AppServiceError.outcomeUncertain
            } catch { throw AppServiceError.outcomeUncertain }
        }
    }

    private static func authorize(_ client: Clients, _ credentials: AuthCredentialStore, _ latch: LocalSignOutLatch, _ context: AccountContext) async throws -> PostgrestClient {
        guard try latch.read() == nil, !credentials.isLocked() else { throw AppServiceError.localStorage }
        do {
            let session = try await client.auth.session
            guard try latch.read() == nil, !credentials.isLocked(),
                  !session.isExpired, session.user.id == context.accountID.rawValue else { throw AppServiceError.invalidResponse }
            return client.database(session: session)
        } catch { throw safeError(error) }
    }

    private struct GroupRow: Decodable {
        let id: UUID
        let owner_id: UUID
        let name: String
        let created_at: Date

        func domain(account: AccountID) throws -> SoloGroup {
            guard owner_id == account.rawValue, GroupNameInput.normalize(name) == name else { throw AppServiceError.invalidResponse }
            return SoloGroup(id: GroupID(rawValue: id), ownerID: account, name: name, createdAt: created_at)
        }
    }

    private struct MemberRow: Decodable {
        let group_id: UUID
        let user_id: UUID
        let role: String
    }

    private static func readGroup(_ client: PostgrestClient, account: AccountID) async throws -> SoloGroup? {
        let rows: [GroupRow] = try await client.from("groups").select("id,owner_id,name,created_at").eq("owner_id", value: account.rawValue.uuidString).limit(2).execute().value
        guard rows.count <= 1 else { throw AppServiceError.invalidResponse }
        guard let row = rows.first else { return nil }
        let members: [MemberRow] = try await client.from("group_members").select("group_id,user_id,role").eq("group_id", value: row.id.uuidString).limit(2).execute().value
        guard members.count == 1, let member = members.first,
              member.user_id == account.rawValue, member.group_id == row.id, member.role == "owner" else { throw AppServiceError.invalidResponse }
        return try row.domain(account: account)
    }

    private static func identity(_ session: Session) -> AccountIdentity {
        AccountIdentity(id: AccountID(rawValue: session.user.id), email: session.user.email)
    }

    private static func isConnectionError(_ error: any Error) -> Bool { error is URLError }

    private static func safeError(_ error: any Error) -> AppServiceError {
        if let error = error as? AppServiceError { return error }
        if isConnectionError(error) { return .offline }
        if let error = error as? AuthError {
            if ["otp_expired", "invalid_credentials"].contains(error.errorCode.rawValue) { return .invalidCode }
            if ["over_request_rate_limit", "over_email_send_rate_limit"].contains(error.errorCode.rawValue) { return .rejected("Too many requests. Wait a little before trying again.") }
        }
        return .rejected("The service could not complete this request. Check your connection and app configuration, then retry.")
    }
}

actor SerializedEffects {
    private var tail: Task<Void, Never>?

    func submit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return task
    }
}
