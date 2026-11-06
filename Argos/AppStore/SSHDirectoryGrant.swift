//
//  SSHDirectoryGrant.swift
//  Argos
//
//  Panel con el que el usuario concede a Argos la lectura de ~/.ssh (canal App
//  Store, sin excepción temporal de sandbox). Se pide una vez; el permiso queda
//  guardado como bookmark de solo lectura en `SSHDirectoryAccess`.
//

import AppKit

@MainActor
enum SSHDirectoryGrant {

    enum Outcome: Equatable {
        case granted
        case cancelled
        case failed(String)
    }

    /// Abre el panel ya situado en ~/.ssh: basta pulsar «Conceder acceso».
    static func request() -> Outcome {
        let directory = URL(fileURLWithPath: SSHDirectoryAccess.directoryPath(), isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = "Dar acceso a ~/.ssh"
        panel.message = "Argos lee tu ~/.ssh/config y las claves que referencia. "
            + "Pulsa «Conceder acceso» con la carpeta .ssh abierta. Solo se pide una vez y es de solo lectura."
        panel.prompt = "Conceder acceso"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = directory

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard url.standardizedFileURL.path == directory.standardizedFileURL.path else {
            return .failed("Elige la carpeta .ssh de tu usuario (\(directory.path)).")
        }
        do {
            try SSHDirectoryAccess.storeGrant(for: url)
            Log.store.info("Acceso a ~/.ssh concedido")
            return .granted
        } catch {
            Log.store.error("No se pudo guardar el acceso a ~/.ssh: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
