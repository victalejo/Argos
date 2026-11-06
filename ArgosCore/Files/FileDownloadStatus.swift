//
//  FileDownloadStatus.swift
//  ArgosCore
//
//  Estado de la última descarga del explorador de archivos.
//

import Foundation

/// Estado de la última descarga (banner en el visor).
enum FileDownloadStatus: Equatable {
    case downloading(name: String)
    case saved(URL)
    case failed(name: String, message: String)
}
