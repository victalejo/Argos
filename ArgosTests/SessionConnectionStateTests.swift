//
//  SessionConnectionStateTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("SessionConnectionState.from")
struct SessionConnectionStateTests {

    @Test("Conectando => connecting (independiente de isAttached)")
    func connecting() {
        #expect(SessionConnectionState.from(status: .connecting, isAttached: false) == .connecting)
        #expect(SessionConnectionState.from(status: .connecting, isAttached: true) == .connecting)
    }

    @Test("Conectado => live")
    func live() {
        #expect(SessionConnectionState.from(status: .connected, isAttached: false) == .live)
    }

    @Test("Fallo => error")
    func error() {
        #expect(SessionConnectionState.from(status: .failed("boom"), isAttached: true) == .error)
    }

    @Test("Sin terminal cargado y sin adjuntar => dormant")
    func dormant() {
        #expect(SessionConnectionState.from(status: nil, isAttached: false) == .dormant)
    }

    @Test("Sin terminal cargado pero adjunta en tmux => attachedElsewhere")
    func elsewhere() {
        #expect(SessionConnectionState.from(status: nil, isAttached: true) == .attachedElsewhere)
    }

    @Test("Detach limpio: dormant o attachedElsewhere según tmux")
    func ended() {
        #expect(SessionConnectionState.from(status: .ended, isAttached: false) == .dormant)
        #expect(SessionConnectionState.from(status: .ended, isAttached: true) == .attachedElsewhere)
    }
}
