//
//  CheckForUpdatesView.swift
//  Argos
//
//  Botón de menú "Buscar actualizaciones…" enlazado al actualizador de Sparkle.
//  Patrón recomendado por Sparkle para SwiftUI: el botón se deshabilita mientras
//  el actualizador no puede comprobar (p. ej. ya hay un chequeo en curso).
//

import Sparkle
import SwiftUI

/// Expone `canCheckForUpdates` del `SPUUpdater` como propiedad observable.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Buscar actualizaciones…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
