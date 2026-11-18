//
//  PosixChecksum.swift
//  Argos
//
//  CRC de `cksum` (POSIX.2: CRC-32 0x04C11DB7 sin reflejar, con la longitud añadida y
//  complementado). Sirve para comprobar EN EL SERVIDOR, sin herramientas extra, que un
//  archivo sigue siendo el que se leyó (`cksum` está en todo sistema POSIX).
//

import Foundation

enum PosixChecksum {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
        }
        return crc
    }

    /// Lo que imprime `cksum < archivo`: `"<crc> <bytes>"`.
    static func fingerprint(of data: Data) -> String {
        "\(crc(of: data)) \(data.count)"
    }

    static func crc(of data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        var length = data.count
        while length > 0 {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(length & 0xFF)) & 0xFF)]
            length >>= 8
        }
        return ~crc
    }
}
