//
//  ImportServerSheet.swift
//  ArgosiOS
//
//  Añadir un servidor desde el Mac: escanea el QR de «Enviar al iPhone…» (o llega ya
//  leído desde la cámara del sistema por el enlace `argos://`) y pide confirmación
//  antes de guardarlo. Ver `ServerTransfer`.
//

import SwiftUI

struct ImportServerSheet: View {
    let onImported: (Server) -> Void
    @Environment(ServerHub.self) private var hub
    @Environment(\.dismiss) private var dismiss

    @State private var transfer: ServerTransfer?
    @State private var scanError: String?
    @State private var saveError: String?

    init(transfer: ServerTransfer? = nil, onImported: @escaping (Server) -> Void = { _ in }) {
        self.onImported = onImported
        _transfer = State(initialValue: transfer)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let transfer {
                    confirmation(for: transfer)
                } else {
                    scanner
                }
            }
            .navigationTitle("Añadir desde el Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Escáner

    @ViewBuilder
    private var scanner: some View {
        if QRScannerView.isAvailable {
            QRScannerView(onScan: handle)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text(scanError ?? "En el Mac, abre el menú del servidor y elige «Enviar al iPhone…». Apunta la cámara al código.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(scanError == nil ? Color.primary : Color.red)
                        .padding()
                }
        } else {
            ContentUnavailableView {
                Label("Cámara no disponible", systemImage: "camera.badge.ellipsis")
            } description: {
                Text("Permite el acceso a la cámara en Ajustes › Argos, o escanea el código del Mac con la app Cámara: abrirá Argos.")
            }
        }
    }

    private func handle(_ text: String) {
        guard transfer == nil else { return }
        do {
            transfer = try ServerTransfer.decode(text)
            scanError = nil
        } catch {
            scanError = error.userMessage
        }
    }

    // MARK: - Confirmación

    private func confirmation(for transfer: ServerTransfer) -> some View {
        Form {
            Section {
                LabeledContent("Nombre", value: transfer.name)
                LabeledContent("Servidor") {
                    Text(verbatim: "\(transfer.username)@\(transfer.host)\(transfer.port == 22 ? "" : ":\(transfer.port)")")
                        .font(.callout.monospaced())
                }
                LabeledContent("Acceso", value: "Clave creada en el Mac solo para este dispositivo")
                LabeledContent("Identidad del servidor") {
                    Text(transfer.hostKeyFingerprint ?? "Se confiará en ella en la primera conexión")
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                if hasDuplicate(of: transfer) {
                    Text("Ya tienes un servidor con este usuario y dirección: se añadirá otro.")
                }
            }
            if transfer.conflictsWithTrustedHostKey() {
                Section {
                    Label(
                        "La identidad de este servidor no coincide con la que ya conoce este iPhone. Puede ser un código falso o un servidor reinstalado: no se añadirá. Si lo reinstalaste, usa «Olvidar host key» en el servidor y vuelve a escanear.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(.red)
                }
            }
            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red)
                }
            }
            Section {
                Button("Añadir servidor") { add(transfer) }
                    .frame(maxWidth: .infinity)
                    .bold()
                    .disabled(transfer.conflictsWithTrustedHostKey())
            } footer: {
                Text("Añade solo códigos generados por tu propio Mac.")
            }
        }
    }

    private func hasDuplicate(of transfer: ServerTransfer) -> Bool {
        hub.store.servers.contains {
            $0.host == transfer.host && $0.port == transfer.port && $0.username == transfer.username
        }
    }

    private func add(_ transfer: ServerTransfer) {
        do {
            let server = try hub.importTransfer(transfer)
            dismiss()
            onImported(server)
        } catch {
            Log.store.error("No se pudo añadir el servidor del QR: \(error.userMessage, privacy: .public)")
            saveError = "No se pudo añadir el servidor: \(error.userMessage)"
        }
    }
}
