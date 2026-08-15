import AppKit
import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Model

struct UsageWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

struct ServiceUsage {
    var plan: String?
    var account: String?  // who this data belongs to, read from the live token
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
              formBody: [String: String]? = nil,
              timeout: TimeInterval = 25) throws -> [String: Any] {
    guard let url = URL(string: urlString) else { throw FetchError.parse("bad URL") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let body = jsonBody {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    } else if let formBody {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = formBody.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
        usage.account = accountEmail(token: token)  // best-effort; never blocks usage
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

    // Identity of the account this token belongs to, so the menu names whose
    // limits it is showing. Same token as the usage call, so the two can't drift.
    private func accountEmail(token: String) -> String? {
        guard let json = try? httpJSON("https://api.anthropic.com/api/oauth/profile", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": Self.userAgent,
        ]), let account = json["account"] as? [String: Any] else { return nil }
        return (account["email"] as? String) ?? (account["display_name"] as? String)
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
        usage.account = jwtEmail(token)  // decoded from the same access token
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

    // The account email is carried inside the access-token JWT, so the menu can
    // name whose limits it shows without any extra request.
    private func jwtEmail(_ jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = object["https://api.openai.com/profile"] as? [String: Any] else { return nil }
        return profile["email"] as? String
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

// MARK: - Grok (token in ~/.grok/auth.json, same storage the xAI Grok CLI uses)

struct GrokSource {
    static let authPath = NSHomeDirectory() + "/.grok/auth.json"
    static let tokenURL = "https://auth.x.ai/oauth2/token"
    static let usageURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let userAgent = "grok-cli"
    // auth.json is a map keyed by "<issuer>::<client_id>"; the xAI provider entry
    // holds { key: <JWT access>, refresh_token, oidc_client_id, email, ... }.
    // Same freshest-chain-plus-ancestor guard as the other sources so a failed
    // write-back after a rotation can't strand the CLI's only valid refresh token.
    static var memoryAuth: [String: Any]?
    static var memoryAncestor: String?
    static let memoryLock = NSLock()

    func fetch() -> ServiceUsage {
        do {
            var (auth, ancestor) = try readAuth()
            var entry = try providerEntry(auth).entry
            if jwtExpiry(entry["key"] as? String) < Date().timeIntervalSince1970 + 60 {
                (auth, ancestor) = try refresh(auth, ancestorToken: ancestor)
                entry = try providerEntry(auth).entry
            }
            guard let token = entry["key"] as? String else {
                throw FetchError.notLoggedIn("No access token — run `grok login`")
            }
            do {
                return try usage(token: token, entry: entry)
            } catch FetchError.http(401, _) {
                (auth, _) = try refresh(auth, ancestorToken: ancestor)
                entry = try providerEntry(auth).entry
                guard let retry = entry["key"] as? String else {
                    throw FetchError.notLoggedIn("No access token after refresh")
                }
                return try usage(token: retry, entry: entry)
            }
        } catch {
            var usage = ServiceUsage()
            usage.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return usage
        }
    }

    private func usage(token: String, entry: [String: Any]) throws -> ServiceUsage {
        let json = try httpJSON(Self.usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "x-grok-client-mode": "cli",
            "User-Agent": Self.userAgent,
        ])
        guard let config = json["config"] as? [String: Any] else {
            throw FetchError.parse("no billing config in response")
        }
        var usage = ServiceUsage()
        usage.account = entry["email"] as? String
        let reset = parseISO((config["currentPeriod"] as? [String: Any])?["end"])
        if let used = (config["creditUsagePercent"] as? NSNumber)?.doubleValue {
            usage.windows.append(UsageWindow(label: "Weekly", usedPercent: used, resetsAt: reset))
        }
        for product in (config["productUsage"] as? [[String: Any]]) ?? [] {
            guard let used = (product["usagePercent"] as? NSNumber)?.doubleValue else { continue }
            let raw = (product["product"] as? String) ?? "Usage"
            let label = raw.hasPrefix("Grok") ? String(raw.dropFirst(4)) : raw
            usage.extras.append(UsageWindow(label: label, usedPercent: used, resetsAt: reset))
        }
        guard !usage.windows.isEmpty else { throw FetchError.parse("no usage windows in response") }
        return usage
    }

    // The xAI provider entry within the auth map, plus its map key.
    private func providerEntry(_ auth: [String: Any]) throws -> (key: String, entry: [String: Any]) {
        let match = auth.first { key, value in
            key.hasPrefix("https://auth.x.ai") && (value as? [String: Any])?["refresh_token"] != nil
        } ?? auth.first { _, value in
            (value as? [String: Any])?["refresh_token"] != nil
        }
        guard let match, let entry = match.value as? [String: Any] else {
            throw FetchError.notLoggedIn("No Grok login in auth.json — run `grok login`")
        }
        return (match.key, entry)
    }

    private func providerRefreshToken(_ auth: [String: Any]?) -> String? {
        guard let auth, let entry = try? providerEntry(auth).entry else { return nil }
        return entry["refresh_token"] as? String
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

    private func readAuth() throws -> (auth: [String: Any], ancestor: String) {
        var storeAbsent = false
        let store: [String: Any]?
        do {
            store = try readStore()
        } catch FetchError.notLoggedIn {
            store = nil
            storeAbsent = true
        } catch {
            store = nil
        }
        let storeToken = providerRefreshToken(store)
        Self.memoryLock.lock()
        let cached = Self.memoryAuth
        let cachedAncestor = Self.memoryAncestor
        Self.memoryLock.unlock()
        if let cached, let cachedAncestor {
            if storeAbsent {
                clearMemory()
            } else if store == nil {
                return (cached, cachedAncestor)  // transiently unreadable: memory carries the chain
            } else if let storeToken, storeToken == cachedAncestor {
                if persist(cached, consumedRefreshToken: cachedAncestor, ancestorToken: cachedAncestor),
                   let own = providerRefreshToken(cached) {
                    return (cached, own)
                }
                return (cached, cachedAncestor)
            } else {
                clearMemory()  // store moved past us (new login / CLI rotation): adopt it
            }
        }
        guard let store else {
            throw FetchError.notLoggedIn("~/.grok/auth.json not found — run `grok login`")
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
            throw FetchError.notLoggedIn("~/.grok/auth.json not found — run `grok login`")
        }
        guard let data = FileManager.default.contents(atPath: Self.authPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parse("Grok auth.json unreadable")
        }
        return object
    }

    private func refresh(_ auth: [String: Any], ancestorToken: String)
        throws -> (auth: [String: Any], ancestor: String) {
        let (providerKey, entry) = try providerEntry(auth)
        guard let refreshToken = entry["refresh_token"] as? String,
              let clientID = entry["oidc_client_id"] as? String else {
            throw FetchError.notLoggedIn("No refresh token — run `grok login`")
        }
        let json = try httpJSON(Self.tokenURL, method: "POST",
            headers: ["User-Agent": Self.userAgent],
            formBody: ["grant_type": "refresh_token",
                       "refresh_token": refreshToken,
                       "client_id": clientID])
        guard let accessToken = json["access_token"] as? String else {
            throw FetchError.parse("Grok token refresh missing access_token")
        }
        var newEntry = entry
        newEntry["key"] = accessToken
        if let newRefresh = json["refresh_token"] as? String { newEntry["refresh_token"] = newRefresh }
        if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            newEntry["expires_at"] = formatter.string(from: Date().addingTimeInterval(expiresIn))
        }
        var newAuth = auth
        newAuth[providerKey] = newEntry
        Self.memoryLock.lock()
        Self.memoryAuth = newAuth
        Self.memoryAncestor = ancestorToken
        Self.memoryLock.unlock()
        if persist(newAuth, consumedRefreshToken: refreshToken, ancestorToken: ancestorToken),
           let own = newEntry["refresh_token"] as? String {
            return (newAuth, own)
        }
        return (newAuth, ancestorToken)
    }

    // Write back so the Grok CLI and this app share one valid token chain. Only
    // replace a store that still holds our chain's past (the token we consumed or
    // the ancestor); anything else is a foreign login and must not be clobbered.
    @discardableResult
    private func persist(_ newAuth: [String: Any], consumedRefreshToken: String, ancestorToken: String) -> Bool {
        guard let current = try? readStore(),
              let (providerKey, currentEntry) = try? providerEntry(current),
              let storeToken = currentEntry["refresh_token"] as? String else {
            NSLog("LimitBar: grok auth.json not in a known state during write-back; keeping refreshed token in memory")
            return false
        }
        guard storeToken == consumedRefreshToken || storeToken == ancestorToken else {
            clearMemory()  // foreign chain: the store is the newer truth
            return false
        }
        guard let newEntry = newAuth[providerKey] as? [String: Any] else { return false }
        // Splice only the token fields so anything else the CLI wrote survives.
        var mergedEntry = currentEntry
        for key in ["key", "refresh_token", "expires_at"] { mergedEntry[key] = newEntry[key] }
        var merged = current
        merged[providerKey] = mergedEntry
        do {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: Self.authPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.authPath)
            clearMemory()
            return true
        } catch {
            NSLog("LimitBar: grok auth.json write-back failed (%@); keeping refreshed token in memory", "\(error)")
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

    static func grok() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 16)
            transform.concat()
            NSColor.black.setStroke()
            // Grok: an angular blade — a long diagonal slash with a shorter parallel accent.
            let strokes: [(NSPoint, NSPoint)] = [
                (NSPoint(x: 4.2, y: 2.6), NSPoint(x: 12.0, y: 12.4)),
                (NSPoint(x: 4.2, y: 7.4), NSPoint(x: 8.1, y: 12.4)),
            ]
            for (a, b) in strokes {
                let path = NSBezierPath()
                path.lineWidth = 2.1
                path.lineCapStyle = .round
                path.move(to: a)
                path.line(to: b)
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Services & preferences

enum Service: String, CaseIterable, Identifiable {
    case claude, codex, grok
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }
    var icon: NSImage {
        switch self {
        case .claude: return Icons.claude()
        case .codex: return Icons.openAI()
        case .grok: return Icons.grok()
        }
    }
    func fetch() -> ServiceUsage {
        switch self {
        case .claude: return ClaudeSource().fetch()
        case .codex: return CodexSource().fetch()
        case .grok: return GrokSource().fetch()
        }
    }
    var accent: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.46, blue: 0.32)
        case .codex: return Color(red: 0.10, green: 0.66, blue: 0.52)
        case .grok: return Color(red: 0.40, green: 0.52, blue: 0.96)
        }
    }
    private var defaultsKey: String { "service.\(rawValue).enabled" }
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

final class LimitStore: ObservableObject {
    @Published var usage: [Service: ServiceUsage] = [:]
    @Published var enabled: [Service: Bool] = [:]
    @Published var lastUpdated: Date?
    @Published var isFetching = false
    @Published var launchAtLogin = false

    var onRefresh: () -> Void = {}
    var onSetEnabled: (Service, Bool) -> Void = { _, _ in }
    var onSetLaunch: (Bool) -> Void = { _ in }
    var onQuit: () -> Void = {}
}

private func clockString(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
    return f.string(from: date)
}

// MARK: - Liquid Glass helpers

@available(macOS 26.0, *)
private func regularGlass(tint: Color?) -> Glass {
    guard let tint else { return .regular }
    return Glass.regular.tint(tint.opacity(0.16))
}

extension View {
    // Native Liquid Glass on macOS 26+, with a material fallback on older systems.
    @ViewBuilder
    func glassPanel(_ radius: CGFloat, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(regularGlass(tint: tint),
                             in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Popover UI

struct PopoverView: View {
    @ObservedObject var store: LimitStore

    private var visible: [Service] { Service.allCases.filter { store.enabled[$0] == true } }
    private var enabledCount: Int { visible.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            servicesSection
            Divider().opacity(0.35)
            visibilityRow
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("LimitBar").font(.system(size: 15, weight: .bold))
            Spacer()
            if store.isFetching {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else if let updated = store.lastUpdated {
                Text("updated \(clockString(updated))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { store.onRefresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
    }

    @ViewBuilder private func serviceCards() -> some View {
        VStack(spacing: 12) {
            ForEach(visible) { service in
                ServiceCardView(service: service, usage: store.usage[service])
            }
        }
    }

    @ViewBuilder private var servicesSection: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { serviceCards() }
        } else {
            serviceCards()
        }
    }

    private var visibilityRow: some View {
        HStack(spacing: 7) {
            Text("Show").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            ForEach(Service.allCases) { service in
                let on = store.enabled[service] == true
                let lockLast = on && enabledCount <= 1
                Button { store.onSetEnabled(service, !on) } label: {
                    Text(service.title).font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(ChipStyle(on: on, accent: service.accent))
                .disabled(lockLast)
                .help(lockLast ? "At least one service must stay visible"
                               : (on ? "Hide \(service.title)" : "Show \(service.title)"))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Toggle(isOn: Binding(get: { store.launchAtLogin },
                                 set: { store.onSetLaunch($0) })) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.small)
            Button { store.onQuit() } label: {
                Text("Quit LimitBar").font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }
}

struct ServiceCardView: View {
    let service: Service
    let usage: ServiceUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: service.icon)
                    .renderingMode(.template)
                    .resizable().frame(width: 16, height: 16)
                    .foregroundStyle(service.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.title).font(.system(size: 14, weight: .semibold))
                    if let account = usage?.account, !account.isEmpty {
                        Text(account).font(.system(size: 10.5))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let plan = usage?.plan, !plan.isEmpty {
                    Text(plan).font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(service.accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(service.accent)
                }
            }
            cardBody
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(18, tint: service.accent)
    }

    @ViewBuilder private var cardBody: some View {
        if let usage, let error = usage.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(.orange)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        } else if let usage, !usage.windows.isEmpty {
            VStack(spacing: 9) {
                ForEach(Array((usage.windows + usage.extras).enumerated()), id: \.offset) { _, window in
                    UsageBarView(window: window, accent: service.accent)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct UsageBarView: View {
    let window: UsageWindow
    let accent: Color

    private var remaining: Double { window.remainingPercent }
    private var barColor: Color {
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.label).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(remaining.rounded()))% left")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(barColor.gradient)
                        .frame(width: max(3, geo.size.width * remaining / 100))
                }
            }
            .frame(height: 6)
            if let reset = window.resetsAt {
                Text("resets \(clockString(reset))")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ChipStyle: ButtonStyle {
    let on: Bool
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(Color.secondary))
            .background {
                if on {
                    Capsule().fill(accent.gradient)
                } else {
                    Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LimitStore()
    private var statusItems: [Service: NSStatusItem] = [:]
    private let popover = NSPopover()
    private var fetching: Set<Service> = []
    private var lastUpdated: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        for service in Service.allCases { store.enabled[service] = service.isEnabled }
        store.launchAtLogin = launchEnabled()
        store.onRefresh = { [weak self] in self?.refresh() }
        store.onSetEnabled = { [weak self] service, on in self?.setEnabled(service, on) }
        store.onSetLaunch = { [weak self] on in self?.setLaunch(on) }
        store.onQuit = { NSApp.terminate(nil) }

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        syncStatusItems()
        refresh()
        // .common so the timer keeps firing while the popover is open.
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

    // One menu-bar item per enabled service, rebuilt so the left-to-right order
    // stays Claude · Codex · Grok no matter what order the toggles were flipped.
    private func syncStatusItems() {
        for (_, item) in statusItems { NSStatusBar.system.removeStatusItem(item) }
        statusItems.removeAll()
        for service in Service.allCases.reversed() where store.enabled[service] == true {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = service.icon
                button.imagePosition = .imageLeft
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.title = " …"
                button.target = self
                button.action = #selector(statusItemClicked(_:))
            }
            statusItems[service] = item
        }
        updateButtons()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender); return }
        if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { refresh() }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    // Each enabled service fetches and publishes independently, so one wedged or
    // slow source can never freeze the others or block future refreshes.
    @objc func refresh() {
        for service in Service.allCases where store.enabled[service] == true {
            guard !fetching.contains(service) else { continue }
            fetching.insert(service)
            store.isFetching = true
            DispatchQueue.global().async {
                let result = service.fetch()
                DispatchQueue.main.async {
                    self.store.usage[service] = result
                    self.fetching.remove(service)
                    self.lastUpdated = Date()
                    self.store.lastUpdated = self.lastUpdated
                    self.store.isFetching = !self.fetching.isEmpty
                    self.updateButton(service)
                }
            }
        }
    }

    private func updateButtons() { for service in Service.allCases { updateButton(service) } }

    private func updateButton(_ service: Service) {
        guard let button = statusItems[service]?.button else { return }
        let usage = store.usage[service] ?? ServiceUsage()
        guard usage.error == nil, let binding = usage.binding else {
            button.title = usage.error == nil ? " …" : " –"
            button.toolTip = "\(service.title): \(usage.error ?? "loading…")"
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
        let who = usage.account.map { " (\($0))" } ?? ""
        button.toolTip = service.title + who + " — " + usage.windows
            .map { "\($0.label): \(Int($0.remainingPercent.rounded()))% left" }
            .joined(separator: " · ")
    }

    // MARK: Preferences

    private func setEnabled(_ service: Service, _ on: Bool) {
        let count = Service.allCases.filter { store.enabled[$0] == true }.count
        if !on && count <= 1 {
            store.enabled[service] = true  // keep one item so the popover stays reachable
            return
        }
        service.isEnabled = on
        store.enabled[service] = on
        syncStatusItems()
        if on { refresh() }
    }

    private func launchEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLaunch(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch-at-login toggle failed: \(error)")
        }
        store.launchAtLogin = launchEnabled()
    }
}

// MARK: - CLI modes for headless testing

func dumpIcons(to dir: String) {
    for (name, image) in [("claude", Icons.claude()), ("openai", Icons.openAI()), ("grok", Icons.grok())] {
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
        print("\(name) [\(usage.plan ?? "?")] <\(usage.account ?? "unknown account")>: " + parts.joined(separator: "; "))
    }
    describe("Claude", ClaudeSource().fetch())
    describe("Codex", CodexSource().fetch())
    describe("Grok", GrokSource().fetch())
}

// Render the popover to a PNG over a backdrop so the layout can be eyeballed
// without opening the menu bar. Real Liquid Glass only composites live on screen;
// here the translucent panels rasterize flat, but text/bars/spacing are faithful.
@MainActor
func renderPopover(to path: String) {
    _ = NSApplication.shared
    let store = LimitStore()
    for service in Service.allCases { store.enabled[service] = true }
    store.usage[.claude] = ClaudeSource().fetch()
    store.usage[.codex] = CodexSource().fetch()
    store.usage[.grok] = GrokSource().fetch()
    store.lastUpdated = Date()
    let root = PopoverView(store: store)
        .padding(22)
        .background(LinearGradient(
            colors: [Color(red: 0.17, green: 0.18, blue: 0.24), Color(red: 0.07, green: 0.08, blue: 0.11)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
        .frame(width: 364)
    let renderer = ImageRenderer(content: root)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("\(path) (\(Int(image.size.width))×\(Int(image.size.height)))")
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
if let flagIndex = arguments.firstIndex(of: "--render-popover") {
    let path = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "popover.png"
    let renderApp = NSApplication.shared
    renderApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        renderPopover(to: path)
        exit(0)
    }
    renderApp.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
