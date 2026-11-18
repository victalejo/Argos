//
//  DoctorScreen.swift
//  ArgosiOS
//
//  Pantalla «Doctor del servidor» de iPhone/iPad: la misma comprobación y las mismas reglas
//  que el Mac (`ArgosCore/Doctor`), con «Copiar diagnóstico» y «Compartir».
//
//  Presentación:   .sheet(isPresented: $showDoctor) {
//                      DoctorScreen(service: service, serverName: server.name, knownServers: store.servers)
//                  }
//  (lleva su propio `NavigationStack`; también sirve con `.fullScreenCover`.)
//

import SwiftUI
import UIKit

struct DoctorScreen: View {
    let knownServers: [Server]

    @State private var model: DoctorModel
    @State private var includesPersonalData = false
    @State private var includesTechnicalDetail = false
    @State private var isPreparing = false
    @State private var copied = false
    @State private var shared: SharedReport?
    @Environment(\.dismiss) private var dismiss

    init(service: any SSHServicing, serverName: String, knownServers: [Server] = []) {
        self.knownServers = knownServers
        _model = State(initialValue: DoctorModel(service: service, serverName: serverName))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Doctor")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Listo") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await model.run() } } label: {
                            Label("Volver a comprobar", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isLoading)
                    }
                }
                .task { if model.state == .idle { await model.run() } }
                .alert("No se pudo completar", isPresented: errorBinding) {
                    Button("Aceptar", role: .cancel) {}
                } message: {
                    Text(model.fixError ?? "")
                }
                .sheet(item: $shared) { report in
                    ActivityView(text: report.text).presentationDetents([.medium, .large])
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Comprobando el servidor…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("No se pudo comprobar", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Volver a comprobar") { Task { await model.run() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let result):
            List {
                Section {
                    ForEach(result.checks) { check in
                        DoctorCheckRow(check: check, isFixing: model.fixing == check.id) { fix in
                            Task { await model.apply(fix, to: check.id) }
                        }
                    }
                } header: {
                    Text("\(model.serverName) · \(result.summary)")
                }
                reportSection
            }
            .refreshable { await model.run() }
        }
    }

    private var reportSection: some View {
        Section {
            Toggle("Incluir nombres, usuarios e IPs", isOn: $includesPersonalData)
            Toggle("Incluir detalle técnico del registro", isOn: $includesTechnicalDetail)
            Button {
                Task { await prepare(share: false) }
            } label: {
                Label(copied ? "Copiado" : "Copiar diagnóstico", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(isPreparing)
            Button {
                Task { await prepare(share: true) }
            } label: {
                Label("Compartir diagnóstico…", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparing)
        } header: {
            Text("Informe para un issue")
        } footer: {
            Text("Por defecto los servidores, usuarios e IPs se sustituyen por marcadores como «servidor-1». "
                 + "Argos oculta los secretos que reconoce, pero no puede garantizar que no se escape alguno: "
                 + "revisa el texto antes de publicarlo. El detalle técnico (depuración y agente) puede contener texto del servidor.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.fixError != nil }, set: { if !$0 { model.fixError = nil } })
    }

    private func prepare(share: Bool) async {
        isPreparing = true
        defer { isPreparing = false }
        let text = await DiagnosticReport.collect(
            doctor: model.result, serverName: model.serverName,
            knownServers: knownServers.map(DiagnosticRedactor.KnownServer.init),
            includePersonalData: includesPersonalData,
            includesTechnicalDetail: includesTechnicalDetail
        )
        if share {
            shared = SharedReport(text: text)
        } else {
            UIPasteboard.general.string = text
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct SharedReport: Identifiable {
    let id = UUID()
    let text: String
}

private struct DoctorCheckRow: View {
    let check: DoctorCheck
    let isFixing: Bool
    let onFix: (DoctorFix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.detail).font(.callout).foregroundStyle(.secondary)
                if let fix = check.fix { fixView(fix) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(check.status.label): \(check.title)")
    }

    @ViewBuilder
    private func fixView(_ fix: DoctorFix) -> some View {
        switch fix {
        case .installClaudeHooks(let isUpdate):
            Button(isUpdate ? "Actualizar hooks" : "Instalar hooks") { onFix(fix) }
                .buttonStyle(.bordered).disabled(isFixing)
        case .installPortsSkill(let isUpdate):
            Button(isUpdate ? "Actualizar skill" : "Instalar skill") { onFix(fix) }
                .buttonStyle(.bordered).disabled(isFixing)
        case .copyCommand(let command):
            VStack(alignment: .leading, spacing: 4) {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copiar comando") { UIPasteboard.general.string = command }
                    .buttonStyle(.bordered).controlSize(.small)
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
