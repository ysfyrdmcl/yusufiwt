public enum WireProtocolVersion {
    public static let current = 1
    public static let supported = 1 ... current

    public static func supports(_ version: Int) -> Bool {
        supported.contains(version)
    }
}
