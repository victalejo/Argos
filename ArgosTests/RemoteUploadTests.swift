//
//  RemoteUploadTests.swift
//  ArgosTests
//
//  Subidas a /tmp: nombres no adivinables y apertura exclusiva con permisos privados.
//

import Testing
import Foundation
@testable import Argos

@Suite("Subidas privadas a /tmp")
struct RemoteUploadTests {

    @Test func lasCapturasVanAUnaRutaConParteAleatoria() {
        let first = RemoteUpload.pastedPath(fileExtension: "png")
        let second = RemoteUpload.pastedPath(fileExtension: "png")
        #expect(first != second)
        #expect(first.hasPrefix("/tmp/argos-pasted-"))
        #expect(first.hasSuffix(".png"))
    }

    @Test func dosSubidasEnElMismoInstanteNoColisionan() {
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(RemoteUpload.droppedPath(originalName: "a.txt", now: date)
            != RemoteUpload.droppedPath(originalName: "a.txt", now: date))
    }

    @Test func elNombreArrastradoSeSanea() {
        let path = RemoteUpload.droppedPath(originalName: "../../etc/mi archivo;rm.txt")
        #expect(path.hasPrefix("/tmp/argos-"))
        #expect(path.hasSuffix("-mi_archivo_rm.txt"))
        #expect(!path.dropFirst(5).contains("/"))
    }

    @Test func unNombreVacioTieneRespaldo() {
        #expect(RemoteUpload.droppedPath(originalName: "").hasSuffix("-archivo"))
    }

    @Test func abreDeFormaExclusivaYSinTruncar() {
        // SSH_FXF_WRITE | SSH_FXF_CREAT | SSH_FXF_EXCL: falla si ya existe (o es un enlace).
        #expect(RemoteUpload.exclusiveOpenFlags == 0x02 | 0x08 | 0x20)
    }

    @Test func losPermisosSonSoloParaElPropietario() {
        #expect(RemoteUpload.privatePermissions == 0o600)
    }
}
