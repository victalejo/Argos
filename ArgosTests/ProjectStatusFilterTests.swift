//
//  ProjectStatusFilterTests.swift
//  ArgosTests
//

import Testing
@testable import Argos

@Suite("Filtro de proyectos por estado")
struct ProjectStatusFilterTests {

    @Test("Cada estado de conexión cae en una sola categoría")
    func statusFromConnection() {
        #expect(ProjectStatus.of(connection: nil, onMac: false) == .stopped)
        #expect(ProjectStatus.of(connection: .live, onMac: false) == .open)
        #expect(ProjectStatus.of(connection: .connecting, onMac: false) == .open)
        #expect(ProjectStatus.of(connection: .error, onMac: false) == .open)
        #expect(ProjectStatus.of(connection: .attachedElsewhere, onMac: false) == .background)
        #expect(ProjectStatus.of(connection: .dormant, onMac: false) == .dormant)
    }

    @Test("Enviado al Mac tiene prioridad aunque quede sesión en el servidor")
    func onMacWins() {
        #expect(ProjectStatus.of(connection: nil, onMac: true) == .onMac)
        #expect(ProjectStatus.of(connection: .dormant, onMac: true) == .onMac)
        #expect(ProjectStatus.of(connection: .live, onMac: true) == .onMac)
    }

    @Test("«Todos» incluye todo; cada filtro solo su estado")
    func includes() {
        let all: [ProjectStatus] = [.open, .background, .dormant, .stopped, .onMac]
        #expect(all.allSatisfy(ProjectStatusFilter.all.includes))
        #expect(all.filter(ProjectStatusFilter.open.includes) == [.open])
        #expect(all.filter(ProjectStatusFilter.dormant.includes) == [.dormant])
        #expect(all.filter(ProjectStatusFilter.stopped.includes) == [.stopped])
        #expect(all.filter(ProjectStatusFilter.onMac.includes) == [.onMac])
        #expect(all.filter(ProjectStatusFilter.background.includes) == [.background])
    }

    @Test("Todas las opciones tienen título e icono")
    func labels() {
        for option in ProjectStatusFilter.allCases {
            #expect(!option.title.isEmpty)
            #expect(!option.systemImage.isEmpty)
        }
    }
}
