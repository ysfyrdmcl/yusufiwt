#if os(macOS)
    import AppKit

    public struct DisplayGeometry: Sendable, Equatable {
        public let identifier: String
        public let frame: CGRect
        public let visibleFrame: CGRect
        public let safeAreaTopInset: CGFloat
        public let auxiliaryTopLeftArea: CGRect?
        public let auxiliaryTopRightArea: CGRect?

        public init(
            identifier: String,
            frame: CGRect,
            visibleFrame: CGRect,
            safeAreaTopInset: CGFloat = 0,
            auxiliaryTopLeftArea: CGRect? = nil,
            auxiliaryTopRightArea: CGRect? = nil
        ) {
            self.identifier = identifier
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.safeAreaTopInset = safeAreaTopInset
            self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
            self.auxiliaryTopRightArea = auxiliaryTopRightArea
        }

        public var notchFrame: CGRect? {
            guard safeAreaTopInset > 0,
                  let left = auxiliaryTopLeftArea,
                  let right = auxiliaryTopRightArea,
                  right.minX > left.maxX
            else { return nil }
            return CGRect(
                x: left.maxX,
                y: frame.maxY - safeAreaTopInset,
                width: right.minX - left.maxX,
                height: safeAreaTopInset
            )
        }
    }

    public enum NotchPanelMode: Sendable, Equatable {
        case compact
        case activity
        case decision
        case expanded

        var showsDetails: Bool {
            self != .compact
        }
    }

    public enum FloatingPanelPlacement {
        public static func frame(
            panelSize: CGSize,
            displays: [DisplayGeometry],
            cursorLocation: CGPoint,
            preferredDisplayID: String? = nil,
            topPadding: CGFloat = 12
        ) -> CGRect? {
            guard !displays.isEmpty else { return nil }
            let display = preferredDisplayID.flatMap { id in displays.first(where: { $0.identifier == id }) }
                ?? displays.first(where: { $0.notchFrame != nil })
                ?? displays.first(where: { $0.frame.contains(cursorLocation) })
                ?? displays.first
            guard let display else { return nil }
            return frame(panelSize: panelSize, display: display, topPadding: topPadding)
        }

        public static func frame(
            panelSize: CGSize,
            display: DisplayGeometry,
            topPadding: CGFloat = 12
        ) -> CGRect {
            if let notch = display.notchFrame {
                let width = min(panelSize.width, display.frame.width)
                let height = min(panelSize.height, display.frame.height)
                let horizontalOrigin = min(
                    max(display.frame.minX, notch.midX - width / 2),
                    display.frame.maxX - width
                )
                return CGRect(
                    x: horizontalOrigin,
                    y: display.frame.maxY - height,
                    width: width,
                    height: height
                )
            }
            let visible = display.visibleFrame
            let width = min(panelSize.width, visible.width)
            let height = min(panelSize.height, visible.height)
            let horizontalOrigin = min(max(visible.minX, visible.midX - width / 2), visible.maxX - width)
            let verticalOrigin = max(visible.minY, visible.maxY - height - topPadding)
            return CGRect(x: horizontalOrigin, y: verticalOrigin, width: width, height: height)
        }
    }

    extension DisplayGeometry {
        init(screen: NSScreen) {
            let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
                ?? String(describing: screen)
            self.init(
                identifier: identifier,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                safeAreaTopInset: screen.safeAreaInsets.top,
                auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
                auxiliaryTopRightArea: screen.auxiliaryTopRightArea
            )
        }
    }
#endif
