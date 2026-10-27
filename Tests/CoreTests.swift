import Foundation

@main struct CoreTests {
    static func main() throws {
        var passed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAILED: " + name) }
            passed += 1
        }
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n".utf8)
        let success = try HTTPResponse.parse(raw)
        expect(success.appleSuccess, "real Apple success response")
        expect(success.headers["content-type"] == "text/html", "case insensitive HTTP headers")
        expect(!HTTPResponse(status: 200, headers: [:], body: Data("<html>请登录</html>".utf8)).appleSuccess, "login page is not connectivity success")
        expect(!HTTPResponse(status: 302, headers: [:], body: success.body).appleSuccess, "redirect is not connectivity success")
        let interim = try HTTPResponse.parse(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8) + raw)
        expect(interim.appleSuccess, "interim HTTP status")
        let context = "wlanuserip=192.0.2.2&wlanacname=logic&nasip=198.51.100.1&url=http://1.1.1.1/"
        let trusted = URL(string: Portal.origin + "/eportal/index.jsp?" + context)!
        expect(Portal.isTrusted(trusted), "confirmed school portal allowed")
        expect(!Portal.isTrusted(URL(string: "http://172.16.54.18.example.com/eportal/index.jsp")!), "host suffix attack rejected")
        expect(!Portal.isTrusted(URL(string: "http://172.16.54.18@evil.example/eportal/index.jsp")!), "userinfo attack rejected")
        expect(!Portal.isTrusted(URL(string: "http://172.16.54.18/eportal/logout")!), "other paths rejected")
        expect(Portal.isTrusted(URL(string: "http://172.16.54.18:8080/eportal/index.jsp")!), "school's confirmed web port allowed")
        expect(!Portal.isTrusted(URL(string: "http://172.16.54.18:801/eportal/index.jsp")!), "unconfirmed port rejected")
        expect(Portal.apiURL(for: trusted, method: "login").absoluteString == Portal.origin + "/eportal/InterFace.do?method=login", "API uses confirmed portal origin")
        expect(Portal.discoveryEntries.first?.host == "1.1.1.1", "IP discovery precedes DNS-dependent fallback entries")
        expect(Portal.secureProbe.scheme == "https", "connectivity verification is TLS protected")
        expect(Portal.secondarySecureProbe.scheme == "https" && Portal.secondarySecureProbe.host != Portal.secureProbe.host, "fallback connectivity verification uses an independent TLS endpoint")
        let query = try Portal.contextQuery(trusted, address: "192.0.2.2")
        expect(query == context, "fresh query is preserved verbatim")
        var rejectedStaleIP = false
        do { _ = try Portal.contextQuery(trusted, address: "192.0.2.3") } catch { rejectedStaleIP = true }
        expect(rejectedStaleIP, "stale client IP rejected")
        let redirect = HTTPResponse(status: 200, headers: [:], body: Data("<script>location.href='\(trusted.absoluteString.replacingOccurrences(of: "&", with: "&amp;"))';</script>".utf8))
        expect(Portal.redirect(in: redirect, from: Portal.probe) == trusted, "JavaScript redirect extraction without execution")
        let headerRedirect = HTTPResponse(status: 302, headers: ["location": trusted.absoluteString], body: Data())
        expect(Portal.redirect(in: headerRedirect, from: Portal.probe) == trusted, "HTTP redirect extraction")
        var attempts = 0
        let discovered = try Portal.discover { _ in
            attempts += 1
            if attempts == 1 { throw CampusError.message("simulated timeout") }
            return headerRedirect
        }
        expect(discovered == trusted && attempts == 2, "a timed-out discovery endpoint does not skip the next endpoint")
        var cancellationPropagated = false
        do { _ = try Portal.discover { _ in throw CancellationError() } } catch is CancellationError { cancellationPropagated = true }
        expect(cancellationPropagated, "sleep cancellation stops discovery immediately")
        expect(Portal.doubleEncode("a+b&中") == "a%252Bb%2526%25E4%25B8%25AD", "school double encode matches JavaScript")
        let body = Portal.loginBody(credentials: Credentials(username: "a&b", password: "unused"), query: context, service: "default", password: "cipher", encrypted: true)
        expect(body.contains("userId=a%2526b&password=cipher&service=default&"), "form values cannot inject parameters")
        expect(body.hasSuffix("&passwordEncrypt=true"), "encryption flag is explicit")
        expect(!body.contains("unused"), "plaintext credential is not used in encrypted form")
        let network = NetworkSnapshot(interface: "en0", address: "192.0.2.2", router: "192.0.2.1", profile: "test-profile", joined: "test-time")
        expect(network.matches(Configuration(networkProfile: "test-profile")), "registered Wi-Fi recognized")
        expect(!network.matches(Configuration(networkProfile: "different")), "other Wi-Fi rejected")
        expect(!NetworkSnapshot(interface: "en0", address: "192.0.2.2", router: "192.0.2.1", profile: "", joined: "").matches(Configuration(networkProfile: "")), "missing identifier fails closed")
        expect(WakePolicy.mayRun(systemSleeping: false, displaySleepStates: [false]), "external display awake after clamshell wake permits a check")
        expect(WakePolicy.mayRun(systemSleeping: false, displaySleepStates: [true, false]), "sleeping built-in display does not mask an awake external display")
        expect(!WakePolicy.mayRun(systemSleeping: false, displaySleepStates: [true]), "dark wake does not start network checks")
        expect(!WakePolicy.mayRun(systemSleeping: true, displaySleepStates: [false]), "system sleep always blocks checks")
        expect(!WakePolicy.mayRun(systemSleeping: false, displaySleepStates: []), "missing display state fails closed")
        let oldStatus = try JSONDecoder().decode(Status.self, from: Data(#"{"updated":"2026-10-26T11:26:27Z","code":"online","text":"online"}"#.utf8))
        expect(oldStatus.trigger == nil && oldStatus.code == "online", "existing status records remain readable after adding trigger details")
        expect(oldStatus.failureReason == nil, "existing status records remain readable after adding failure categories")
        expect(LoginFailureReason.classify(["result": "fail", "message": "用户名或密码错误"]) == .credentials, "explicit credential failure is distinguished")
        expect(LoginFailureReason.classify(["result": "fail", "message": "用户已经在线"]) == .alreadyOnline, "existing session is not classified as a bad password")
        expect(LoginFailureReason.classify(["result": "fail", "message": "未绑定服务对应的运营商"]) == .service, "operator binding is not classified as a bad password")
        let gateway = LoginFailureReason.classify(["message": "认证设备未注册或会话参数过期"]).status(revision: "example")
        expect(gateway.code == "deferred" && gateway.blockedRevision == nil, "temporary gateway problems do not permanently block future wake checks")
        let unknown = LoginFailureReason.classify(["message": "unexpected reflection account-12345 secret-example http://192.0.2.1/?session=private"]).status(revision: "example")
        let encodedUnknown = String(decoding: try JSONEncoder().encode(unknown), as: UTF8.self)
        expect(unknown.failureReason == "unknown" && unknown.blockedRevision == "example", "unrecognized refusal is reported honestly and stops automatic resubmission")
        expect(!encodedUnknown.contains("account-12345") && !encodedUnknown.contains("secret-example") && !encodedUnknown.contains("session=private"), "server reflections never enter saved status or event text")
        let skipped = Authenticator(configuration: Configuration(networkProfile: "different"), network: network, cancellation: Cancellation()).run()
        expect(skipped.code == "other-network", "other Wi-Fi never starts an HTTP or keychain request")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/RSAFixture.json"))) as! [String: String]
        let encrypted = try PortalRSA.encrypt(fixture["plaintext"]!, modulus: fixture["modulus"]!, exponent: fixture["exponent"]!)
        expect(encrypted == fixture["expected"], "native RSA matches independent mathematical reference")
        expect(DirectHTTP.quote("a\"b\\c\n") == "\"a\\\"b\\\\c\\n\"", "curl stdin config escaping")
        print("\(passed) checks passed; no real credentials or login submissions used.")
    }
}
