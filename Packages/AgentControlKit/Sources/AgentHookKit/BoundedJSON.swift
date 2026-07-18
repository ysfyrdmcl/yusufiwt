#if os(macOS)
    import Foundation

    public enum HookInputError: Error, Sendable, Equatable, CustomStringConvertible {
        case empty
        case tooLarge(Int)
        case excessiveNesting
        case malformedJSON

        public var description: String {
            switch self {
            case .empty: "Hook input is empty"
            case let .tooLarge(size): "Hook input is too large (\(size) bytes)"
            case .excessiveNesting: "Hook input nesting exceeds the limit"
            case .malformedJSON: "Hook input is not valid JSON"
            }
        }
    }

    public enum BoundedJSON {
        public static func decode<T: Decodable>(
            _ type: T.Type,
            from data: Data,
            maximumBytes: Int,
            maximumDepth: Int = 64
        ) throws -> T {
            guard !data.isEmpty else { throw HookInputError.empty }
            guard data.count <= maximumBytes else { throw HookInputError.tooLarge(data.count) }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw HookInputError.malformedJSON
            }
            guard depth(of: object, limit: maximumDepth) <= maximumDepth else {
                throw HookInputError.excessiveNesting
            }
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw HookInputError.malformedJSON
            }
        }

        private static func depth(of value: Any, limit: Int, current: Int = 0) -> Int {
            guard current <= limit else { return current }
            if let values = value as? [Any] {
                return values.reduce(current) { max($0, depth(of: $1, limit: limit, current: current + 1)) }
            }
            if let values = value as? [String: Any] {
                return values.values.reduce(current) { max($0, depth(of: $1, limit: limit, current: current + 1)) }
            }
            return current
        }
    }
#endif
