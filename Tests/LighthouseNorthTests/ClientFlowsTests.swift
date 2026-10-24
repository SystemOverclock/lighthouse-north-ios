import XCTest
@testable import LighthouseNorthClient

/// Fluxos canônicos do cliente: register (minimização provada por keys
/// exatas), optOut (ordem deliberada + best-effort), watcher, rotação e
/// heartbeat — paridade com as suítes Flutter/Android.
///
/// NOTA DE EVIDÊNCIA (frente B 3.3): testes ESCRITOS e revisados, mas NÃO
/// EXECUTADOS nesta máquina (Windows — swift test exige macOS; ver README
/// "Build pendente macOS").
final class ClientFlowsTests: XCTestCase {

    override func tearDown() {
        LighthouseNorthClient.shared?.close()
    }

    // ------------------------------------------------------------------
    // registerForPush
    // ------------------------------------------------------------------

    func testRegistroFelizEnviaExatamenteOs4CamposDoContrato() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)

        let reg = try await h.client.registerForPush(contactRef: "cliente-42", policyVersion: "2026-09")

        // MINIMIZAÇÃO por asserção de keys exatas:
        let body = try XCTUnwrap(h.engine.calls.first?.json)
        XCTAssertEqual(Set(body.keys), ["platform", "token", "contactRef", "consent"])
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["token"] as? String, tokenForTests)
        XCTAssertEqual(body["contactRef"] as? String, "cliente-42")
        let consent = try XCTUnwrap(body["consent"] as? [String: Any])
        XCTAssertEqual(Set(consent.keys), ["granted", "capturedAt", "policyVersion"])
        XCTAssertEqual(consent["granted"] as? Bool, true)
        XCTAssertEqual(consent["policyVersion"] as? String, "2026-09")
        XCTAssertTrue(
            (consent["capturedAt"] as? String ?? "")
                .range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil
        )

        XCTAssertEqual(h.store.state?.token, tokenForTests)
        XCTAssertEqual(reg.maskedToken, "fake...cdef")
        XCTAssertEqual(reg.updatedExisting, false) // 201 = novo
    }

    func testPermissaoNegadaNaoRegistraENaoGastaRede() async throws {
        let h = try makeHarness(permissions: FakePermissionGateway(granted: false))

        do {
            _ = try await h.client.registerForPush()
            XCTFail("esperava pushPermissionDenied")
        } catch let error as LighthouseNorthError {
            guard case LighthouseNorthError.pushPermissionDenied = error else {
                return XCTFail("esperava pushPermissionDenied, veio \(error)")
            }
        }
        XCTAssertEqual(h.engine.calls.count, 0)
        XCTAssertEqual(h.store.state, nil)
    }

    func testContactRefForaDe1a200FalhaAntesDeRede() async throws {
        let h = try makeHarness()
        for bad in ["", String(repeating: "x", count: 201)] {
            do {
                _ = try await h.client.registerForPush(contactRef: bad)
                XCTFail("esperava invalidInput")
            } catch let error as LighthouseNorthError {
                guard case LighthouseNorthError.invalidInput = error else {
                    return XCTFail("esperava invalidInput, veio \(error)")
                }
            }
        }
        XCTAssertEqual(h.engine.calls.count, 0)
    }

    // ------------------------------------------------------------------
    // optOut
    // ------------------------------------------------------------------

    func testOptOutRevocaConsentAntesDoUnregisterELimpaEstado() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)
        _ = try await h.client.registerForPush(contactRef: "cliente-42", policyVersion: "2026-09")
        h.engine.enqueue(status: 200) // revoke
        h.engine.enqueue(status: 200) // unregister

        let result = await h.client.optOut()

        XCTAssertEqual(result.fullyOptedOut, true)
        XCTAssertEqual(h.engine.calls.count, 3)
        // ORDEM: revoke ANTES do unregister.
        XCTAssertEqual(h.engine.calls[1].path, "v1/devices")
        let revoke = h.engine.calls[1].json
        XCTAssertEqual((revoke["consent"] as? [String: Any])?["granted"] as? Bool, false)
        XCTAssertEqual(revoke["contactRef"] as? String, "cliente-42")
        XCTAssertEqual(h.engine.calls[2].path, "v1/devices/unregister")
        XCTAssertEqual(h.store.state, nil)
    }

    func testFalhaTotalDeRedePreservaEstadoParaRetentar() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)
        _ = try await h.client.registerForPush(contactRef: "cliente-42", policyVersion: nil)
        for _ in 0..<6 { h.engine.enqueue(networkError: URLError(.notConnectedToInternet)) }

        let result = await h.client.optOut()

        XCTAssertEqual(result.fullyOptedOut, false)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(result.stateCleared, false)
        XCTAssertEqual(h.store.state?.token, tokenForTests) // preservado
        XCTAssertEqual(h.store.state?.contactRef, "cliente-42")
    }

    func testSemContactRefOptOutSoUnregister() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)
        _ = try await h.client.registerForPush()
        h.engine.enqueue(status: 200)

        let result = await h.client.optOut()

        XCTAssertEqual(result.consentRevoked, nil) // etapa não aplicável
        XCTAssertEqual(result.unregistered, true)
        XCTAssertEqual(h.engine.calls.count, 2)
        XCTAssertEqual(result.fullyOptedOut, true)
    }

    func testOptOutSemRegistroENoop() async throws {
        let h = try makeHarness()
        let result = await h.client.optOut()
        XCTAssertEqual(result.fullyOptedOut, true)
        XCTAssertEqual(result.hadRegistration, false)
        XCTAssertEqual(h.engine.calls.count, 0)
    }

    // ------------------------------------------------------------------
    // Rotação de token (3.3)
    // ------------------------------------------------------------------

    func testRotacaoRegistraNovoRemoveAntigoEPreservaContactRef() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)
        _ = try await h.client.registerForPush(contactRef: "cliente-42", policyVersion: "2026-09")
        let novo = "fake-apns-token-NOVO-9876543210"
        h.engine.enqueue(status: 200) // register novo
        h.engine.enqueue(status: 200) // unregister antigo

        let result = try await h.client.onNewToken(novo)

        XCTAssertEqual(result.changed, true)
        XCTAssertEqual(result.registered, true)
        XCTAssertEqual(result.oldRemoved, true)

        let register = h.engine.calls[1].json
        XCTAssertEqual(register["token"] as? String, novo)
        XCTAssertEqual(register["contactRef"] as? String, "cliente-42")
        // SEM consent (@gate QA 3.3): rotação não é ato de consentimento —
        // reafirmar granted=true ressuscitaria consentimento revogado no
        // intervalo do optOut parcial (paridade com Kotlin/Flutter).
        XCTAssertNil(register["consent"])
        XCTAssertEqual(h.engine.calls[2].path, "v1/devices/unregister")
        XCTAssertEqual(h.engine.calls[2].json["token"] as? String, tokenForTests)
        XCTAssertEqual(h.store.state?.token, novo)
        XCTAssertEqual(h.store.state?.contactRef, "cliente-42")
    }

    func testRotacaoSemTokenAntigoRegistraSemConsent() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)

        let result = try await h.client.onNewToken("fake-apns-token-NOVO-9876543210")

        XCTAssertEqual(result.oldRemoved, nil)
        XCTAssertEqual(Set(h.engine.calls[0].json.keys), ["platform", "token"])
    }

    func testRotacaoComTokenIgualENoop() async throws {
        let h = try makeHarness()
        h.engine.enqueue(status: 201)
        _ = try await h.client.registerForPush()

        let result = try await h.client.onNewToken(tokenForTests)

        XCTAssertEqual(result.changed, false)
        XCTAssertEqual(h.engine.calls.count, 1)
    }

    // ------------------------------------------------------------------
    // Heartbeat
    // ------------------------------------------------------------------

    func testHeartbeatStartSemTokenNaoAgenda() throws {
        let h = try makeHarness()
        XCTAssertEqual(h.client.startHeartbeat(), false)
        XCTAssertEqual(h.scheduler.scheduled.count, 0)
    }

    func testHeartbeatTickChamaRefreshEReagenda() async throws {
        let h = try makeHarness()
        h.store.write(DeviceState(token: tokenForTests))
        XCTAssertEqual(h.client.startHeartbeat(intervalMs: 60_000), true)
        // FixedSdkRandom(0.5) → fator 1.0 (±10% neutro).
        XCTAssertEqual(h.scheduler.scheduled.first?.delayMs, 60_000)
        h.engine.enqueue(status: 200)

        await h.scheduler.runNext()

        XCTAssertEqual(h.engine.calls.first?.path, "v1/devices/refresh")
        XCTAssertEqual(h.engine.calls.first?.json["token"] as? String, tokenForTests)
        XCTAssertEqual(h.scheduler.scheduled.count, 2) // re-agendado
    }

    func testJitterDoHeartbeatEntre09e11() {
        // O fator é amostrado dentro do scheduleNext; aqui validamos a fórmula
        // documentada via limites do random fixo.
        let base = 100_000.0
        XCTAssertEqual(Int64((base * (0.9 + 0.2 * FixedSdkRandom(0.0).nextDouble())).rounded()), 90_000)
        XCTAssertEqual(Int64((base * (0.9 + 0.2 * FixedSdkRandom(1.0).nextDouble())).rounded()), 110_000)
    }

    func testFalhaDeRedeNoRefreshNaoDerrubaOCiclo() async throws {
        let h = try makeHarness()
        h.store.write(DeviceState(token: tokenForTests))
        _ = h.client.startHeartbeat(intervalMs: 60_000)
        for _ in 0..<3 { h.engine.enqueue(networkError: URLError(.timedOut)) }

        await h.scheduler.runNext()

        XCTAssertEqual(h.engine.calls.count, 3)
        XCTAssertEqual(h.scheduler.scheduled.count, 2) // próximo tick agendado
        XCTAssertEqual(h.client.isHeartbeatRunning, true)
    }

    // ------------------------------------------------------------------
    // App key
    // ------------------------------------------------------------------

    func testAppKeyInvalidaFalhaNoInitialize() {
        XCTAssertThrowsError(
            try LighthouseNorthClient.initialize(appKey: "curta", apiBaseUrl: "https://api.lighthouse-north.test")
        )
        XCTAssertThrowsError(
            try LighthouseNorthClient.initialize(appKey: "ak com espaco0000000000000000", apiBaseUrl: "https://api.lighthouse-north.test")
        )
    }

    func testUnconfiguredTokenProviderErroTipado() async throws {
        let h = try makeHarness(tokens: FakeTokenProvider(token: nil))
        h.engine.enqueue(status: 201)
        // provider default real seria UnconfiguredTokenProvider; o harness
        // injeta fake — aqui exercitamos o unconfigured diretamente.
        let provider = UnconfiguredTokenProvider()
        do {
            _ = try await provider.getToken()
            XCTFail("esperava firebaseNotConfigured")
        } catch let error as LighthouseNorthError {
            guard case LighthouseNorthError.firebaseNotConfigured = error else {
                return XCTFail("esperava firebaseNotConfigured, veio \(error)")
            }
        } catch {
            XCTFail("esperava firebaseNotConfigured, veio \(error)")
        }
        _ = h // silencia unused
    }
}
