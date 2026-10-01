//
//  SuspensionPolicyTests.swift
//  ArgosTests
//
//  La app no debe generar tráfico SSH proactivo cuando el Mac está en reposo o
//  la app no está en uso (el bug: heartbeat + sondeo + autoreconnect seguían
//  abriendo conexiones toda la noche).
//

import Testing
@testable import Argos

@Suite("SuspensionPolicy.shouldSuspend")
struct SuspensionPolicyTests {

    @Test("App activa y sistema despierto => no suspender")
    func activeAndAwake() {
        #expect(SuspensionPolicy.shouldSuspend(appActive: true, systemAwake: true) == false)
    }

    @Test("App inactiva => suspender aunque el sistema siga despierto")
    func appInactive() {
        #expect(SuspensionPolicy.shouldSuspend(appActive: false, systemAwake: true) == true)
    }

    @Test("Mac en reposo => suspender aunque la app siga activa")
    func systemAsleep() {
        #expect(SuspensionPolicy.shouldSuspend(appActive: true, systemAwake: false) == true)
    }

    @Test("Reposo + inactiva => suspender")
    func both() {
        #expect(SuspensionPolicy.shouldSuspend(appActive: false, systemAwake: false) == true)
    }
}
