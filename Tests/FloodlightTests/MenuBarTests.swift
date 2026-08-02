import AppKit
import XCTest
@testable import Floodlight

@MainActor
final class MenuBarTests: XCTestCase {
    func testStatusMenuExposesSettingsAndLauncherControls() throws {
        let menu = AppDelegate().makeStatusMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Show Floodlight",
                "",
                "Settings…",
                "Choose Search Scope…",
                "Rebuild Index",
                "Launch at Login",
                "",
                "Quit Floodlight",
            ]
        )
        let settings = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
        XCTAssertEqual(settings.action.map(NSStringFromSelector), "showSettings")
    }

    func testMainMenuExposesStandardTextEditingCommands() throws {
        let mainMenu = AppDelegate().makeMainMenu()
        let editMenu = try XCTUnwrap(
            mainMenu.items.compactMap(\.submenu).first { $0.title == "Edit" }
        )

        XCTAssertEqual(
            editMenu.items.map(\.title),
            ["Undo", "Redo", "", "Cut", "Copy", "Paste", "Select All"]
        )
        XCTAssertEqual(
            editMenu.items.compactMap { item in
                item.action.map(NSStringFromSelector)
            },
            ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]
        )
        XCTAssertTrue(editMenu.items.allSatisfy { $0.target == nil })
    }
}
