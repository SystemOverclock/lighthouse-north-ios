import XCTest
@testable import LighthouseNorthClient

/// Transporte: TLS-only, headers minimizados, retry exato (500→1s→2s com
/// jitter ±25%, máx. 3, só 408/429/5xx) + estado versionado — paridade com
/// as suítes Flutter/Android. ZERO rede real.
///
/// NOTA DE EVIDÊNCIA (frente B 3.3): testes ESCRITOS e revisados, mas NÃO
/// EXECUTADOS nesta máquina (Windows — swift test exige macOS; ver README
/// "Build pendente macOS").
final class TransportAndStateTests: XCTestCase {

    // ------------------------------------------------------------------
    // Base URL
    // ------------------------------------------------------------------

    func testHttpsAceito() throws {
        let url = try HttpTransport.validateBaseUrl("https://api.exemplo.com/")
        XCTAssertEqual(url.host, "api.exemplo.com")
    }

    func testHttpLoopbackAceitoParaDevTestes() throws {
        XCTAssertEqual(try HttpTransport.validateBaseUrl("http://localhost:3000").host, "localhost")
        XCTAssertEqual(try HttpTransport.validateBaseUrl("http://127.0.0.1:3000").host, "127.0.0.1")
    }

    func testHttpForaDeLoopbackRejeitado() {
        XCTAssertThrowsError(try HttpTransport.validateBaseUrl("http://api.exemplo.com")) { error in
            guard case LighthouseNorthError.insecureBaseUrl = error else {
                return XCTFail("esperava insecureBaseUrl, veio \(error)")
            }
        }
    }

    func testBaseUrlMalformadaRejeitada() {
        XCTAssertThrowsError(try HttpTransport.validateBaseUrl("não é url"))
        XCTAssertThrowsError(try HttpTransport.validateBaseUrl("ftp://x.com"))
        XCTAssertThrowsError(try HttpTransport.validateBaseUrl("https://x.com?q=1"))
        XCTAssertThrowsError(try HttpTransport.validateBaseUrl("https://user:pw@x.com"))
    }

    // ------------------------------------------------------------------
    // Request exato + retry
    // ------------------------------------------------------------------

    func testRequestTemExatamenteOsHeadersDoContrato() async throws {
        let engine = RecordingEngine()
        engine.enqueue(status: 201)
        let transport = try HttpTransport(
            engine: engine,
            baseUrl: "https://api.lighthouse-north.test",
            appKey: appKeyForTests,
            scheduler: ManualScheduler(),
            random: FixedSdkRandom(0.5),
            logger: NoopLogger()
        )

        _ = try await transport.postJson("/v1/devices", body: ["token": tokenForTests])

        let call = try XCTUnwrap(engine.calls.first)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.url, "https://api.lighthouse-north.test/v1/devices")
        XCTAssertEqual(call.headers["x-app-key"], appKeyForTests)
        XCTAssertEqual(call.headers["accept"], "application/json")
        XCTAssertEqual(call.headers["content-type"], "application/json; charset=utf-8")
        XCTAssertEqual(call.headers["user-agent"], "lighthouse-north-client-ios/0.1.0 (swift;ios)")
        // Minimização: NENHUM header além dos 4 do contrato.
        XCTAssertEqual(Set(call.headers.keys), ["x-app-key", "accept", "user-agent", "content-type"])
    }

    func test5xxTenta3VezesComBackoffExato() async throws {
        let engine = RecordingEngine()
        engine.enqueue(status: 500)
        engine.enqueue(status: 503)
        engine.enqueue(status: 200)
        let scheduler = ManualScheduler()
        let transport = try HttpTransport(
            engine: engine, baseUrl: "https://api.lighthouse-north.test", appKey: appKeyForTests,
            scheduler: scheduler, random: FixedSdkRandom(0.5), logger: NoopLogger()
        )

        let status = try await transport.postJson("/v1/devices", body: [:])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(engine.calls.count, 3)
        // FixedSdkRandom(0.5) → fator exatamente 1.0.
        XCTAssertEqual(scheduler.sleeps, [500, 1000])
    }

    func testStatusNaoRetryaveis() {
        for status in [408, 429, 500, 503] {
            XCTAssertTrue(RetryPolicy.isRetryableStatus(status), "esperava retry em \(status)")
        }
        for status in [400, 401, 403, 404, 409, 422] {
            XCTAssertFalse(RetryPolicy.isRetryableStatus(status), "não esperava retry em \(status)")
        }
    }

    func test401ViraUnauthorizedSemRetry() async throws {
        let engine = RecordingEngine()
        engine.enqueue(status: 401, body: "{\"error\":\"unauthorized\"}")
        let transport = try HttpTransport(
            engine: engine, baseUrl: "https://api.lighthouse-north.test", appKey: appKeyForTests,
            scheduler: ManualScheduler(), random: FixedSdkRandom(0.5), logger: NoopLogger()
        )

        do {
            _ = try await transport.postJson("/v1/devices", body: [:])
            XCTFail("esperava unauthorizedAppKey")
        } catch let error as LighthouseNorthError {
            guard case LighthouseNorthError.unauthorizedAppKey = error else {
                return XCTFail("esperava unauthorizedAppKey, veio \(error)")
            }
        }
        XCTAssertEqual(engine.calls.count, 1)
    }

    func testFalhaDeRedePersistenteViraNetworkError() async throws {
        let engine = RecordingEngine()
        for _ in 0..<3 { engine.enqueue(networkError: URLError(.notConnectedToInternet)) }
        let scheduler = ManualScheduler()
        let transport = try HttpTransport(
            engine: engine, baseUrl: "https://api.lighthouse-north.test", appKey: appKeyForTests,
            scheduler: scheduler, random: FixedSdkRandom(0.5), logger: NoopLogger()
        )

        do {
            _ = try await transport.postJson("/v1/devices", body: [:])
            XCTFail("esperava network")
        } catch let error as LighthouseNorthError {
            guard case LighthouseNorthError.network = error else {
                return XCTFail("esperava network, veio \(error)")
            }
        }
        XCTAssertEqual(engine.calls.count, 3)
        XCTAssertEqual(scheduler.sleeps, [500, 1000])
    }

    func testJitterMultiplicaBackoffEntre075e125() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(for: 1, random: FixedSdkRandom(0.0)), 375)
        XCTAssertEqual(policy.delay(for: 1, random: FixedSdkRandom(1.0)), 625)
        XCTAssertEqual(policy.delay(for: 2, random: FixedSdkRandom(0.0)), 750)
        XCTAssertEqual(policy.delay(for: 3, random: FixedSdkRandom(1.0)), 2500)
    }

    // ------------------------------------------------------------------
    // Estado versionado (§5)
    // ------------------------------------------------------------------

    func testEstadoRoundTripExato() throws {
        let state = DeviceState(
            platform: .ios,
            token: tokenForTests,
            contactRef: "cliente-42",
            policyVersion: "2026-09",
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000),
            heartbeatActive: true,
            heartbeatIntervalMs: 86_400_000
        )
        let json = StateCodec.toJsonString(state)
        let keys = Set((Json.decode(json) as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(
            keys,
            ["v", "platform", "token", "contactRef", "policyVersion",
             "registeredAt", "heartbeatActive", "heartbeatIntervalMs"]
        )
        XCTAssertEqual(StateCodec.fromJsonString(json), state)
    }

    func testEstadoCorrompidoOuVersaoDesconhecidaEDescartado() {
        XCTAssertNil(StateCodec.fromJsonString("não é json"))
        XCTAssertNil(StateCodec.fromJsonString("{\"v\":99}"))
        XCTAssertNil(StateCodec.fromJsonString("{\"v\":1,\"platform\":\"tvOS\"}"))
    }

    func testRedactMascaraSegredos() {
        XCTAssertEqual(redactSecret(tokenForTests), "fake...cdef")
        XCTAssertEqual(redactSecret("curto"), "***")
    }
}
