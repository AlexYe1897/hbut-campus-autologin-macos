import Foundation

@main struct TUNTests {
    static func main() throws {
        var passed = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAILED: " + label) }
            passed += 1
        }
        let campus = NetworkSnapshot(interface: "en0", address: "192.0.2.2", router: "192.0.2.1", profile: "campus-test", joined: "synthetic")
        let other = NetworkSnapshot(interface: "en1", address: "192.0.2.3", router: "192.0.2.1", profile: "other-test", joined: "synthetic")
        expect(TUNSupport.select(primary: "utun8", candidates: [campus], preferredProfile: "campus-test") == campus, "TUN primary does not hide physical campus Wi-Fi")
        expect(TUNSupport.select(primary: "utun8", candidates: [other, campus], preferredProfile: "campus-test") == campus, "registered Wi-Fi is selected independently of virtual routing")
        expect(TUNSupport.select(primary: "utun8", candidates: [campus, other], preferredProfile: "missing") == nil, "ambiguous physical networks fail closed")
        expect(TUNSupport.select(primary: "en1", candidates: [campus, other], preferredProfile: "missing") == other, "physical primary remains usable for initial setup")
        expect(TUNSupport.select(primary: "utun8", candidates: [], preferredProfile: "campus-test") == nil, "no Wi-Fi never falls back to TUN")
        expect(!TUNSupport.physicalInterface("utun8") && !TUNSupport.physicalInterface("en0\nproxy=evil"), "virtual or injected interface names are rejected")
        expect(!TUNSupport.usableAddress("169.254.1.2") && !TUNSupport.usableAddress("127.0.0.1"), "unready Wi-Fi addresses are rejected")
        expect(!TUNSupport.publicAddress("198.18.1.2") && !TUNSupport.publicAddress("198.19.0.1"), "Fake-IP range is rejected")
        expect(!TUNSupport.publicAddress("172.16.54.18") && !TUNSupport.publicAddress("100.64.0.1"), "private and shared addresses cannot become public probe overrides")
        expect(!TUNSupport.publicAddress("192.0.2.2") && !TUNSupport.publicAddress("224.0.0.1"), "documentation and multicast ranges are rejected")
        expect(TUNSupport.octets("127.1") == nil && TUNSupport.octets("008.8.8.8") == nil, "ambiguous IPv4 syntax is rejected")
        let host = "www.baidu.com"
        var reply: [String: Any] = ["Status": 0, "TC": false, "Question": [["name": host + ".", "type": 1]], "Answer": [
            ["name": "cdn.example.com.", "type": 1, "data": "8.8.8.8"],
            ["name": host, "type": 5, "data": "cdn.example.com."],
            ["name": "unrelated.example.com", "type": 1, "data": "9.9.9.9"],
            ["name": "cdn.example.com", "type": 1, "data": "198.18.0.8"]
        ]]
        expect(TUNSupport.answers(reply, for: host) == ["8.8.8.8"], "only public A records in the requested CNAME chain are used")
        reply["Question"] = ["name": host + ".", "type": 1]
        expect(TUNSupport.answers(reply, for: host) == ["8.8.8.8"], "AliDNS single-object Question schema is accepted with the same host validation")
        reply["Status"] = 3
        expect(TUNSupport.answers(reply, for: host).isEmpty, "negative DNS response cannot confirm connectivity")
        reply["Status"] = 0; reply["TC"] = true
        expect(TUNSupport.answers(reply, for: host).isEmpty, "truncated DNS response is rejected")
        reply["TC"] = false; reply["Question"] = [["name": "unrelated.example.com", "type": 1]]
        expect(TUNSupport.answers(reply, for: host).isEmpty, "DNS question must match the requested host")
        let option = try TUNSupport.resolveOption(url: Portal.secondarySecureProbe, address: "8.8.8.8")
        expect(option == "www.baidu.com:443:8.8.8.8", "real address override preserves the original TLS host")
        var rejected = false
        do { _ = try TUNSupport.resolveOption(url: URL(string: "https://evil.example/")!, address: "8.8.8.8") } catch { rejected = true }
        expect(rejected, "only fixed connectivity hosts accept a DNS override")
        rejected = false
        do { _ = try TUNSupport.resolveOption(url: Portal.secondarySecureProbe, address: "127.0.0.1") } catch { rejected = true }
        expect(rejected, "DNS overrides never target localhost")
        expect(TUNSupport.discoveryEntries.allSatisfy { TUNSupport.octets($0.host ?? "") != nil }, "portal discovery avoids intercepted DNS entirely")
        print("\(passed) TUN checks passed; no real credentials or network requests used.")
    }
}
