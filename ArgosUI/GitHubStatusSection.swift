//
//  GitHubStatusSection.swift
//  ArgosUI
//
//  Sección «GitHub» del panel «Cambios» (Mac e iPhone/iPad): el PR de la rama con su
//  revisión y checks, el CI del commit HEAD por workflow, y las acciones (abrir en
//  GitHub, crear PR, relanzar lo fallido). Todo viene del `gh` del servidor.
//

import SwiftUI

/// Crea y mantiene el modelo de una raíz (cambia de raíz → modelo nuevo, con `.id`).
struct GitHubStatusHost: View {
    let branch: GitBranchInfo
    @State private var model: GitHubStatusModel

    init(root: String, branch: GitBranchInfo, service: any SSHServicing,
         onCIPending: (@MainActor (_ root: String, _ sha: String) -> Void)?) {
        self.branch = branch
        _model = State(initialValue: GitHubStatusModel(root: root, service: service, onCIPending: onCIPending))
    }

    var body: some View {
        GitHubStatusSection(model: model, branch: branch)
            .task {
                await model.refresh(force: true)
                await model.pollWhileVisible()
            }
            // Un push o un commit cambian lo que hay que mirar: se relee al momento.
            .onChange(of: branch) { _, _ in Task { await model.refresh(force: true) } }
    }
}

struct GitHubStatusSection: View {
    let model: GitHubStatusModel
    let branch: GitBranchInfo
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Consultando GitHub…").font(.caption).foregroundStyle(.secondary)
                }
            case .ghMissing:
                hint("Instala GitHub CLI (`gh`) en el servidor para ver el PR y el CI aquí.")
            case .notAuthenticated:
                hint("`gh` no tiene sesión en el servidor. Ejecuta `gh auth login` en el terminal.")
            case .notGitHub:
                EmptyView()
            case .failed(let message):
                HStack {
                    hint("GitHub: \(message)")
                    Spacer()
                    Button("Reintentar") { Task { await model.refresh(force: true) } }
                        .font(.caption)
                }
            case .loaded(let snapshot):
                pullRequestRow(snapshot)
                ciRows(snapshot)
            }
            feedback
        }
        .buttonStyle(.borderless)
    }

    // MARK: - PR

    @ViewBuilder
    private func pullRequestRow(_ snapshot: GitHubSnapshot) -> some View {
        if let pr = snapshot.pullRequest {
            Button { if let url = pr.url { openURL(url) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: prSymbol(pr)).foregroundStyle(prColor(pr))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(pr.number) \(pr.title)").lineLimit(2).foregroundStyle(.primary)
                        Text([pr.stateLabel, pr.reviewLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let checks = pr.checksState { CheckStateIcon(state: checks) }
                    Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Pull request \(pr.number): \(pr.title). \(pr.stateLabel). Abrir en GitHub")
        } else if snapshot.branch != nil {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
                Text("Sin PR para esta rama").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if model.operation == .createPullRequest { ProgressView().controlSize(.small) }
                Menu("Crear PR") {
                    Button("Crear PR") { Task { await model.createPullRequest() } }
                    Button("Crear como borrador") { Task { await model.createPullRequest(draft: true) } }
                }
                .fixedSize()
                .disabled(!model.canCreatePullRequest(branch: branch))
                .help(createHelp)
            }
        }
    }

    private var createHelp: String {
        if branch.upstream == nil { return "Primero publica la rama (Push)." }
        if branch.ahead > 0 { return "Sube antes los commits pendientes (Push)." }
        return "Abre un PR con el título y la descripción de los commits."
    }

    private func prSymbol(_ pr: GitHubPullRequest) -> String {
        switch pr.state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .open: return pr.isDraft ? "pencil.circle" : "arrow.triangle.pull"
        }
    }

    private func prColor(_ pr: GitHubPullRequest) -> Color {
        switch pr.state {
        case .merged: return .purple
        case .closed: return .red
        case .open: return pr.isDraft ? .secondary : .green
        }
    }

    // MARK: - CI

    @ViewBuilder
    private func ciRows(_ snapshot: GitHubSnapshot) -> some View {
        if snapshot.runs.isEmpty {
            if snapshot.pullRequest == nil {
                Text("Sin ejecuciones de CI para \(snapshot.shortSha)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let state = snapshot.ciState { CheckStateIcon(state: state) }
                    Text("CI · \(snapshot.shortSha)").font(.caption.weight(.semibold))
                    Spacer()
                }
                ForEach(snapshot.runs) { run in runRow(run) }
            }
        }
        if let warning = snapshot.warning {
            hint(warning)
        }
    }

    private func runRow(_ run: GitHubRun) -> some View {
        HStack(spacing: 6) {
            CheckStateIcon(state: run.state).font(.caption)
            Button { if let url = run.url { openURL(url) } } label: {
                Text(run.workflow).font(.caption).lineLimit(1).foregroundStyle(.primary)
            }
            .accessibilityLabel("\(run.workflow): \(run.state.label). Abrir en GitHub")
            Spacer(minLength: 4)
            if run.state == .failure {
                if model.operation == .rerun(run.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Relanzar") { Task { await model.rerunFailed(run) } }
                        .font(.caption)
                        .disabled(model.operation != nil)
                        .help("Vuelve a lanzar los jobs fallidos")
                }
            }
        }
    }

    // MARK: - Mensajes

    @ViewBuilder
    private var feedback: some View {
        if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(.green).lineLimit(3)
                .textSelection(.enabled)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(6))
                    if model.notice == notice { model.notice = nil }
                }
        }
        if let error = model.errorMessage {
            HStack(alignment: .top) {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
                Spacer()
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .font(.caption)
                    .accessibilityLabel("Cerrar error")
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(.init(text)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Icono del estado de un check o del CI (también para VoiceOver).
struct CheckStateIcon: View {
    let state: GitHubCheckState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(state.label)
            .help(state.label)
    }

    private var symbol: String {
        switch state {
        case .pending: return "clock.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .pending: return .orange
        case .success: return .green
        case .failure: return .red
        case .cancelled, .skipped: return .secondary
        }
    }
}
