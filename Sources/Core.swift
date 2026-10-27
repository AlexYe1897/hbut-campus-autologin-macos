import Foundation
import Security
import LocalAuthentication
import SystemConfiguration
import Darwin

enum CampusError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Paths {
    static let label = "local.hbut.autologin"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let directory = home.appendingPathComponent("Library/Application Support/HBUTAutoLogin")
    static let configuration = directory.appendingPathComponent("config.json")
    static let status = directory.appendingPathComponent("status.json")
    static let log = directory.appendingPathComponent("events.log")
    static let application = home.appendingPathComponent("Applications/校园网自动登录.app")
    static let executable = application.appendingPathComponent("Contents/MacOS/CampusAutoLogin")
    static let agent = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare()
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct Configuration: Codable {
    var revision = UUID().uuidString
    var enabled = true
    var networkProfile: String
    var service = "default"
    static func load() -> Configuration? {
        guard let data = try? Data(contentsOf: Paths.configuration) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct Credentials: Codable { var username: String; var password: String }

enum Keychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Paths.label, kSecAttrAccount as String: "campus"]
    }
    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let changes: [String: Any] = [kSecValueData as String: data]
        var result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "校园网自动登录"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw CampusError.message("无法保存到钥匙串（\(result)）。") }
    }
    static func load(interactive: Bool = false) throws -> Credentials {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
        }
        var value: CFTypeRef?
        let result = SecItemCopyMatching(request as CFDictionary, &value)
        guard result == errSecSuccess, let data = value as? Data else {
            throw CampusError.message("凭据尚未设置，或钥匙串暂不可用。请打开校园网自动登录设置。")
        }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

struct NetworkSnapshot: Equatable {
    var interface: String
    var address: String
    var router: String
    var profile: String
    var joined: String
    var identity: String { [interface, address, router, profile, joined].joined(separator: "|") }
    static func current() -> NetworkSnapshot? {
        guard let store = SCDynamicStoreCreate(nil, "HBUT read network" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = global["PrimaryInterface"] as? String,
              let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              interfaces.contains(where: {
                  SCNetworkInterfaceGetBSDName($0) as String? == interface &&
                  SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211
              }),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/IPv4" as CFString) as? [String: Any],
              let address = (ipv4["Addresses"] as? [String])?.first,
              !address.hasPrefix("169.254.") else { return nil }
        let wifi = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(interface)/AirPort" as CFString) as? [String: Any] ?? [:]
        return NetworkSnapshot(interface: interface, address: address,
                               router: global["Router"] as? String ?? "",
                               profile: wifi["ProfileID"] as? String ?? "",
                               joined: String(describing: wifi["AutoJoinTimestamp"] ?? ""))
    }
    func matches(_ configuration: Configuration) -> Bool {
        !configuration.networkProfile.isEmpty && profile == configuration.networkProfile
    }
}

struct Status: Codable {
    static let changed = Notification.Name("local.hbut.autologin.statusChanged")
    var updated = ISO8601DateFormatter().string(from: Date())
    var code: String
    var text: String
    var blockedRevision: String? = nil
    var trigger: String? = nil
    var failureReason: String? = nil
    static func load() -> Status? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() {
        try? Paths.write(self, to: Paths.status)
        // Only fixed summaries are logged: no credentials, request URLs, MACs or sessions.
        let entry = "\(updated) \(code) \(text)" + (trigger.map { "（触发：\($0)）" } ?? "") + "\n"
        try? Paths.prepare()
        var data = (try? Data(contentsOf: Paths.log)) ?? Data()
        if data.count > 24_000 { data = Data() }
        data.append(Data(entry.utf8))
        try? data.write(to: Paths.log, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.log.path)
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

enum WakePolicy {
    static func mayRun(systemSleeping: Bool, displaySleepStates: [Bool]) -> Bool {
        !systemSleeping && displaySleepStates.contains(false)
    }
}

final class Cancellation {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func start(_ task: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        process = task
        try task.run()
    }
    func finished() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let process, process.isRunning { process.terminate() }
    }
    func pause(_ seconds: TimeInterval, deadline: TimeInterval) throws {
        let end = min(ProcessInfo.processInfo.systemUptime + seconds, deadline)
        while ProcessInfo.processInfo.systemUptime < end {
            if cancelled { throw CancellationError() }
            Thread.sleep(forTimeInterval: min(0.15, end - ProcessInfo.processInfo.systemUptime))
        }
        if cancelled { throw CancellationError() }
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    static func parse(_ data: Data) throws -> HTTPResponse {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw CampusError.message("服务器未返回有效 HTTP 响应。")
        }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first, let code = Int(first.split(separator: " ").dropFirst().first ?? "") else {
            throw CampusError.message("HTTP 状态无效。")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[split.upperBound...])
        if (100..<200).contains(code) { return try parse(body) }
        return HTTPResponse(status: code, headers: headers, body: body)
    }
    var appleSuccess: Bool {
        let html = text.lowercased().filter { !$0.isWhitespace }
        return status == 200 && html.contains("<title>success</title>") &&
            (html.contains("<body>success</body>") || html.contains("<h1>success</h1>"))
    }
    func json() throws -> [String: Any] {
        guard status == 200, let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CampusError.message("认证服务器未返回预期数据。")
        }
        return object
    }
}

final class DirectHTTP {
    let cancellation: Cancellation
    let deadline: TimeInterval
    init(_ cancellation: Cancellation, seconds: TimeInterval = 27) {
        self.cancellation = cancellation
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
    func request(_ url: URL, body: String? = nil, timeout: Double = 4, headOnly: Bool = false) throws -> HTTPResponse {
        if cancellation.cancelled { throw CancellationError() }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0.2 else { throw CampusError.message("本轮连接检查已超时，等待下一次开盖或手动重连。") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-q", "--noproxy", "*", "--ipv4", "--http1.1", "--silent", "--show-error", "--include",
                          "--user-agent", "Mozilla/5.0 (Macintosh; Mac OS X) AppleWebKit/605.1.15 CampusAutoLogin/1.0",
                          "--connect-timeout", "3", "--max-time", String(min(timeout, remaining)),
                          "--max-filesize", "262144", "--proto", "=http,https", "--max-redirs", "0", "--config", "-"]
        task.environment = ProcessInfo.processInfo.environment.filter { !$0.key.lowercased().hasSuffix("_proxy") }
        let input = Pipe(), output = Pipe()
        task.standardInput = input; task.standardOutput = output; task.standardError = FileHandle.nullDevice
        // URLs and POST bodies go through stdin, never the process argument list or disk.
        var configuration = "url = \(Self.quote(url.absoluteString))\nheader = \(Self.quote("Cache-Control: no-cache"))\n"
        if headOnly { configuration += "head\n" }
        if let body {
            configuration += "header = \(Self.quote("Content-Type: application/x-www-form-urlencoded; charset=UTF-8"))\ndata = \(Self.quote(body))\n"
        }
        try cancellation.start(task)
        defer { cancellation.finished() }
        try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8))
        try? input.fileHandleForWriting.close()
        let received = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try? output.fileHandleForReading.close()
        if cancellation.cancelled { throw CancellationError() }
        guard task.terminationStatus == 0, received.count <= 280_000 else {
            throw CampusError.message("直连请求未完成（\(task.terminationStatus)），本轮不会更改系统代理。")
        }
        return try HTTPResponse.parse(received)
    }
    func isOnline() -> Bool {
        if (try? request(Portal.secureProbe, timeout: 3).appleSuccess) == true { return true }
        // A single external endpoint can be temporarily unreachable even when
        // authentication is valid. The fallback still requires verified TLS.
        return (try? request(Portal.secondarySecureProbe, timeout: 2, headOnly: true).status) == 200
    }
}

enum Portal {
    static let origin = "http://172.16.54.18"
    static let probe = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let secureProbe = URL(string: "https://www.apple.com/library/test/success.html")!
    static let secondarySecureProbe = URL(string: "https://www.baidu.com/")!
    static let discoveryEntries = [URL(string: "http://1.1.1.1/")!, probe, URL(string: "http://www.baidu.com/")!]
    static let componentCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: componentCharacters)! }
    static func doubleEncode(_ value: String) -> String { encode(encode(value)) }
    static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "172.16.54.18" && (url.port == nil || url.port == 80 || url.port == 8080) &&
            url.user == nil && url.password == nil && url.path == "/eportal/index.jsp"
    }
    static func apiURL(for portalURL: URL, method: String) -> URL {
        var components = URLComponents(url: portalURL, resolvingAgainstBaseURL: false)!
        components.path = "/eportal/InterFace.do"
        components.query = "method=" + method
        components.fragment = nil
        return components.url!
    }
    static func redirect(in response: HTTPResponse, from url: URL) -> URL? {
        if let target = response.headers["location"] { return URL(string: target, relativeTo: url)?.absoluteURL }
        let patterns = [#"(?i)(?:window\.|document\.|self\.|top\.)?location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
                        #"(?i)location\.replace\(\s*["']([^"']+)["']"#,
                        #"(?i)http-equiv\s*=\s*["']refresh["'][^>]*content\s*=\s*["'][^"']*url=([^"']+)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: response.text, range: NSRange(response.text.startIndex..., in: response.text)),
                  let range = Range(match.range(at: 1), in: response.text) else { continue }
            return URL(string: String(response.text[range]).replacingOccurrences(of: "&amp;", with: "&"), relativeTo: url)?.absoluteURL
        }
        return nil
    }
    static func discover(fetch: (URL) throws -> HTTPResponse) throws -> URL? {
        for entry in discoveryEntries {
            do {
                let response = try fetch(entry)
                if let target = redirect(in: response, from: entry), isTrusted(target) { return target }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        return nil
    }
    static func contextQuery(_ url: URL, address: String) throws -> String {
        guard isTrusted(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name.lowercased() == "wlanuserip" })?.value == address,
              components.queryItems?.contains(where: { $0.name.lowercased() == "nasip" && !($0.value ?? "").isEmpty }) == true,
              let query = components.percentEncodedQuery else {
            throw CampusError.message("认证引导地址与当前校园连接不匹配，未提交凭据。")
        }
        return query
    }
    static func loginBody(credentials: Credentials, query: String, service: String, password: String, encrypted: Bool) -> String {
        let fields = [("userId", credentials.username), ("password", password), ("service", service),
                      ("queryString", query), ("operatorPwd", ""), ("operatorUserId", ""),
                      ("validcode", ""), ("passwordEncrypt", encrypted ? "true" : "false")]
        return fields.map { "\($0.0)=\(doubleEncode($0.1))" }.joined(separator: "&")
    }
}

enum LoginFailureReason: String {
    case credentials, account, service, alreadyOnline, gateway, unknown
    static func classify(_ response: [String: Any]) -> Self {
        let message = (["message", "msg", "errorMessage"].compactMap { response[$0] as? String }).joined(separator: " ").lowercased()
        func has(_ phrases: [String]) -> Bool { phrases.contains { message.contains($0) } }
        if has(["已经在线", "已在线", "重复登录", "already online"]) { return .alreadyOnline }
        if has(["运营商", "绑定服务", "服务未开通", "服务不存在"]) { return .service }
        if has(["会话", "参数", "认证设备", "网关", "nas", "服务器繁忙", "系统繁忙", "认证超时", "连接超时"]) { return .gateway }
        if has(["余额不足", "欠费", "已停用", "已停机", "已禁用", "账号过期", "账户过期", "账号被锁", "账户被锁", "冻结"]) { return .account }
        if has(["密码错误", "密码不正确", "用户名或密码", "账号或密码", "用户不存在", "用户名不存在", "invalid password", "incorrect password", "user not found", "user does not exist"]) { return .credentials }
        return .unknown
    }
    func status(revision: String) -> Status {
        let text: String
        switch self {
        case .credentials: text = "学校返回账号或密码校验失败，已暂停自动提交；请核对网页登录所用凭据后重新保存。"
        case .account: text = "学校返回账户状态受限，已暂停自动提交；请检查校园网账户状态。"
        case .service: text = "学校返回服务或运营商绑定问题，已暂停自动提交；请确认网页登录时选择的服务。"
        case .alreadyOnline: text = "学校提示当前会话已在线，但暂未确认直连联网；已暂停重复提交，可点立即检查复核。"
        case .gateway: text = "学校返回认证设备、会话或服务器异常；本轮结束，等待下次唤醒或手动检查。"
        case .unknown: text = "学校未接受本次认证，暂未识别原因；已暂停自动提交，可点立即检查手动重试一次。"
        }
        // Persist only fixed categories, never raw server messages that could
        // reflect an account, password, address or session parameter.
        return Status(code: self == .gateway ? "deferred" : "rejected", text: text,
                      blockedRevision: self == .gateway ? nil : revision, failureReason: rawValue)
    }
}

enum PortalRSA {
    static func bytes(_ hex: String) throws -> [UInt8] {
        let padded = hex.count.isMultiple(of: 2) ? hex : "0" + hex
        guard !padded.isEmpty, padded.allSatisfy({ $0.isHexDigit }) else { throw CampusError.message("认证服务器公钥无效。") }
        var result: [UInt8] = [], index = padded.startIndex
        while index < padded.endIndex {
            let next = padded.index(index, offsetBy: 2)
            result.append(UInt8(padded[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
    static func der(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        var length = bytes.count, encoded: [UInt8] = []
        repeat { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        let prefix: [UInt8] = bytes.count < 128 ? [UInt8(bytes.count)] : [0x80 | UInt8(encoded.count)] + encoded
        return [tag] + prefix + bytes
    }
    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var value = bytes
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if value[0] >= 128 { value.insert(0, at: 0) }
        return der(2, value)
    }
    static func encrypt(_ value: String, modulus: String, exponent: String) throws -> String {
        var n = try bytes(modulus)
        while n.count > 1 && n.first == 0 { n.removeFirst() }
        guard n.count >= 128, n.count <= 512 else { throw CampusError.message("认证公钥长度无效。") }
        let e = try bytes(exponent)
        let keyData = Data(der(0x30, integer(n) + integer(e)))
        var error: Unmanaged<CFError>?
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes, &error) else {
            throw CampusError.message("无法载入校园网认证公钥。")
        }
        // Match the school's RSAUtils: reverse UTF-16 units, pack little-endian,
        // zero-pad chunks of 2 * biHighIndex(modulus), then raw RSA.
        let units = Array(value.utf16.reversed())
        let chunkSize = 2 * ((n.count - 1) / 2)
        var chunks: [String] = []
        for start in stride(from: 0, to: max(1, units.count), by: chunkSize) {
            let slice = Array(units[start..<min(start + chunkSize, units.count)])
            guard slice.allSatisfy({ $0 <= 255 }) else { throw CampusError.message("学校认证加密暂不支持此密码字符，请先使用网页登录。") }
            var block = [UInt8](repeating: 0, count: n.count)
            for (offset, unit) in slice.enumerated() { block[n.count - 1 - offset] = UInt8(unit) }
            guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, Data(block) as CFData, &error) as Data? else {
                throw CampusError.message("校园网密码加密失败。")
            }
            var bytes = Array(encrypted)
            while bytes.count > 2 && bytes[0] == 0 && bytes[1] == 0 { bytes.removeFirst(2) }
            chunks.append(bytes.map { String(format: "%02x", $0) }.joined())
        }
        return chunks.joined(separator: " ")
    }
}

final class Authenticator {
    let configuration: Configuration
    let network: NetworkSnapshot
    let cancellation: Cancellation
    init(configuration: Configuration, network: NetworkSnapshot, cancellation: Cancellation) {
        self.configuration = configuration; self.network = network; self.cancellation = cancellation
    }
    func run() -> Status {
        if !network.matches(configuration) { return Status(code: "other-network", text: "当前不是已登记的校园 Wi-Fi，未发起认证。") }
        let http = DirectHTTP(cancellation)
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        do {
            try Paths.prepare()
            descriptor = open(Paths.directory.appendingPathComponent("login.lock").path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                return Status(code: "busy", text: "已有一次认证检查正在运行。")
            }
            if http.isOnline() {
                return Status(code: "online", text: "已联网，无需重复登录。")
            }
            var portalURL: URL?
            for attempt in 0..<3 {
                if attempt > 0 { try cancellation.pause(2, deadline: http.deadline) }
                // Failure of an external detector must not skip the IP portal entry.
                // Each discovery request is independent; no credentials are attached.
                portalURL = try Portal.discover { try http.request($0, timeout: 2) }
                if portalURL != nil { break }
                if http.deadline - ProcessInfo.processInfo.systemUptime < 2 { break }
                // A network may finish reconnecting during discovery.
                if attempt < 2, http.isOnline() {
                    return Status(code: "online", text: "已联网，无需重复登录。")
                }
            }
            guard let portalURL else { return Status(code: "unavailable", text: "暂未获取校园网认证引导，等待下次开盖或手动重连。") }
            let query = try Portal.contextQuery(portalURL, address: network.address)
            let page = try http.request(portalURL)
            guard page.status == 200, page.text.contains("AuthInterFace.pageInfo"), page.text.contains("passwordEncrypt") else {
                throw CampusError.message("认证页面特征不匹配，未提交凭据。")
            }
            let info = try http.request(Portal.apiURL(for: portalURL, method: "pageInfo"),
                                        body: "queryString=" + Portal.encode(query)).json()
            guard (info["validCodeUrl"] as? String ?? "").isEmpty,
                  (info["isToCasPage"] as? String ?? "false") == "false" else {
                return Status(code: "manual-required", text: "校园网本次要求额外验证，请先使用网页登录。")
            }
            let credentials = try Keychain.load()
            let encrypted = (info["passwordEncrypt"] as? String) == "true"
            var password = credentials.password
            if encrypted {
                guard let modulus = info["publicKeyModulus"] as? String, let exponent = info["publicKeyExponent"] as? String else {
                    throw CampusError.message("认证服务器未提供加密公钥。")
                }
                let mac = URLComponents(url: portalURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mac" })?.value
                password = try PortalRSA.encrypt(password + ">" + ((mac?.isEmpty == false) ? mac! : "111111111"), modulus: modulus, exponent: exponent)
            }
            guard NetworkSnapshot.current()?.identity == network.identity else { throw CancellationError() }
            let body = Portal.loginBody(credentials: credentials, query: query, service: configuration.service, password: password, encrypted: encrypted)
            // A credentials submission is made at most once per event batch.
            let result = try http.request(Portal.apiURL(for: portalURL, method: "login"), body: body, timeout: 5).json()
            guard result["result"] as? String == "success" else {
                if http.isOnline() {
                    return Status(code: "online", text: "当前连接已认证，无需再次提交。")
                }
                return LoginFailureReason.classify(result).status(revision: configuration.revision)
            }
            // The gateway can acknowledge authentication before opening Internet access.
            // Retry only connectivity verification, never the credentials submission.
            for attempt in 0..<3 {
                if http.deadline - ProcessInfo.processInfo.systemUptime < 0.3 { break }
                try cancellation.pause(attempt == 0 ? 1 : 2, deadline: http.deadline)
                if http.isOnline() {
                    return Status(code: "connected", text: "校园网自动登录成功。")
                }
            }
            return Status(code: "submitted", text: "认证服务器已接受登录，暂未确认外网连通。")
        } catch is CancellationError {
            return Status(code: "cancelled", text: "已合盖或网络变化，本轮检查已取消。")
        } catch {
            return Status(code: "deferred", text: (error as? CampusError)?.errorDescription ?? "本轮认证检查未完成，等待下一次触发。")
        }
    }
}
