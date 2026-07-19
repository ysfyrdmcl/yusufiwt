import AgentMacUI
import AgentPersistence
import Foundation
import Testing

@Suite("Notch panel geometry")
struct NotchPanelGeometryTests {
    @Test("Elapsed time is compact and stable for the notch surface")
    func elapsedFormatting() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(NotchPanelFormatting.elapsed(from: start, to: start.addingTimeInterval(12)) == "<1m")
        #expect(NotchPanelFormatting.elapsed(from: start, to: start.addingTimeInterval(65)) == "1m")
        #expect(NotchPanelFormatting.elapsed(from: start, to: start.addingTimeInterval(3_900)) == "1h 5m")
        #expect(NotchPanelFormatting.elapsed(from: start, to: start.addingTimeInterval(93_600)) == "1d 2h")
    }

    @Test("Live states use human-readable labels")
    func stateTitles() {
        #expect(NotchPanelFormatting.stateTitle(.thinking) == "Thinking")
        #expect(NotchPanelFormatting.stateTitle(.executing) == "Working")
        #expect(NotchPanelFormatting.stateTitle(.waitingApproval) == "Approval needed")
    }

    @Test("Older helper snapshots remain decodable without a start date")
    func legacySessionListItemDecoding() throws {
        let json = """
        {
          "id": "E763E288-EBB8-4A3A-A342-7A65EE9B42E2",
          "projectName": "Legacy",
          "adapterID": "codex",
          "state": "running",
          "lastMeaningfulEventAt": 721692800,
          "snapshotRevision": 1
        }
        """
        let item = try JSONDecoder().decode(SessionListItem.self, from: Data(json.utf8))
        #expect(item.startedAt == item.lastMeaningfulEventAt)
    }

    @Test("Panel derives the camera housing gap and attaches to the physical screen top")
    func notchPlacement() throws {
        let display = DisplayGeometry(
            identifier: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 660, height: 38),
            auxiliaryTopRightArea: CGRect(x: 852, y: 944, width: 660, height: 38)
        )
        let notch = try #require(display.notchFrame)
        #expect(notch == CGRect(x: 660, y: 944, width: 192, height: 38))

        let frame = FloatingPanelPlacement.frame(
            panelSize: CGSize(width: 420, height: 300),
            display: display
        )
        #expect(frame.midX == notch.midX)
        #expect(frame.maxY == display.frame.maxY)
        #expect(frame.minY >= display.frame.minY)
    }

    @Test("A notched display wins over the cursor display for the persistent surface")
    func notchDisplayPreference() throws {
        let external = DisplayGeometry(
            identifier: "external",
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055)
        )
        let builtIn = DisplayGeometry(
            identifier: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 660, height: 38),
            auxiliaryTopRightArea: CGRect(x: 852, y: 944, width: 660, height: 38)
        )
        let frame = try #require(FloatingPanelPlacement.frame(
            panelSize: CGSize(width: 420, height: 300),
            displays: [external, builtIn],
            cursorLocation: CGPoint(x: 2000, y: 500)
        ))
        let notch = try #require(builtIn.notchFrame)
        #expect(frame.midX == notch.midX)
        #expect(frame.maxY == builtIn.frame.maxY)
    }
}
