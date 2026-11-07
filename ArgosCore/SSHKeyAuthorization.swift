//
//  SSHKeyAuthorization.swift
//  Argos
//
//  Añade y retira claves públicas del `~/.ssh/authorized_keys` del servidor. Lo usa
//  «Enviar al iPhone»: el Mac (que ya tiene acceso) autoriza una clave nueva creada
//  solo para el iPhone, y la retira si el usuario cancela.
//

import Foundation

extension SSHService {
    /// Añade `line` al final de `authorized_keys` (crea `~/.ssh` con permisos 0700 y el
    /// archivo con 0600 si no existen).
    static func authorizeKeyCommand(line: String) -> String {
        "umask 077 && mkdir -p \"$HOME/.ssh\" && "
            + "printf '%s\\n' \(ShellQuoting.singleQuoted(line)) >> \"$HOME/.ssh/authorized_keys\""
    }

    /// Reescribe `authorized_keys` sin las líneas que contienen ` <comment>`. Solo
    /// sobrescribe si `grep` terminó bien (0 = quedan líneas, 1 = no queda ninguna); con
    /// `cat >` el archivo conserva sus permisos y propietario.
    static func revokeKeyCommand(comment: String) -> String {
        "f=\"$HOME/.ssh/authorized_keys\"; [ -f \"$f\" ] || exit 0; "
            + "grep -vF -- \(ShellQuoting.singleQuoted(" " + comment)) \"$f\" > \"$f.argos\"; "
            + "s=$?; if [ $s -le 1 ]; then cat \"$f.argos\" > \"$f\"; fi; rm -f \"$f.argos\"; [ $s -le 1 ]"
    }

    func authorizeKey(line: String) async throws {
        try await runManagementCommand(Self.authorizeKeyCommand(line: line))
    }

    func revokeKey(comment: String) async throws {
        try await runManagementCommand(Self.revokeKeyCommand(comment: comment))
    }
}
