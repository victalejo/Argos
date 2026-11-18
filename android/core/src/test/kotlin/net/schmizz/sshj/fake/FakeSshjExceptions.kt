package net.schmizz.sshj.fake

import java.io.IOException

// Dobles con los MISMOS nombres simples que las excepciones de sshj (core no depende de sshj):
// `TransportErrorText` las reconoce por paquete y nombre de clase.

class OpenFailException(message: String) : IOException(message)

class UserAuthException(message: String) : IOException(message)

class ConnectionException(message: String, cause: Throwable? = null) : IOException(message, cause)

class TransportException(message: String) : IOException(message)

class SFTPException(message: String) : IOException(message)
