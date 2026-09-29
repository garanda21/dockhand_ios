import DockhandAPI
import Foundation

extension URLSessionConfiguration {
    static var dockhandEphemeral: URLSessionConfiguration {
        DockhandHTTPSession.makeConfiguration()
    }
}

enum DockhandConnectionStage: Sendable {
    case health
    case environments
    case selectedEnvironment
}

struct DockhandConnectionStageError: Error {
    let stage: DockhandConnectionStage
    let underlying: Error
}

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
        if let challenge = proxyChallenge(in: error) {
            return message(for: challenge)
        }

        if let connectionError = error as? DockhandConnectionStageError {
            let detail = message(for: connectionError.underlying)
            switch connectionError.stage {
            case .health:
                return localized(
                    "Could not validate Dockhand at this address. \(detail)",
                    spanish: "No se pudo validar Dockhand en esta dirección. \(detail)"
                )
            case .environments:
                return localized(
                    "Dockhand is online, but its environments could not be loaded. \(detail)",
                    spanish: "Dockhand está en línea, pero no se pudieron cargar sus entornos. \(detail)"
                )
            case .selectedEnvironment:
                if isTransportFailure(connectionError.underlying) {
                    return localized(
                        "Dockhand is online, but the selected Docker environment could not be reached. Check the environment or Hawser connection.",
                        spanish: "Dockhand está en línea, pero no se pudo acceder al entorno Docker seleccionado. Revisa la conexión del entorno o de Hawser."
                    )
                }
                return localized(
                    "Dockhand is online, but data could not be loaded from the selected environment. \(detail)",
                    spanish: "Dockhand está en línea, pero no se pudieron cargar los datos del entorno seleccionado. \(detail)"
                )
            }
        }

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

    static func proxyChallenge(in error: Error) -> DockhandProxyChallengeError? {
        if let connectionError = error as? DockhandConnectionStageError {
            return proxyChallenge(in: connectionError.underlying)
        }
        return DockhandProxyChallenge.challenge(in: error)
    }

    private static func message(for challenge: DockhandProxyChallengeError) -> String {
        switch challenge {
        case .redirect(_, let host?):
            return localized(
                "A reverse proxy in front of Dockhand tried to redirect to a sign-in page (\(host)). Check this server's custom headers in Settings.",
                spanish: "Un proxy inverso delante de Dockhand intentó redirigir a una página de inicio de sesión (\(host)). Revisa los headers personalizados de este servidor en Ajustes."
            )
        case .redirect:
            return localized(
                "A reverse proxy in front of Dockhand tried to redirect the request. Check the server address and this server's custom headers in Settings.",
                spanish: "Un proxy inverso delante de Dockhand intentó redirigir la solicitud. Revisa la dirección y los headers personalizados de este servidor en Ajustes."
            )
        case .proxyAuthenticationRequired:
            return localized(
                "The proxy in front of Dockhand requires authentication. Check this server's custom headers in Settings.",
                spanish: "El proxy delante de Dockhand requiere autenticación. Revisa los headers personalizados de este servidor en Ajustes."
            )
        case .accessDenied:
            return localized(
                "The reverse proxy in front of Dockhand rejected the request. The custom headers may be missing, wrong, expired or not allowed by the proxy policy. Check them in Settings.",
                spanish: "El proxy inverso delante de Dockhand rechazó la solicitud. Puede que los headers personalizados falten, sean incorrectos, hayan caducado o la política del proxy no los permita. Revísalos en Ajustes."
            )
        case .webPage:
            return localized(
                "The server returned a web page instead of the Dockhand API. A reverse proxy may be asking you to sign in, or the address may be wrong. Check the address and custom headers in Settings.",
                spanish: "El servidor devolvió una página web en lugar de la API de Dockhand. Puede que un proxy inverso esté pidiendo iniciar sesión o que la dirección sea incorrecta. Revisa la dirección y los headers personalizados en Ajustes."
            )
        }
    }

    private static func message(for error: DockhandServiceError) -> String {
        switch error {
        case .invalidResponse:
            return localized(
                "Dockhand sent a response the app could not read. Try again or update the server.",
                spanish: "Dockhand envió una respuesta que la app no pudo leer. Inténtalo de nuevo o actualiza el servidor."
            )
        case .logsUnavailable(let reason):
            let suffix = reason.map { " (\($0))" } ?? ""
            return localized(
                "Dockhand cannot read logs for this container. Its logging driver may not support reading.\(suffix)",
                spanish: "Dockhand no puede leer los logs de este contenedor. Es posible que su driver de logs no permita la lectura.\(suffix)"
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
                    "Dockhand rejected the token. It may be expired, revoked, or missing the required permissions.",
                    spanish: "Dockhand rechazó el token. Puede haber caducado, estar revocado o no tener los permisos necesarios."
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
        case .appTransportSecurityRequiresSecureConnection:
            return localized(
                "iOS blocked this insecure connection. Use HTTPS or a server address on your local network.",
                spanish: "iOS bloqueó esta conexión no segura. Usa HTTPS o una dirección de servidor de tu red local."
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
            ("Code=-1022", .appTransportSecurityRequiresSecureConnection),
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

    private static func isTransportFailure(_ error: Error) -> Bool {
        urlErrorCode(in: error) != nil
            || urlErrorCode(in: errorText(error)) != nil
            || looksLikeTechnicalTransportError(errorText(error))
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
