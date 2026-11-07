//
//  QRScannerView.swift
//  ArgosiOS
//
//  Escáner de códigos QR con la cámara (VisionKit `DataScannerViewController`).
//  Avisa de cada QR nuevo que reconoce; quien lo usa decide si le sirve.
//

import SwiftUI
import VisionKit

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    /// `false` si el dispositivo no tiene cámara compatible o se denegó el permiso.
    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            Log.store.error("No se pudo iniciar el escáner de QR: \(String(describing: error), privacy: .public)")
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    onScan(text)
                }
            }
        }
    }
}
