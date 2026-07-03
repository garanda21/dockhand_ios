import Foundation

enum DockhandUserFacingErrorFormatter {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if urlErrorCode(in: error) == .cancelled || urlErrorCode(in: errorText(error)) == .cancelled {
            return true
        }

        return false
    }

    static func message(for error: Error) -> String {
        if let urlErrorCode = urlErrorCode(in: error) ?? urlErrorCode(in: errorText(error)) {
            return message(for: urlErrorCode)
        }

        if let serviceError = error as? DockhandServiceError {
            return message(for: serviceError)
        }

        let rawMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawMessage.isEmpty {
            return localized(
                "Something went wrong. Try again in a moment.",
                spanish: "Algo salió mal. Inténtalo de nuevo en un momento."
            )
        }

        if looksLikeTechnicalTransportError(rawMessage) {
            return localized(
                "Could not connect to Dockhand. Check that the server is online and that your network or VPN is connected.",
                spanish: "No se pudo conectar con Dockhand. Comprueba que el servidor esté encendido y que estés en la red o VPN correcta."
            )
        }

        return rawMessage
    }

    private static func message(for error: DockhandServiceError) -> String {
        switch error {
        case .invalidResponse:
            return localized(
                "Dockhand sent a response the app could not read. Try again or update the server.",
                spanish: "Dockhand envió una respuesta que la app no pudo leer. Inténtalo de nuevo o actualiza el servidor."
            )
        case .message(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? localized(
                    "Dockhand could not complete the request.",
                    spanish: "Dockhand no pudo completar la solicitud."
                )
                : trimmed
        case .unexpectedStatus(let code):
            switch code {
            case 401, 403:
                return localized(
                    "Dockhand rejected the request. Check the server token in Settings.",
                    spanish: "Dockhand rechazó la solicitud. Revisa el token del servidor en Ajustes."
                )
            case 404:
                return localized(
                    "Dockhand could not find the requested resource. Refresh and try again.",
                    spanish: "Dockhand no encontró el recurso solicitado. Actualiza e inténtalo de nuevo."
                )
            case 408, 504:
                return localized(
                    "Dockhand took too long to respond. Check the server connection and try again.",
                    spanish: "Dockhand tardó demasiado en responder. Revisa la conexión del servidor e inténtalo de nuevo."
                )
            case 500..<600:
                return localized(
                    "Dockhand reported a server error. Try again in a moment.",
                    spanish: "Dockhand informó de un error del servidor. Inténtalo de nuevo en un momento."
                )
            default:
                return localized(
                    "Dockhand could not complete the request. Try again in a moment.",
                    spanish: "Dockhand no pudo completar la solicitud. Inténtalo de nuevo en un momento."
                )
            }
        }
    }

    private static func message(for code: URLError.Code) -> String {
        switch code {
        case .timedOut:
            return localized(
                "Could not connect to Dockhand. Check that the server is online and that your network or VPN is connected.",
                spanish: "No se pudo conectar con Dockhand. Comprueba que el servidor esté encendido y que estés en la red o VPN correcta."
            )
        case .notConnectedToInternet:
            return localized(
                "No internet connection. Connect to a network and try again.",
                spanish: "No hay conexión a internet. Conéctate a una red e inténtalo de nuevo."
            )
        case .networkConnectionLost:
            return localized(
                "The connection to Dockhand was interrupted. Try again.",
                spanish: "La conexión con Dockhand se interrumpió. Inténtalo de nuevo."
            )
        case .cannotFindHost, .dnsLookupFailed:
            return localized(
                "Could not find the Dockhand server. Check the server address in Settings.",
                spanish: "No se encontró el servidor Dockhand. Revisa la dirección del servidor en Ajustes."
            )
        case .cannotConnectToHost:
            return localized(
                "Could not reach the Dockhand server. Check that it is online and reachable from this network.",
                spanish: "No se pudo acceder al servidor Dockhand. Comprueba que esté encendido y accesible desde esta red."
            )
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return localized(
                "The secure connection to Dockhand failed. Check the server certificate or URL.",
                spanish: "Falló la conexión segura con Dockhand. Revisa el certificado o la URL del servidor."
            )
        case .userAuthenticationRequired:
            return localized(
                "Dockhand requires authentication. Check the server token in Settings.",
                spanish: "Dockhand requiere autenticación. Revisa el token del servidor en Ajustes."
            )
        case .cancelled:
            return localized(
                "The request was cancelled.",
                spanish: "La solicitud se canceló."
            )
        default:
            return localized(
                "Could not connect to Dockhand. Check the server connection and try again.",
                spanish: "No se pudo conectar con Dockhand. Revisa la conexión del servidor e inténtalo de nuevo."
            )
        }
    }

    private static func urlErrorCode(in error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: nsError.code)
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return urlErrorCode(in: underlying)
        }

        return nil
    }

    private static func urlErrorCode(in text: String) -> URLError.Code? {
        let patterns: [(String, URLError.Code)] = [
            ("Code=-1001", .timedOut),
            ("Code=-1009", .notConnectedToInternet),
            ("Code=-1005", .networkConnectionLost),
            ("Code=-1003", .cannotFindHost),
            ("Code=-1006", .dnsLookupFailed),
            ("Code=-1004", .cannotConnectToHost),
            ("Code=-999", .cancelled),
            ("Code=-1200", .secureConnectionFailed),
            ("Code=-1202", .serverCertificateUntrusted),
            ("timed out", .timedOut),
            ("agotado el tiempo", .timedOut)
        ]

        return patterns.first { text.localizedCaseInsensitiveContains($0.0) }?.1
    }

    private static func looksLikeTechnicalTransportError(_ message: String) -> Bool {
        [
            "Client encountered an error",
            "Transport threw an error",
            "NSURLErrorDomain",
            "kCFErrorDomainCFNetwork",
            "URLSessionTask",
            "NSErrorFailingURL",
            "OpenAPIRuntime"
        ].contains { message.localizedCaseInsensitiveContains($0) }
    }

    private static func errorText(_ error: Error) -> String {
        [
            String(describing: error),
            error.localizedDescription,
            (error as NSError).debugDescription
        ].joined(separator: "\n")
    }

    private static func localized(_ english: String, spanish: String) -> String {
        if Locale.autoupdatingCurrent.language.languageCode?.identifier == "es" {
            return spanish
        }

        return english
    }
}

extension Error {
    var isDockhandCancellation: Bool {
        DockhandUserFacingErrorFormatter.isCancellation(self)
    }

    var dockhandUserFacingMessage: String {
        DockhandUserFacingErrorFormatter.message(for: self)
    }
}
