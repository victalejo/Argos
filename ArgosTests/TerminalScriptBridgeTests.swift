//
//  TerminalScriptBridgeTests.swift
//  ArgosTests
//
//  «Abrir en Terminal con Claude Code» en el canal App Store: el script de usuario
//  (Application Scripts) define un handler que recibe el comando, y Argos lo invoca
//  con un Apple Event de subrutina. Estos tests fijan ese contrato.
//

import Carbon
import Foundation
import Testing
@testable import Argos

@Suite("Puente de AppleScript hacia Terminal (App Store)")
struct TerminalScriptBridgeTests {

    @Test("El script define el handler, abre Terminal y declara su versión")
    func scriptSource() {
        let source = TerminalScriptBridge.scriptSource
        #expect(source.contains("on \(TerminalScriptBridge.handlerName)(comando)"))
        #expect(source.contains("tell application id \"com.apple.Terminal\""))
        #expect(source.contains("do script comando"))
        #expect(source.contains("return \(TerminalScriptBridge.scriptVersion)"))
    }

    @Test("El nombre del handler va en minúsculas (AppleScript lo exige en el evento)")
    func handlerIsLowercase() {
        #expect(TerminalScriptBridge.handlerName == TerminalScriptBridge.handlerName.lowercased())
    }

    @Test("El Apple Event es una subrutina con el nombre del handler y el comando como único argumento")
    func appleEvent() throws {
        let command = "cd '/Users/ana/x' && claude"
        let event = TerminalScriptBridge.appleEvent(handler: TerminalScriptBridge.handlerName, arguments: [command])

        #expect(event.eventClass == AEEventClass(kASAppleScriptSuite))
        #expect(event.eventID == AEEventID(kASSubroutineEvent))
        let name = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName)))
        #expect(name.stringValue == TerminalScriptBridge.handlerName)
        let args = try #require(event.paramDescriptor(forKeyword: keyDirectObject))
        #expect(args.numberOfItems == 1)
        #expect(args.atIndex(1)?.stringValue == command)
    }

    @Test("El archivo del script se llama igual que espera la instalación")
    func scriptFileName() {
        #expect(TerminalScriptBridge.scriptFileName.hasSuffix(".scpt"))
    }

    @Test("Instalación: solo vale guardar en la carpeta de scripts con el nombre esperado")
    func validatesInstallDestination() {
        let dir = URL(fileURLWithPath: "/Users/ana/Library/Application Scripts/com.iaportafolio.argos", isDirectory: true)
        let good = dir.appendingPathComponent(TerminalScriptBridge.scriptFileName)
        #expect(TerminalScriptBridge.isValidDestination(good, scriptsDirectory: dir))
        #expect(!TerminalScriptBridge.isValidDestination(dir.appendingPathComponent("otro.scpt"), scriptsDirectory: dir))
        #expect(!TerminalScriptBridge.isValidDestination(
            URL(fileURLWithPath: "/Users/ana/Desktop").appendingPathComponent(TerminalScriptBridge.scriptFileName),
            scriptsDirectory: dir))
    }

    @Test("Mensaje para el resultado «falta instalar el script»")
    func needsScriptMessage() {
        let message = LocalTerminalLauncher.message(for: .needsScriptInstall)
        #expect(message?.contains("Ajustes") == true)
    }
}
