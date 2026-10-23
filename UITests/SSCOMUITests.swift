import XCTest

/// Drives SSCOM like a person would. The app runs with `-SSCOMEphemeralSettings YES`, so it starts
/// from defaults and never saves over the user's setup.
final class SSCOMUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-SSCOMEphemeralSettings", "YES", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: Helpers

    var window: XCUIElement { app.windows.firstMatch }

    func element(_ id: String) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func replaceText(_ id: String, with text: String) {
        let field = element(id)
        XCTAssertTrue(field.waitForExistence(timeout: 3), id)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text + "\t")
    }

    func choose(_ popUpID: String, _ item: String) {
        let popup = element(popUpID)
        XCTAssertTrue(popup.waitForExistence(timeout: 3), popUpID)
        popup.click()
        app.menuItems[item].firstMatch.click()
    }

    var log: String { (element("receive.log").value as? String) ?? "" }

    /// Waits until the receive window contains `text`.
    func waitForLog(_ text: String, timeout: TimeInterval = 4, _ message: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if log.contains(text) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        attach("Log – \(message)")
        XCTFail("\(message): \"\(text)\" not in the log.\n\(log.suffix(800))")
    }

    func attach(_ name: String) {
        let a = XCTAttachment(screenshot: window.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func showStringsPanel() {
        if element("presets.library").exists { return }
        let toggle = element("panel.strings")
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Strings panel toggle")
        toggle.click()
        XCTAssertTrue(element("presets.library").waitForExistence(timeout: 3), "strings panel shown")
    }

    func loadRelayPreset() {
        showStringsPanel()
        element("presets.library").click()
        app.menuItems["Modbus POE ETH Relay (B) — Modbus RTU"].click()
        let replace = app.windows.buttons.matching(identifier: "Replace Strings").firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 3), "confirm dialog")
        replace.click()
    }

    func sendPreset(_ slot: Int) {
        let button = element("preset.send.\(slot)")
        XCTAssertTrue(button.waitForExistence(timeout: 3), "preset \(slot)")
        XCTAssertTrue(button.isEnabled, "preset \(slot) enabled (connected?)")
        button.click()
    }

    // MARK: Tests

    /// Loads the relay preset and checks it sets the checksum, without any device.
    func testRelayPresetLoads() {
        choose("link.mode", "TCP Client")
        loadRelayPreset()
        XCTAssertEqual(element("send.checksum").value as? String, "ModbusCRC16")
        XCTAssertEqual(element("remote.port").value as? String, "4196")
        XCTAssertTrue(window.buttons["Relay 1 on"].exists)
        attach("Relay preset loaded")
    }

    /// Switches relay 1 on and off on a real Modbus POE ETH Relay (B).
    /// Runs only with SSCOM_RELAY_HOST set (in the scheme or `TEST_RUNNER_SSCOM_RELAY_HOST`).
    func testRelayOneOnOff() throws {
        guard let host = ProcessInfo.processInfo.environment["SSCOM_RELAY_HOST"], !host.isEmpty else {
            throw XCTSkip("Set SSCOM_RELAY_HOST to a relay's IP address to run this test.")
        }
        choose("link.mode", "TCP Client")
        loadRelayPreset()
        let hexDisplay = window.checkBoxes["HEX display"]
        if (hexDisplay.value as? Int) != 1 { hexDisplay.click() }
        replaceText("remote.host", with: host)
        replaceText("remote.port", with: "4196")
        element("link.open").click()
        waitForLog("Opened", "connect to \(host):4196")

        sendPreset(1)   // Relay 1 on — the relay echoes the command.
        waitForLog("01 05 00 00 FF 00 8C 3A", timeout: 3, "relay 1 on sent")
        let afterOn = log.components(separatedBy: "01 05 00 00 FF 00 8C 3A").count - 1
        XCTAssertGreaterThanOrEqual(afterOn, 2, "relay echoed the on command")
        attach("Relay 1 on")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        sendPreset(2)   // Relay 1 off
        waitForLog("01 05 00 00 00 00 CD CA", timeout: 3, "relay 1 off sent")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let afterOff = log.components(separatedBy: "01 05 00 00 00 00 CD CA").count - 1
        XCTAssertGreaterThanOrEqual(afterOff, 2, "relay echoed the off command")
        attach("Relay 1 off")
        element("link.open").click()
    }
}
