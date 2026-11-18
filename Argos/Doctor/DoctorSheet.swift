//
//  DoctorSheet.swift
//  Argos
//
//  Hoja «Doctor del servidor» del Mac: una comprobación remota con estado, explicación y
//  arreglo por fila, más «Copiar diagnóstico» (informe para pegar en un issue). Toda la lógica
//  (qué es aviso o problema) vive en `ArgosCore/Doctor`; aquí solo se pinta.
//
//  Presentación:   .sheet(isPresented: $show) {
//                      DoctorSheet(service: service, serverName: server.name, knownServers: store.servers)
//                  }
//

import AppKit
import SwiftUI

struct DoctorSheet: View {
    let knownServers: [Server]

    @State private var model: DoctorModel
    @State private var includesPersonalData = false
    @State private var includesTechnicalDetail = false
    @State private var copyState: CopyState = .idle
    @Environment(\.dismiss) private var dismiss

    private enum CopyState { case idle, working, copied }

    init(service: any SSHServicing, serverName: String, knownServers: [Server] = []) {
        self.knownServers = knownServers
        _model = State(initialValue: DoctorModel(service: service, serverName: serverName))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .task { if model.state == .idle { await model.run() } }
        .alert("No se pudo completar", isPresented: errorBinding) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.fixError ?? "")
        }
    }

    // MARK: - Partes

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Doctor del servidor").font(.headline)
                Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        if let result = model.result { return "\(model.serverName) · \(result.summary)" }
        return model.serverName
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Comprobando el servidor…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("No se pudo comprobar el servidor").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Volver a comprobar") { Task { await model.run() } }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let result):
            List(result.checks) { check in
                DoctorCheckRow(check: check, isFixing: model.fixing == check.id) { fix in
                    Task { await model.apply(fix, to: check.id) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Incluir nombres, usuarios e IPs", isOn: $includesPersonalData)
                    .help("Por defecto el diagnóstico los sustituye por marcadores como «servidor-1». Argos oculta los secretos que reconoce; revisa el texto antes de publicarlo.")
                Toggle("Incluir detalle técnico del registro", isOn: $includesTechnicalDetail)
                    .help("Añade entradas de depuración y del agente, que pueden contener texto del servidor.")
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button {
                Task { await copyDiagnostic() }
            } label: {
                switch copyState {
                case .idle: Label("Copiar diagnóstico", systemImage: "doc.on.doc")
                case .working: Label("Preparando…", systemImage: "hourglass")
                case .copied: Label("Copiado", systemImage: "checkmark")
                }
            }
            .disabled(copyState == .working)
            Button("Volver a comprobar") { Task { await model.run() } }
                .disabled(model.isLoading)
            Button("Cerrar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.fixError != nil }, set: { if !$0 { model.fixError = nil } })
    }

    private func copyDiagnostic() async {
        copyState = .working
        let text = await DiagnosticReport.collect(
            doctor: model.result, serverName: model.serverName,
            knownServers: knownServers.map(DiagnosticRedactor.KnownServer.init),
            includePersonalData: includesPersonalData,
            includesTechnicalDetail: includesTechnicalDetail
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyState = .copied
        try? await Task.sleep(for: .seconds(2))
        copyState = .idle
    }
}

private struct DoctorCheckRow: View {
    let check: DoctorCheck
    let isFixing: Bool
    let onFix: (DoctorFix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = check.fix { fixView(fix) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(check.status.label): \(check.title)")
    }

    @ViewBuilder
    private func fixView(_ fix: DoctorFix) -> some View {
        switch fix {
        case .installClaudeHooks(let isUpdate):
            Button(isUpdate ? "Actualizar hooks" : "Instalar hooks") { onFix(fix) }
                .disabled(isFixing)
        case .installPortsSkill(let isUpdate):
            Button(isUpdate ? "Actualizar skill" : "Instalar skill") { onFix(fix) }
                .disabled(isFixing)
        case .copyCommand(let command):
            HStack {
                Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                Button("Copiar comando") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    private var symbol: String {
        switch check.status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        case .unknown: return .secondary
        }
    }
}
