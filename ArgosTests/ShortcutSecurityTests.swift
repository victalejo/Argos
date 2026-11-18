//
//  ShortcutSecurityTests.swift
//  ArgosTests
//
//  Seguridad del atajo «Pedir a Claude»: el modo aprobado se vuelve a comprobar justo
//  antes de entregar (un cambio a «sin preguntar» entre medias no se cuela), y el bloqueo
//  con Face ID de la app también vale para los atajos y para lo que se ve fuera de ella.
//

import Foundation
import Testing
@testable import Argos

@Suite("Atajos: el modo aprobado se comprueba al entregar")
struct ShortcutDeliveryCheckTests {
    private let bypass = ClaudeAgentCommand.PermissionMode.bypassPermissions.rawValue
    private let acceptEdits = ClaudeAgentCommand.PermissionMode.acceptEdits.rawValue
    private let ask = ClaudeAgentCommand.PermissionMode.default.rawValue
    private let plan = ClaudeAgentCommand.PermissionMode.plan.rawValue

    private func meta(_ mode: String?, folder: String = "/srv/app") -> PersistentAgentMeta {
        PersistentAgentMeta(workingDirectory: folder, title: "app", createdAt: Date(), permissionMode: mode)
    }

    @Test("Mismo modo que el confirmado: se entrega")
    func sameModeDelivers() {
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: bypass, currentRawMode: bypass))
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: acceptEdits, currentRawMode: acceptEdits))
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: "yolo", currentRawMode: "yolo"))
    }

    @Test("Cambiado a uno más permisivo (o desconocido): se niega")
    func morePermissiveRefused() {
        #expect(!ShortcutAgentPlanner.mayDeliver(approvedRawMode: ask, currentRawMode: bypass))
        #expect(!ShortcutAgentPlanner.mayDeliver(approvedRawMode: nil, currentRawMode: acceptEdits))
        #expect(!ShortcutAgentPlanner.mayDeliver(approvedRawMode: acceptEdits, currentRawMode: bypass))
        #expect(!ShortcutAgentPlanner.mayDeliver(approvedRawMode: bypass, currentRawMode: acceptEdits))
        #expect(!ShortcutAgentPlanner.mayDeliver(approvedRawMode: plan, currentRawMode: "yolo"))
    }

    @Test("Cambiado a uno que pregunta: puede seguir")
    func toAskingContinues() {
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: bypass, currentRawMode: ask))
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: bypass, currentRawMode: plan))
        #expect(ShortcutAgentPlanner.mayDeliver(approvedRawMode: bypass, currentRawMode: nil))
    }

    @Test("El agente tiene que seguir ahí y en la carpeta del proyecto")
    func verdict() {
        #expect(ShortcutAgentPlanner.deliveryVerdict(approvedRawMode: bypass, workingDirectory: "/srv/app", current: nil) == .agentGone)
        #expect(ShortcutAgentPlanner.deliveryVerdict(approvedRawMode: bypass, workingDirectory: "/srv/app",
                                                     current: meta(bypass, folder: "/srv/otro")) == .agentMoved)
        #expect(ShortcutAgentPlanner.deliveryVerdict(approvedRawMode: ask, workingDirectory: "/srv/app",
                                                     current: meta(bypass)) == .modeChanged)
        #expect(ShortcutAgentPlanner.deliveryVerdict(approvedRawMode: bypass, workingDirectory: "/srv/app/",
                                                     current: meta(bypass)) == .deliver)
    }

    @Test("Lo aprobado es el texto leído del agente, o el modo con el que se creará")
    func approvedRawMode() {
        let info = PersistentAgentInfo(id: UUID().uuidString.lowercased(), isAlive: false, logBytes: 0, meta: meta(nil))
        #expect(ShortcutAgentPlan.resume(info).approvedRawMode == nil)
        #expect(ShortcutAgentPlan.create(.bypassPermissions).approvedRawMode == bypass)
        // Un agente nuevo en «sin preguntar» pide confirmación mostrando ese modo.
        #expect(ShortcutAgentPlanner.requiresConfirmation(mode: ShortcutAgentPlan.create(.bypassPermissions).permissionMode,
                                                          allowsUnconfirmed: false))
    }
}

@MainActor
@Suite("Atajos: el reanudado del cliente respeta la comprobación")
struct ShortcutResumeGuardTests {
    @Test("Si la comprobación dice que no, no se reanuda ni se envía")
    func guardBlocksResume() async {
        let mock = MockSSHService()
        let info = PersistentAgentInfo(
            id: "6a55640d-ac70-41ab-8426-6eb72d4fb5eb", isAlive: false, logBytes: 10,
            meta: PersistentAgentMeta(workingDirectory: "/srv", title: "srv", createdAt: Date(),
                                      permissionMode: "bypassPermissions", hibernatedAt: Date())
        )
        let session = PersistentAgentSession(service: mock, info: info, hibernation: { .standard })
        let outcome = await session.send("hola", confirmedResume: true) { (_: PersistentAgentMeta) -> Bool in false }
        #expect(outcome == .needsResumeConfirmation)
        #expect(mock.agentCommands.isEmpty)   // no se lanzó ningún claude
        #expect(mock.agentScripts.isEmpty)    // ni se escribió en la FIFO
    }
}

@Suite("Bloqueo de la app en atajos y Spotlight")
struct AppLockShortcutPolicyTests {
    @Test("Sin bloqueo, el atajo sigue; con bloqueo, manda la autenticación")
    func decisions() {
        #expect(!AppLockPolicy.shortcutRequiresAuthentication(enabled: false))
        #expect(AppLockPolicy.shortcutRequiresAuthentication(enabled: true))
        #expect(AppLockPolicy.shortcutDecision(enabled: false, authentication: .refused) == .proceed)
        #expect(AppLockPolicy.shortcutDecision(enabled: true, authentication: .succeeded) == .proceed)
        #expect(AppLockPolicy.shortcutDecision(enabled: true, authentication: .refused) == .refuse)
        #expect(AppLockPolicy.shortcutDecision(enabled: true, authentication: .notPossibleHere) == .continueInApp)
        // Sin código ni biometría la app tampoco se bloquea.
        #expect(AppLockPolicy.shortcutDecision(enabled: true, authentication: .unavailable) == .proceed)
    }

    @Test("Con bloqueo, los nombres de proyecto solo salen fuera de la app si se permite")
    func exposure() {
        #expect(AppLockPolicy.exposesProjectNames(enabled: false, exposesWhenLocked: false))
        #expect(!AppLockPolicy.exposesProjectNames(enabled: true, exposesWhenLocked: false))
        #expect(AppLockPolicy.exposesProjectNames(enabled: true, exposesWhenLocked: true))
    }
}
