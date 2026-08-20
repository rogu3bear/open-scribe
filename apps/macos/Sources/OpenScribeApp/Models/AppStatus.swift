struct AppStatus: Equatable, Sendable {
    let productName: String
    let coreVersion: String
    let persistence: String
    let capture: String
    let intelligence: String
}

enum RustStatusSource {
    static func load() -> AppStatus {
        let status = nativeStatus()

        return AppStatus(
            productName: status.productName,
            coreVersion: status.coreVersion,
            persistence: status.persistence,
            capture: status.capture,
            intelligence: status.intelligence
        )
    }
}
