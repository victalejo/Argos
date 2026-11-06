//
//  AppStoreLinks.swift
//  Argos
//
//  Enlaces a la ficha de Argos en la Mac App Store (app id de App Store Connect).
//

import Foundation

enum AppStoreLinks {
    static let appID = "6831410935"

    /// Abre la ficha en la app App Store (desde ahí se instala la actualización).
    static let productPage = URL(string: "macappstore://apps.apple.com/app/id\(appID)")!
}
