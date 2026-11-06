//
//  SSHServerResources.swift
//  Argos
//
//  Lectura de recursos del servidor por el CANAL DE COMANDOS (no por el PTY): un único
//  comando que vuelca `/proc` y `df`/`ps` en secciones separadas por `@@`, para que cada
//  refresco del monitor cueste un solo round-trip. Lo parsea `ServerResourceParser`.
//

import Foundation

extension SSHService {

    /// Comando remoto del monitor. Solo lectura; si falta `/proc` (servidor no Linux)
    /// la salida queda incompleta y el parser lanza `.unsupported`.
    static let resourcesCommand = [
        "cat /proc/loadavg",
        "head -1 /proc/stat",
        "grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo",
        "nproc",
        "cut -d' ' -f1 /proc/uptime",
        "df -Pk / | tail -1",
        "ps -eo pid=,pcpu=,pmem=,comm= --sort=-pcpu | head -8",
    ].joined(separator: " && echo '\(ServerResourceParser.separator)' && ")

    /// Toma una muestra de recursos del servidor.
    func resourceSample() async throws -> ServerResourceSample {
        let client = try await connectedClient()
        let result = try await capture(client, command: Self.resourcesCommand)
        return try ServerResourceParser.parse(result.stdout)
    }
}
