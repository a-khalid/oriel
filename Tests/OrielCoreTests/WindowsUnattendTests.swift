import Foundation
@testable import OrielCore
import Testing

struct WindowsUnattendTests {
    @Test func producesWellFormedXML() throws {
        let xml = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "ahmed", password: "secret"))
        let document = try XMLDocument(xmlString: xml)
        #expect(document.rootElement()?.name == "unattend")
        #expect(try document.nodes(forXPath: "//*[local-name()='settings']").count == 3)
    }

    @Test func targetsARM64Components() throws {
        let xml = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "user"))
        let document = try XMLDocument(xmlString: xml)
        let components = try document.nodes(forXPath: "//*[local-name()='component']").compactMap { $0 as? XMLElement }
        #expect(!components.isEmpty)
        #expect(components.allSatisfy { $0.attribute(forName: "processorArchitecture")?.stringValue == "arm64" })
    }

    @Test func bypassesHardwareChecksWhenRequested() {
        let on = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "user", bypassHardwareChecks: true))
        let off = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "user", bypassHardwareChecks: false))
        #expect(on.contains("BypassTPMCheck"))
        #expect(on.contains("BypassSecureBootCheck"))
        #expect(!off.contains("BypassTPMCheck"))
    }

    @Test func escapesUserInput() throws {
        let xml = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "R&D <team>", computerName: "A\"B"))
        let document = try XMLDocument(xmlString: xml)
        let names = try document.nodes(forXPath: "//*[local-name()='LocalAccount']/*[local-name()='Name']")
        #expect(names.first?.stringValue == "R&D <team>")
    }

    @Test func encodesPasswordTheWayWindowsExpects() {
        // Base64(UTF-16LE("Password")) — what Windows writes for an empty password.
        #expect(WindowsUnattend.encodedPassword("") == "UABhAHMAcwB3AG8AcgBkAA==")
        let decoded = Data(base64Encoded: WindowsUnattend.encodedPassword("abc"))!
        #expect(String(data: decoded, encoding: .utf16LittleEndian) == "abcPassword")
    }

    @Test func usesGenericKeyOnlyForKnownEditions() {
        let pro = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "u", edition: "Windows 11 Pro"))
        let other = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "u", edition: "Windows 11 Education"))
        #expect(pro.contains("VK7JG-NPHTM-C97JM-9MPGT-3V66T"))
        #expect(!other.contains("<ProductKey>"))
    }

    @Test func skipsPartitioningWhenDisabled() {
        let xml = WindowsUnattend.xml(for: WindowsUnattendOptions(userName: "u", partitionDiskAutomatically: false))
        #expect(!xml.contains("<DiskConfiguration>"))
    }
}
