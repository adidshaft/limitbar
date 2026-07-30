import AppKit
import Foundation
import ServiceManagement

// MARK: - Model

struct UsageWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct ServiceUsage {
    var plan: String?
    var windows: [UsageWindow] = []
    var extras: [UsageWindow] = []
    var error: String?
    // The most-constrained main window drives the number in the menu bar.
    var binding: UsageWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

enum FetchError: LocalizedError {
    case notLoggedIn(String)
    case http(Int, String)
    case parse(String)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let s): return s
        case .http(let code, let body): return "HTTP \(code): \(String(body.prefix(120)))"
        case .parse(let s): return s
        }
    }
}

// MARK: - Helpers

@discardableResult
func shell(_ command: [String], timeout: TimeInterval = 15) -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    // `security` blocks indefinitely on a keychain-unlock dialog; a deadline keeps
    // one wedged subprocess from freezing every future refresh.
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func httpJSON(_ urlString: String, method: String = "GET",
              headers: [String: String] = [:], jsonBody: [String: Any]? = nil,
              timeout: TimeInterval = 25) throws -> [String: Any] {
    guard let url = URL(string: urlString) else { throw FetchError.parse("bad URL") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let body = jsonBody {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<(Data, Int), Error> = .failure(FetchError.parse("no response"))
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            outcome = .failure(error)
        } else {
            outcome = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        semaphore.signal()
    }.resume()
    if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
        throw FetchError.parse("request timed out")
    }
    let (data, code) = try outcome.get()
    guard (200..<300).contains(code) else {
        throw FetchError.http(code, String(data: data, encoding: .utf8) ?? "")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FetchError.parse("non-object JSON response")
    }
    return object
}

func parseISO(_ value: Any?) -> Date? {
    guard var str = value as? String else { return nil }
    // ISO8601DateFormatter chokes on 6-digit fractional seconds; the date is all we need.
    if let range = str.range(of: "\\.\\d+", options: .regularExpression) {
        str.removeSubrange(range)
    }
    return ISO8601DateFormatter().date(from: str)
}

// MARK: - Claude (token in Keychain, same storage Claude Code uses)

struct ClaudeSource {
    static let keychainService = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-cli/2.1.214 (external, cli)"
    // Freshest chain seen this process, plus the store refresh token it descends
    // from ("ancestor") — fallback so a failed keychain write-back after token
    // rotation can't strand the only valid refresh token. Writes to the store are
    // gated on EXACT token match (consumed or ancestor), never on timestamps:
    // a store holding any other token is foreign (new login / CLI rotation) and
    // must never be clobbered.
    static var memoryCreds: [String: Any]?
    static var memoryAncestor: String?
    static let memoryLock = NSLock()

    func fetch() -> ServiceUsage {
        do {
            var (creds, ancestor) = try readCredentials()
            let expiresAt = (creds["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            if expiresAt < Date().timeIntervalSince1970 * 1000 + 60_000 {
                (creds, ancestor) = try refresh(creds, ancestorToken: ancestor)
            }
            guard let token = creds["accessToken"] as? String else {
                throw FetchError.notLoggedIn("No access token — log in with `claude`")
            }
            do {
                return try usage(token: token, creds: creds)
            } catch FetchError.http(401, _) {
                (creds, ancestor) = try refresh(creds, ancestorToken: ancestor)
                guard let retryToken = creds["accessToken"] as? String else {
                    throw FetchError.notLoggedIn("No access token after refresh")
                }
                return try usage(token: retryToken, creds: creds)
            }
        } catch {
            var usage = ServiceUsage()
            usage.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return usage
        }
    }

    private func usage(token: String, creds: [String: Any]) throws -> ServiceUsage {
        let json = try httpJSON("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": Self.userAgent,
        ])
        var usage = ServiceUsage()
        if let plan = creds["subscriptionType"] as? String { usage.plan = plan.capitalized }
        if let w = window(json["five_hour"], label: "Session (5h)") { usage.windows.append(w) }
        if let w = window(json["seven_day"], label: "Weekly") { usage.windows.append(w) }
        if let w = window(json["seven_day_opus"], label: "Weekly · Opus") { usage.extras.append(w) }
        if let w = window(json["seven_day_sonnet"], label: "Weekly · Sonnet") { usage.extras.append(w) }
        guard !usage.windows.isEmpty else { throw FetchError.parse("no usage windows in response") }
        return usage
    }

    private func window(_ object: Any?, label: String) -> UsageWindow? {
        guard let dict = object as? [String: Any],
              let pct = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(label: label, usedPercent: pct, resetsAt: parseISO(dict["resets_at"]))
    }

    private func readCredentials() throws -> (creds: [String: Any], ancestor: String) {
        var storeAbsent = false
        let store: [String: Any]?
        do {
            store = try readStore()
        } catch FetchError.notLoggedIn {
            store = nil
            storeAbsent = true  // affirmatively deleted (logout), not merely unreadable
        } catch {
            store = nil
        }
        let storeToken = store?["refreshToken"] as? String
        Self.memoryLock.lock()
        let cached = Self.memoryCreds
        let cachedAncestor = Self.memoryAncestor
        Self.memoryLock.unlock()
        if let cached, let cachedAncestor {
            if storeAbsent {
                clearMemory()  // user logged out: don't keep the chain alive from memory
            } else if store == nil {
                return (cached, cachedAncestor)  // transiently unreadable: memory carries the chain
            } else if let storeToken, storeToken == cachedAncestor {
                // Store still holds the consumed parent (an earlier write-back
                // failed): memory is the live descendant. Retry the repair now so
                // the real CLI isn't left with a dead token any longer than needed.
                if persist(cached, consumedRefreshToken: cachedAncestor, ancestorToken: cachedAncestor),
                   let ownToken = cached["refreshToken"] as? String {
                    return (cached, ownToken)  // store now holds our chain: rebase the ancestor
                }
                return (cached, cachedAncestor)
            } else {
                clearMemory()  // store moved past us (new login / CLI rotation): adopt it
            }
        }
        guard let store else {
            throw FetchError.notLoggedIn("Keychain item not found — log in with `claude`")
        }
        return (store, storeToken ?? "")
    }

    private func clearMemory() {
        Self.memoryLock.lock()
        Self.memoryCreds = nil
        Self.memoryAncestor = nil
        Self.memoryLock.unlock()
    }

    private func readStore() throws -> [String: Any] {
        let (status, out) = shell(["/usr/bin/security", "find-generic-password",
                                   "-s", Self.keychainService, "-w"])
        if status == 44 {  // errSecItemNotFound: affirmative absence, i.e. logged out
            throw FetchError.notLoggedIn("Keychain item not found — log in with `claude`")
        }
        guard status == 0, !out.isEmpty else {
            throw FetchError.parse("keychain unavailable (status \(status))")
        }
        guard let data = out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = object["claudeAiOauth"] as? [String: Any] else {
            throw FetchError.parse("unrecognized keychain credential format")
        }
        return creds
    }

    private func refresh(_ old: [String: Any],
                         ancestorToken: String) throws -> (creds: [String: Any], ancestor: String) {
        guard let refreshToken = old["refreshToken"] as? String else {
            throw FetchError.notLoggedIn("No refresh token — log in with `claude`")
        }
        let json = try httpJSON("https://platform.claude.com/v1/oauth/token", method: "POST",
            headers: ["User-Agent": Self.userAgent],
            jsonBody: ["grant_type": "refresh_token",
                       "refresh_token": refreshToken,
                       "client_id": Self.clientID])
        guard let accessToken = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw FetchError.parse("token refresh response missing fields")
        }
        var updated = old
        updated["accessToken"] = accessToken
        if let newRefresh = json["refresh_token"] as? String { updated["refreshToken"] = newRefresh }
        updated["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        Self.memoryLock.lock()
        Self.memoryCreds = updated
        Self.memoryAncestor = ancestorToken
        Self.memoryLock.unlock()
        if persist(updated, consumedRefreshToken: refreshToken, ancestorToken: ancestorToken),
           let ownToken = updated["refreshToken"] as? String {
            return (updated, ownToken)  // store now holds this chain: rebase the ancestor
        }
        return (updated, ancestorToken)
    }

    // Write back so Claude Code and this app share one valid token chain.
    // A write may only replace a store that provably still holds our own chain's
    // past — the exact token we just consumed, or the store token our in-memory
    // chain descends from. Anything else (different token, missing token,
    // unreadable/unrecognized store) is foreign and must never be clobbered.
    // Returns true only when the write landed.
    @discardableResult
    private func persist(_ creds: [String: Any], consumedRefreshToken: String, ancestorToken: String) -> Bool {
        guard let current = try? readStore(),
              let storeToken = current["refreshToken"] as? String else {
            NSLog("LimitBar: keychain not in a known state during write-back; keeping refreshed token in memory")
            return false
        }
        guard storeToken == consumedRefreshToken || storeToken == ancestorToken else {
            // Foreign chain (new login or CLI rotation mid-flight): the store is
            // the newer truth — drop our fork and adopt it next cycle.
            clearMemory()
            return false
        }
        // Splice only the token fields so anything else the CLI wrote meanwhile survives.
        var merged = current
        for key in ["accessToken", "refreshToken", "expiresAt"] { merged[key] = creds[key] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": merged]),
              let payload = String(data: data, encoding: .utf8) else { return false }
        let (status, _) = shell(["/usr/bin/security", "add-generic-password", "-U",
                                 "-s", Self.keychainService, "-a", NSUserName(), "-w", payload])
        if status == 0 {
            clearMemory()
            return true
        }
        NSLog("LimitBar: keychain write-back failed (status %d); keeping refreshed token in memory", status)
        return false
    }
}

// MARK: - Codex (token in ~/.codex/auth.json, same storage the Codex CLI uses)

struct CodexSource {
    static let authPath = NSHomeDirectory() + "/.codex/auth.json"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userAgent = "codex_cli_rs"
    // Freshest auth seen this process, plus the store refresh token it descends
    // from ("ancestor") — fallback so a failed auth.json write-back after token
    // rotation can't strand the only valid refresh token. Writes are gated on
    // EXACT token match (consumed or ancestor), never on timestamps.
    static var memoryAuth: [String: Any]?
    static var memoryAncestor: String?
    static let memoryLock = NSLock()

    func fetch() -> ServiceUsage {
        do {
            var (auth, ancestor) = try readAuth()
            var tokens = auth["tokens"] as? [String: Any] ?? [:]
            if jwtExpiry(tokens["access_token"] as? String) < Date().timeIntervalSince1970 + 60 {
                (auth, tokens, ancestor) = try refresh(auth: auth, tokens: tokens, ancestorToken: ancestor)
            }
            guard let token = tokens["access_token"] as? String else {
                throw FetchError.notLoggedIn("No access token — run `codex login`")
            }
            do {
                return try usage(token: token, accountID: tokens["account_id"] as? String)
            } catch FetchError.http(401, _) {
                (auth, tokens, ancestor) = try refresh(auth: auth, tokens: tokens, ancestorToken: ancestor)
                guard let retryToken = tokens["access_token"] as? String else {
                    throw FetchError.notLoggedIn("No access token after refresh")
                }
                return try usage(token: retryToken, accountID: tokens["account_id"] as? String)
            }
        } catch {
            var usage = ServiceUsage()
            usage.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return usage
        }
    }

    private func usage(token: String, accountID: String?) throws -> ServiceUsage {
        var headers = ["Authorization": "Bearer \(token)",
                       "originator": Self.userAgent,
                       "User-Agent": Self.userAgent]
        if let accountID { headers["chatgpt-account-id"] = accountID }
        let json = try httpJSON("https://chatgpt.com/backend-api/wham/usage", headers: headers)
        var usage = ServiceUsage()
        if let plan = json["plan_type"] as? String { usage.plan = plan.capitalized }
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let w = window(rateLimit["primary_window"]) { usage.windows.append(w) }
            if let w = window(rateLimit["secondary_window"]) { usage.windows.append(w) }
        }
        for extra in (json["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            guard let name = extra["limit_name"] as? String,
                  let rateLimit = extra["rate_limit"] as? [String: Any],
                  let w = window(rateLimit["primary_window"], labelOverride: name) else { continue }
            usage.extras.append(w)
        }
        guard !usage.windows.isEmpty else { throw FetchError.parse("no rate-limit windows in response") }
        return usage
    }

    private func window(_ object: Any?, labelOverride: String? = nil) -> UsageWindow? {
        guard let dict = object as? [String: Any],
              let pct = (dict["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let label = labelOverride ?? windowLabel((dict["limit_window_seconds"] as? NSNumber)?.doubleValue)
        var resetsAt: Date?
        if let epoch = (dict["reset_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = (dict["reset_after_seconds"] as? NSNumber)?.doubleValue {
            resetsAt = Date().addingTimeInterval(after)
        }
        return UsageWindow(label: label, usedPercent: pct, resetsAt: resetsAt)
    }

    private func windowLabel(_ seconds: Double?) -> String {
        guard let s = seconds else { return "Limit" }
        if s <= 6 * 3600 { return "Session (5h)" }
        if s >= 6 * 86400 { return "Weekly" }
        return "\(Int(s / 3600))h limit"
    }

    private func readAuth() throws -> (auth: [String: Any], ancestor: String) {
        var storeAbsent = false
        let store: [String: Any]?
        do {
            store = try readStore()
        } catch FetchError.notLoggedIn {
            store = nil
            storeAbsent = true  // file affirmatively deleted (logout), not merely unreadable
        } catch {
            store = nil
        }
        let storeToken = ((store?["tokens"] as? [String: Any])?["refresh_token"]) as? String
        Self.memoryLock.lock()
        let cached = Self.memoryAuth
        let cachedAncestor = Self.memoryAncestor
        Self.memoryLock.unlock()
        if let cached, let cachedAncestor {
            if storeAbsent {
                clearMemory()  // user logged out: don't keep the chain alive from memory
            } else if store == nil {
                return (cached, cachedAncestor)  // transiently unreadable: memory carries the chain
            } else if let storeToken, storeToken == cachedAncestor {
                // Store still holds the consumed parent (an earlier write-back
                // failed): memory is the live descendant. Retry the repair now so
                // the real CLI isn't left with a dead token any longer than needed.
                if persist(cached, consumedRefreshToken: cachedAncestor, ancestorToken: cachedAncestor),
                   let ownToken = ((cached["tokens"] as? [String: Any])?["refresh_token"]) as? String {
                    return (cached, ownToken)  // store now holds our chain: rebase the ancestor
                }
                return (cached, cachedAncestor)
            } else {
                // Store moved past us (new login, CLI rotation, or a switch to
                // API-key auth with no tokens at all): adopt whatever it says.
                clearMemory()
            }
        }
        guard let store else {
            throw FetchError.notLoggedIn("~/.codex/auth.json not found — run `codex login`")
        }
        return (store, storeToken ?? "")
    }

    private func clearMemory() {
        Self.memoryLock.lock()
        Self.memoryAuth = nil
        Self.memoryAncestor = nil
        Self.memoryLock.unlock()
    }

    private func readStore() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: Self.authPath) else {
            // Affirmative absence, i.e. logged out.
            throw FetchError.notLoggedIn("~/.codex/auth.json not found — run `codex login`")
        }
        guard let data = FileManager.default.contents(atPath: Self.authPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parse("auth.json unreadable")
        }
        return object
    }

    private func jwtExpiry(_ jwt: String?) -> Double {
        guard let jwt else { return 0 }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return 0 }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue else { return 0 }
        return exp
    }

    private func refresh(auth: [String: Any], tokens: [String: Any], ancestorToken: String)
        throws -> (auth: [String: Any], tokens: [String: Any], ancestor: String) {
        guard let refreshToken = tokens["refresh_token"] as? String else {
            throw FetchError.notLoggedIn("No refresh token — run `codex login`")
        }
        let json = try httpJSON("https://auth.openai.com/oauth/token", method: "POST",
            headers: ["User-Agent": Self.userAgent],
            jsonBody: ["client_id": Self.clientID,
                       "grant_type": "refresh_token",
                       "refresh_token": refreshToken,
                       "scope": "openid profile email"])
        guard let accessToken = json["access_token"] as? String else {
            throw FetchError.parse("Codex token refresh missing access_token")
        }
        var newTokens = tokens
        newTokens["access_token"] = accessToken
        if let idToken = json["id_token"] as? String { newTokens["id_token"] = idToken }
        if let newRefresh = json["refresh_token"] as? String { newTokens["refresh_token"] = newRefresh }
        var newAuth = auth
        newAuth["tokens"] = newTokens
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        newAuth["last_refresh"] = formatter.string(from: Date())
        Self.memoryLock.lock()
        Self.memoryAuth = newAuth
        Self.memoryAncestor = ancestorToken
        Self.memoryLock.unlock()
        if persist(newAuth, consumedRefreshToken: refreshToken, ancestorToken: ancestorToken),
           let ownToken = newTokens["refresh_token"] as? String {
            return (newAuth, newTokens, ownToken)  // store now holds this chain: rebase the ancestor
        }
        return (newAuth, newTokens, ancestorToken)
    }

    // A write may only replace a store that provably still holds our own chain's
    // past — the exact token we just consumed, or the store token our in-memory
    // chain descends from. Anything else (different token, missing token — e.g.
    // API-key auth, unreadable store) is foreign and must never be clobbered.
    // Returns true only when the write landed.
    @discardableResult
    private func persist(_ newAuth: [String: Any], consumedRefreshToken: String, ancestorToken: String) -> Bool {
        guard let current = try? readStore(),
              let storeToken = ((current["tokens"] as? [String: Any])?["refresh_token"]) as? String else {
            NSLog("LimitBar: auth.json not in a known state during write-back; keeping refreshed tokens in memory")
            return false
        }
        guard storeToken == consumedRefreshToken || storeToken == ancestorToken else {
            // Foreign chain (new login or CLI rotation mid-flight): the store is
            // the newer truth — drop our fork and adopt it next cycle.
            clearMemory()
            return false
        }
        // Splice only the token fields so anything else the CLI wrote meanwhile
        // (e.g. a newly added OPENAI_API_KEY) survives.
        var merged = current
        merged["tokens"] = newAuth["tokens"]
        merged["last_refresh"] = newAuth["last_refresh"]
        do {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            // Atomic: a torn in-place write here would log the real Codex CLI out.
            try data.write(to: URL(fileURLWithPath: Self.authPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.authPath)
            clearMemory()
            return true
        } catch {
            NSLog("LimitBar: auth.json write-back failed (%@); keeping refreshed tokens in memory", "\(error)")
            return false
        }
    }
}

// MARK: - Icons (drawn in code, template images so they adapt to menu bar appearance)

enum Icons {
    static func claude() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 16)
            transform.concat()
            NSColor.black.setStroke()
            let center = CGPoint(x: 8, y: 8)
            let rays = 9
            for i in 0..<rays {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(rays) + .pi / 2
                let inner: CGFloat = 1.1
                let outer: CGFloat = i.isMultiple(of: 2) ? 7.4 : 6.5
                let path = NSBezierPath()
                path.lineWidth = 1.9
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                path.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func openAI() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 16)
            transform.concat()
            NSColor.black.setStroke()
            // Hexagon sides, each overshooting one corner: the braided-knot look.
            for i in 0..<6 {
                let path = NSBezierPath()
                path.lineWidth = 2.1
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: -2.8, y: 4.85))
                path.line(to: NSPoint(x: 5.4, y: 4.85))
                var tf = AffineTransform(translationByX: 8, byY: 8)
                tf.rotate(byRadians: CGFloat(i) * .pi / 3)
                path.transform(using: tf)
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var claudeItem: NSStatusItem!
    private var codexItem: NSStatusItem!
    private let menu = NSMenu()
    private var claude = ServiceUsage()
    private var codex = ServiceUsage()
    private var lastUpdated: Date?
    private var claudeFetching = false
    private var codexFetching = false
    private var menuIsOpen = false
    private var isFetching: Bool { claudeFetching || codexFetching }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Created right-to-left: Codex first so Claude ends up on the left.
        codexItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        claudeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        claudeItem.autosaveName = "LimitBar.claude"
        codexItem.autosaveName = "LimitBar.codex"
        configure(claudeItem, icon: Icons.claude())
        configure(codexItem, icon: Icons.openAI())
        menu.delegate = self
        menu.autoenablesItems = false
        claudeItem.menu = menu
        codexItem.menu = menu

        refresh()
        // .common so the timer keeps firing while a menu is open.
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    private func configure(_ item: NSStatusItem, icon: NSImage) {
        guard let button = item.button else { return }
        button.image = icon
        button.imagePosition = .imageLeft
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = " …"
    }

    // Each service fetches and publishes independently, so one wedged or slow
    // source can never freeze the other item or block future refreshes.
    @objc func refresh() {
        if !claudeFetching {
            claudeFetching = true
            DispatchQueue.global().async {
                let result = ClaudeSource().fetch()
                DispatchQueue.main.async {
                    self.claude = result
                    self.claudeFetching = false
                    self.lastUpdated = Date()
                    self.updateButtons()
                }
            }
        }
        if !codexFetching {
            codexFetching = true
            DispatchQueue.global().async {
                let result = CodexSource().fetch()
                DispatchQueue.main.async {
                    self.codex = result
                    self.codexFetching = false
                    self.lastUpdated = Date()
                    self.updateButtons()
                }
            }
        }
        if menuIsOpen { rebuildMenu() }
    }

    private func updateButtons() {
        update(item: claudeItem, usage: claude, name: "Claude")
        update(item: codexItem, usage: codex, name: "Codex")
        // Keep an open menu in sync with data landing underneath it.
        if menuIsOpen { rebuildMenu() }
    }

    private func update(item: NSStatusItem, usage: ServiceUsage, name: String) {
        guard let button = item.button else { return }
        guard usage.error == nil, let binding = usage.binding else {
            button.title = " –"
            button.toolTip = "\(name): \(usage.error ?? "no data")"
            return
        }
        let pct = Int(binding.remainingPercent.rounded())
        let text = " \(pct)%"
        if pct <= 10 {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.systemRed,
            ])
        } else {
            button.title = text
        }
        button.toolTip = name + " — " + usage.windows
            .map { "\($0.label): \(Int($0.remainingPercent.rounded()))% left" }
            .joined(separator: " · ")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
        if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            refresh()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        let items = buildMenuItems()
        // While the menu is open, prefer updating titles in place: a full
        // remove-and-re-add shifts rows under the cursor and drops the highlight.
        let structureMatches = menu.items.count == items.count
            && zip(menu.items, items).allSatisfy {
                $0.isSeparatorItem == $1.isSeparatorItem && $0.action == $1.action
            }
        if structureMatches {
            for (old, new) in zip(menu.items, items) where !old.isSeparatorItem {
                old.title = new.title
                old.isEnabled = new.isEnabled
                old.state = new.state
            }
        } else {
            menu.removeAllItems()
            items.forEach { menu.addItem($0) }
        }
    }

    private func buildMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items += sectionItems(name: "Claude", usage: claude)
        items.append(.separator())
        items += sectionItems(name: "Codex", usage: codex)
        items.append(.separator())

        let updatedTitle = isFetching
            ? "Updating…"
            : lastUpdated.map { "Updated \(timeFormatter.string(from: $0))" } ?? "Updating…"
        let updated = NSMenuItem(title: updatedTitle, action: nil, keyEquivalent: "")
        updated.isEnabled = false
        items.append(updated)

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        items.append(refreshItem)

        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            items.append(login)
        }
        items.append(.separator())
        let quit = NSMenuItem(title: "Quit LimitBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        items.append(quit)
        return items
    }

    private func sectionItems(name: String, usage: ServiceUsage) -> [NSMenuItem] {
        let title = usage.plan.map { "\(name) — \($0) plan" } ?? name
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        var items = [header]
        if let error = usage.error {
            let item = NSMenuItem(title: "⚠︎ " + String(error.prefix(70)), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            items.append(item)
            return items
        }
        for w in usage.windows + usage.extras {
            let line = "\(w.label): \(Int(w.remainingPercent.rounded()))% left\(resetSuffix(w.resetsAt))"
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            items.append(item)
        }
        return items
    }

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func resetSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return " · resets \(f.string(from: date))"
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error)")
        }
    }
}

// MARK: - CLI modes for headless testing

func dumpIcons(to dir: String) {
    for (name, image) in [("claude", Icons.claude()), ("openai", Icons.openAI())] {
        let px = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        image.draw(in: NSRect(x: 8, y: 8, width: px - 16, height: px - 16))
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("\(dir)/\(name).png")
        }
    }
}

func describeFetch() {
    func describe(_ name: String, _ usage: ServiceUsage) {
        if let error = usage.error {
            print("\(name): ERROR — \(error)")
            return
        }
        let parts = (usage.windows + usage.extras).map { w in
            "\(w.label) \(Int(w.remainingPercent.rounded()))% left (used \(w.usedPercent)%)"
                + (w.resetsAt.map { ", resets \($0)" } ?? "")
        }
        print("\(name) [\(usage.plan ?? "?")]: " + parts.joined(separator: "; "))
    }
    describe("Claude", ClaudeSource().fetch())
    describe("Codex", CodexSource().fetch())
}

let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--dump-icons") {
    let dir = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "."
    dumpIcons(to: dir)
    exit(0)
}
if arguments.contains("--test-fetch") {
    describeFetch()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
