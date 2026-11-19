#if TUN_COMPAT
import Foundation
import SystemConfiguration

// Built only by build-tun.sh. The default build keeps the original transport.
enum TUNSupport {
    static let discoveryEntries = [URL(string: "http://1.1.1.1/")!, URL(string: "http://1.0.0.1/")!]
    static let resolverAddresses = ["223.5.5.5", "223.6.6.6"]
    static let probeHosts: Set<String> = ["www.baidu.com", "www.apple.com"]

    static func octets(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4, zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return nil }
        return bytes
    }
    static func usableAddress(_ value: String) -> Bool {
        guard let b = octets(value) else { return false }
        return b[0] != 0 && b[0] != 127 && b[0] < 224 &&
            !(b[0] == 169 && b[1] == 254) && !(b[0] == 198 && (b[1] == 18 || b[1] == 19))
    }
    static func publicAddress(_ value: String) -> Bool {
        guard usableAddress(value), let b = octets(value) else { return false }
        return b[0] != 10 && !(b[0] == 172 && (16...31).contains(b[1])) &&
            !(b[0] == 192 && b[1] == 168) && !(b[0] == 100 && (64...127).contains(b[1])) &&
            !(b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) &&
            !(b[0] == 198 && b[1] == 51 && b[2] == 100) && !(b[0] == 203 && b[1] == 0 && b[2] == 113)
    }
    static func physicalInterface(_ name: String) -> Bool {
        name.range(of: #"\Aen[0-9]+\z"#, options: .regularExpression) != nil
    }
    static func select(primary: String?, candidates: [NetworkSnapshot], preferredProfile: String?) -> NetworkSnapshot? {
        // candidates are collected only from SCNetworkInterface's Wi-Fi devices.
        let valid = candidates.filter { physicalInterface($0.interface) && usableAddress($0.address) && !$0.profile.isEmpty }
        let preferred = valid.filter { $0.profile == preferredProfile }
        if preferred.count == 1 { return preferred[0] }
        if let match = valid.first(where: { $0.interface == primary }) { return match }
        return valid.count == 1 ? valid[0] : nil
    }
    static func currentNetwork() -> NetworkSnapshot? {
        guard let store = SCDynamicStoreCreate(nil, "HBUT physical Wi-Fi" as CFString, nil, nil),
              let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] ?? [:]
        let primary = global["PrimaryInterface"] as? String
        var candidates: [NetworkSnapshot] = []
        for item in interfaces where SCNetworkInterfaceGetInterfaceType(item) == kSCNetworkInterfaceTypeIEEE80211 {
            guard let interface = SCNetworkInterfaceGetBSDName(item) as String?,
                  let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any],
                  let address = (ipv4["Addresses"] as? [String])?.first else { continue }
            let wifi = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/AirPort" as CFString) as? [String: Any] ?? [:]
            let router = ipv4["Router"] as? String ?? (primary == interface ? global["Router"] as? String ?? "" : "")
            candidates.append(NetworkSnapshot(interface: interface, address: address, router: router,
                profile: wifi["ProfileID"] as? String ?? "", joined: String(describing: wifi["AutoJoinTimestamp"] ?? "")))
        }
        return select(primary: primary, candidates: candidates, preferredProfile: Configuration.load()?.networkProfile)
    }

    static func normalizedHost(_ name: String) -> String { name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    static func answers(_ response: [String: Any], for host: String) -> [String] {
        let host = normalizedHost(host)
        // AliDNS returns one Question object; other JSON DoH implementations
        // use an array. Validate the content in either representation.
        let questions = (response["Question"] as? [[String: Any]]) ??
            (response["Question"] as? [String: Any]).map { [$0] } ?? []
        guard response["Status"] as? Int == 0, response["TC"] as? Bool != true,
              questions.count == 1,
              questions[0]["type"] as? Int == 1,
              normalizedHost(questions[0]["name"] as? String ?? "") == host,
              let records = response["Answer"] as? [[String: Any]], records.count <= 64 else { return [] }
        var aliases: Set<String> = [host]
        for _ in 0..<records.count {
            let before = aliases.count
            for record in records where record["type"] as? Int == 5 {
                if aliases.contains(normalizedHost(record["name"] as? String ?? "")),
                   let target = record["data"] as? String, target.utf8.count <= 253 {
                    aliases.insert(normalizedHost(target))
                }
            }
            if aliases.count == before { break }
        }
        var result: [String] = []
        for record in records where record["type"] as? Int == 1 {
            guard aliases.contains(normalizedHost(record["name"] as? String ?? "")),
                  let address = record["data"] as? String, publicAddress(address), !result.contains(address) else { continue }
            result.append(address)
        }
        return Array(result.prefix(4))
    }
    static func resolveOption(url: URL, address: String) throws -> String {
        guard url.scheme == "https", let host = url.host, probeHosts.contains(host),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, publicAddress(address) else {
            throw CampusError.message("TUN 直连检测目标无效，未发送请求。")
        }
        return "\(host):443:\(address)"
    }
    static func isOnline(_ http: DirectHTTP) -> Bool {
        let end = min(http.deadline, ProcessInfo.processInfo.systemUptime + 5)
        for probe in [Portal.secondarySecureProbe, Portal.secureProbe] {
            guard let host = probe.host, !http.cancellation.cancelled else { return false }
            var addresses = http.tunResolvedHosts[host] ?? []
            if addresses.isEmpty {
                for resolver in resolverAddresses {
                    let remaining = end - ProcessInfo.processInfo.systemUptime
                    if remaining < 0.25 { return false }
                    let url = URL(string: "https://\(resolver)/resolve?name=\(host)&type=A")!
                    if let reply = try? http.request(url, timeout: min(1.5, remaining)).json() {
                        addresses = answers(reply, for: host)
                        if !addresses.isEmpty { http.tunResolvedHosts[host] = addresses; break }
                    }
                }
            }
            for address in addresses.prefix(2) {
                let remaining = end - ProcessInfo.processInfo.systemUptime
                if remaining < 0.25 { return false }
                if let reply = try? http.request(probe, timeout: min(2, remaining), headOnly: probe == Portal.secondarySecureProbe, resolvedAddress: address),
                   (probe == Portal.secureProbe ? reply.appleSuccess : reply.status == 200) { return true }
            }
        }
        return false
    }
}
#endif
