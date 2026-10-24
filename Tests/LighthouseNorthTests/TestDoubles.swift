import Foundation
@testable import LighthouseNorthClient

// ---------------------------------------------------------------------------
// Test doubles — ZERO rede real (engine scriptado; scheduler com tempo
// virtual). Paridade com o harness JVM do client-android.
// ---------------------------------------------------------------------------

/// Engine que registra pedidos e responde de um script.
final class RecordingEngine: HttpEngine, @unchecked Sendable {
    struct Call: Equatable {
        let method: String
        let url: String
        let headers: [String: String]
        let body: String
        var path: String {
            // omittingEmptySubsequences: false preserva o "//" do esquema —
            // sem isso o dropFirst(3) engolia o 1º segmento real do path.
            url.split(separator: "/", omittingEmptySubsequences: false)
                .dropFirst(3).joined(separator: "/")
        }
        var json: [String: Any] {
            (Json.decode(body) as? [String: Any]) ?? [:]
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// Script: cada entrada responde um pedido; erro lançável para falha de rede.
    private var script: [Result<HttpResponseData, Error>] = []

    func enqueue(status: Int, body: String = "{\"ok\":true}") {
        lock.lock(); defer { lock.unlock() }
        script.append(.success(HttpResponseData(statusCode: status, body: body)))
    }

    func enqueue(networkError: Error) {
        lock.lock(); defer { lock.unlock() }
        script.append(.failure(networkError))
    }

    func execute(_ request: HttpRequestData) async throws -> HttpResponseData {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(method: request.method, url: request.url, headers: request.headers, body: request.body))
        guard !script.isEmpty else {
            throw URLError(.badServerResponse) // script curto = bug do teste
        }
        return try script.removeFirst().get()
    }
}

/// Scheduler com tempo virtual: registra delays sem executar nada até o
/// teste disparar manualmente.
final class ManualScheduler: SdkScheduler, @unchecked Sendable {
    final class ScheduledTask {
        let delayMs: Int64
        let action: @Sendable () async -> Void
        var cancelled = false

        init(delayMs: Int64, action: @escaping @Sendable () async -> Void) {
            self.delayMs = delayMs
            self.action = action
        }
    }

    private let lock = NSLock()
    private var _scheduled: [ScheduledTask] = []
    private var _sleeps: [Int64] = []
    private var _asyncActions: [@Sendable () async -> Void] = []

    var scheduled: [ScheduledTask] {
        lock.lock(); defer { lock.unlock() }
        return _scheduled
    }

    var sleeps: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return _sleeps
    }

    var asyncActions: [@Sendable () async -> Void] {
        lock.lock(); defer { lock.unlock() }
        return _asyncActions
    }

    func sleep(milliseconds: Int64) async {
        lock.lock(); defer { lock.unlock() }
        _sleeps.append(milliseconds)
    }

    func schedule(
        afterMilliseconds delay: Int64,
        action: @escaping @Sendable () async -> Void
    ) -> Cancellable {
        let task = ScheduledTask(delayMs: delay, action: action)
        lock.lock()
        _scheduled.append(task)
        lock.unlock()
        return ManualCancellable(task: task)
    }

    func executeAsync(_ action: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        _asyncActions.append(action)
    }

    /// Dispara a tarefa não cancelada mais antiga (tick do heartbeat).
    @discardableResult
    func runNext() async -> Bool {
        lock.lock()
        guard let task = _scheduled.first(where: { !$0.cancelled }) else {
            lock.unlock()
            return false
        }
        task.cancelled = true
        lock.unlock()
        await task.action()
        return true
    }
}

final class ManualCancellable: Cancellable {
    private let task: ManualScheduler.ScheduledTask

    init(task: ManualScheduler.ScheduledTask) {
        self.task = task
    }

    func cancel() {
        task.cancelled = true
    }
}

/// Gateway de permissão fake.
final class FakePermissionGateway: PermissionGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var _granted: Bool
    private var _requestCount = 0

    var granted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _granted
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    init(granted: Bool = true) {
        self._granted = granted
    }

    func isGranted() -> Bool { granted }

    func request() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
        return _granted
    }
}

/// Harness — monta LighthouseNorthClient com TUDO fake.
@discardableResult
func makeHarness(
    engine: RecordingEngine = RecordingEngine(),
    store: InMemoryStateStore = InMemoryStateStore(),
    tokens: FakeTokenProvider = FakeTokenProvider(),
    permissions: FakePermissionGateway = FakePermissionGateway(),
    scheduler: ManualScheduler = ManualScheduler(),
    random: SdkRandom = FixedSdkRandom(0.5),
    clock: SdkClock = FakeSdkClock(),
    baseUrl: String = "https://api.lighthouse-north.test"
) throws -> (client: LighthouseNorthClient, engine: RecordingEngine, store: InMemoryStateStore,
             tokens: FakeTokenProvider, permissions: FakePermissionGateway,
             scheduler: ManualScheduler, logger: InMemoryLogger) {
    let logger = InMemoryLogger()
    let client = try LighthouseNorthClient.initialize(
        appKey: "ak_test_0000000000000000000000000001",
        apiBaseUrl: baseUrl,
        configuration: .init(
            logger: logger,
            engine: engine,
            tokenProvider: tokens,
            stateStore: store,
            permissions: permissions,
            clock: clock,
            random: random,
            scheduler: scheduler
        )
    )
    return (client, engine, store, tokens, permissions, scheduler, logger)
}

let appKeyForTests = "ak_test_0000000000000000000000000001"
let tokenForTests = "fake-apns-token-0123456789abcdef"
