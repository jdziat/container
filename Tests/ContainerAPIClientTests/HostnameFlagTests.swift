import Testing
@testable import ContainerAPIClient

struct HostnameFlagTests {
    @Test func testManagementHostname() throws {
        let m = try Flags.Management.parse(["--hostname", "myuts", "--name", "hn2"])
        #expect(m.hostname == "myuts")
        #expect(m.name == "hn2")
    }

    @Test func testManagementDomainname() throws {
        let m = try Flags.Management.parse(["--domainname", "example.test", "--name", "dn1"])
        #expect(m.domainname == "example.test")
        #expect(m.name == "dn1")
    }
}
