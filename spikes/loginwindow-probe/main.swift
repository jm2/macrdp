// macrdp-lwprobe: Phase 0 feasibility probe (spikes B1 + B2) for the jm2/macrdp fork.
//
// Fork-only spike code, NOT for upstream. Launched by a /Library/LaunchAgents plist with
// LimitLoadToSessionType=LoginWindow (plus an optional Aqua control instance), it records:
//
//   B1  which uid / security session it runs in, what TCC reports, and which screen
//       capture paths work there: ScreenCaptureKit (shareable content, screenshot,
//       stream), CGDisplayStream, CGDisplayCreateImage, CGWindowListCreateImage and
//       /usr/sbin/screencapture.
//   B2  whether CGEventPost input reaches the login window: an automatic, net-zero
//       "type 7 letters, then 7 backspaces" sequence per event tap (never Return),
//       plus a token-gated loopback command socket for interactive tests (ctl.sh).
//
// Results go to /Users/Shared/macrdp-lwprobe/<run>/ (probe.log, report.json, PNGs).
// Nothing typed is ever logged: `type` logs a length, and AX field values are reported
// as lengths only, so a password typed through the probe never reaches disk.

import ApplicationServices
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import IOSurface
import ImageIO
import ScreenCaptureKit
import Security
import SystemConfiguration
import VideoToolbox

// MARK: - Options

let usage = """
    macrdp-lwprobe [--session NAME] [--out DIR] [--owner-uid UID] [--auto-input | --no-auto-input]
                   [--auto-delay SECS] [--no-listen] [--request] [--lifetime SECS] [--skip m1,m2]
      --session     label for the run directory (loginwindow | aqua | manual)
      --owner-uid   chown results to this uid (when running as root) so the user can read them
      --auto-input  run the net-zero type/erase sequence (default: on only for --session loginwindow)
      --request     ask for Screen Recording + Accessibility (only useful in an Aqua session)
      --skip        steps to skip: sck-content,\(Method.allCases.map(\.rawValue).joined(separator: ","))
    """

func fatal(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("macrdp-lwprobe: \(msg)\n".utf8))
    exit(2)
}

struct Options {
    var session = "manual"
    var outRoot = "/Users/Shared/macrdp-lwprobe"
    var ownerUID: uid_t?
    var autoInput: Bool?
    var autoDelay = 5.0
    var listen = true
    var request = false
    var lifetime = 1800.0
    var skip: Set<String> = []

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func value() -> String {
            i += 1
            guard i < args.count else { fatal("missing value for \(args[i - 1])") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--session":
                o.session = String(value().lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" })
            case "--out": o.outRoot = value()
            case "--owner-uid":
                guard let u = uid_t(value()) else { fatal("--owner-uid needs a number") }
                o.ownerUID = u
            case "--auto-input": o.autoInput = true
            case "--no-auto-input": o.autoInput = false
            case "--auto-delay": o.autoDelay = Double(value()) ?? 5
            case "--no-listen": o.listen = false
            case "--request": o.request = true
            case "--lifetime": o.lifetime = Double(value()) ?? 1800
            case "--skip": o.skip.formUnion(value().split(separator: ",").map(String.init))
            case "-h", "--help":
                print(usage)
                exit(0)
            default: fatal("unknown argument \(args[i])\n\(usage)")
            }
            i += 1
        }
        if o.session.isEmpty { o.session = "manual" }
        return o
    }
}

// MARK: - Small utilities

enum ProbeError: Error, CustomStringConvertible {
    case timeout(Double)
    case msg(String)
    var description: String {
        switch self {
        case .timeout(let s): return "timed out after \(s)s"
        case .msg(let m): return m
        }
    }
}

func describe(_ e: Error) -> String {
    if let p = e as? ProbeError { return p.description }
    let ns = e as NSError
    return "\(ns.domain) code=\(ns.code): \(ns.localizedDescription)"
}

/// Resolves a continuation exactly once across racing callbacks and timers.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class Box<T> { var value: T? }

/// Runs `op` with a deadline. Unlike a task group this returns on timeout even when the
/// operation ignores cancellation (a hung framework call keeps running in the background).
func withTimeout<T>(_ secs: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let once = Once()
        Task.detached {
            do {
                let v = try await op()
                if once.claim() { cont.resume(returning: v) }
            } catch {
                if once.claim() { cont.resume(throwing: error) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
            if once.claim() { cont.resume(throwing: ProbeError.timeout(secs)) }
        }
    }
}

/// Blocks the calling (non-cooperative) thread until an async operation finishes.
func runSync<T>(_ op: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached {
        box.value = await op()
        sem.signal()
    }
    sem.wait()
    return box.value!
}

func ms(since t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

func jsonSafe(_ v: Any) -> Any {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n
    case let d as [String: Any]: return d.mapValues(jsonSafe)
    case let a as [Any]: return a.map(jsonSafe)
    case let d as NSDictionary:
        var out: [String: Any] = [:]
        for (k, val) in d { out[String(describing: k)] = jsonSafe(val) }
        return out
    default: return String(describing: v)
    }
}

func jsonString(_ v: Any) -> String {
    let safe = jsonSafe(v)
    guard JSONSerialization.isValidJSONObject(safe),
        let d = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
        let s = String(data: d, encoding: .utf8)
    else { return String(describing: safe) }
    return s
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "?"
}

func randomHex(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return b.map { String(format: "%02x", $0) }.joined()
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// Gives files to the installing user when we run as root, so they can read results.
enum Owner {
    static var uid: uid_t?
    static var gid: gid_t = 20
    static func configure(_ u: uid_t?) {
        uid = u
        if let u, let pw = getpwuid(u) { gid = pw.pointee.pw_gid }
    }
    static func give(_ path: String) {
        guard let u = uid, geteuid() == 0 else { return }
        _ = lchown(path, u, gid)
    }
}

enum Log {
    private static let lock = NSLock()
    private static var file: FileHandle?
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func open(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
        Owner.give(path)
        file = FileHandle(forWritingAtPath: path)
    }
    static func say(_ s: String) {
        let line = "\(fmt.string(from: Date())) [\(getpid())] \(s)\n"
        let d = Data(line.utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(d)
        file?.write(d)
    }
}

final class Report {
    private let lock = NSLock()
    private var root: [String: Any] = [:]
    let path: String
    init(path: String) { self.path = path }

    func set(_ key: String, _ value: Any) {
        lock.lock()
        root[key] = jsonSafe(value)
        lock.unlock()
        flush()
    }
    func setIn(_ section: String, _ key: String, _ value: Any) {
        lock.lock()
        var s = root[section] as? [String: Any] ?? [:]
        s[key] = jsonSafe(value)
        root[section] = s
        lock.unlock()
        flush()
    }
    func append(_ section: String, _ value: Any) {
        lock.lock()
        var a = root[section] as? [Any] ?? []
        a.append(jsonSafe(value))
        root[section] = a
        lock.unlock()
        flush()
    }
    private func flush() {
        lock.lock()
        let snapshot = root
        lock.unlock()
        guard JSONSerialization.isValidJSONObject(snapshot),
            let d = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
        else {
            Log.say("report: snapshot is not valid JSON; not written")
            return
        }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        Owner.give(path)
    }
}

// MARK: - Environment (B1: who and where are we?)

func selfSigning() -> [String: Any] {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return ["error": "SecCodeCopySelf failed"] }
    var sc: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc else {
        return ["error": "SecCodeCopyStaticCode failed"]
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info)
        == errSecSuccess, let d = info as? [String: Any]
    else { return ["error": "SecCodeCopySigningInformation failed"] }
    var out: [String: Any] = [:]
    out["identifier"] = d[kSecCodeInfoIdentifier as String] as? String ?? "?"
    out["team"] = d[kSecCodeInfoTeamIdentifier as String] as? String ?? "(none)"
    if let u = d[kSecCodeInfoUnique as String] as? Data { out["cdhash"] = u.map { String(format: "%02x", $0) }.joined() }
    if let f = d[kSecCodeInfoFlags as String] as? NSNumber { out["flags"] = String(format: "0x%x", f.uint32Value) }
    out["path"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return out
}

func tccReport() -> [String: Any] {
    [
        "screen_capture_preflight": CGPreflightScreenCaptureAccess(),
        "post_event_preflight": CGPreflightPostEventAccess(),
        "listen_event_preflight": CGPreflightListenEventAccess(),
        "ax_trusted": AXIsProcessTrusted(),
    ]
}

func consoleReport() -> [String: Any] {
    var r: [String: Any] = [:]
    var cuid: uid_t = 0
    var cgid: gid_t = 0
    if let name = SCDynamicStoreCopyConsoleUser(nil, &cuid, &cgid) as String? {
        r["console_user"] = ["name": name, "uid": Int(cuid)]
    } else {
        r["console_user"] = "nil"
    }
    if let d = CGSessionCopyCurrentDictionary() {
        r["cg_session"] = jsonSafe(d as NSDictionary)
    } else {
        r["cg_session"] = "nil (no window server session for this process)"
    }
    return r
}

func displaysReport() -> [String: Any] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    let onlineErr = CGGetOnlineDisplayList(16, &ids, &n)
    var active = [CGDirectDisplayID](repeating: 0, count: 16)
    var na: UInt32 = 0
    CGGetActiveDisplayList(16, &active, &na)
    let activeSet = Set(active.prefix(Int(na)))
    let list: [[String: Any]] = ids.prefix(Int(n)).map { id in
        let b = CGDisplayBounds(id)
        var m: [String: Any] = [
            "id": Int(id),
            "bounds": "\(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height))",
            "main": CGDisplayIsMain(id) != 0,
            "builtin": CGDisplayIsBuiltin(id) != 0,
            "asleep": CGDisplayIsAsleep(id) != 0,
            "active": activeSet.contains(id),
        ]
        if let mode = CGDisplayCopyDisplayMode(id) { m["mode_px"] = "\(mode.pixelWidth)x\(mode.pixelHeight)" }
        return m
    }
    return ["online_err": Int(onlineErr.rawValue), "main": Int(CGMainDisplayID()), "list": list]
}

func environmentReport() -> [String: Any] {
    var r: [String: Any] = [:]
    let pi = ProcessInfo.processInfo
    r["os"] = pi.operatingSystemVersionString
    r["uid"] = Int(getuid())
    r["euid"] = Int(geteuid())
    r["gid"] = Int(getgid())
    if let pw = getpwuid(geteuid()) { r["user"] = String(cString: pw.pointee.pw_name) }
    var env: [String: String] = [:]
    for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "SHELL", "XPC_SERVICE_NAME", "XPC_FLAGS",
        "__CFBundleIdentifier", "SECURITYSESSIONID", "LaunchInstanceID"]
    {
        if let v = pi.environment[k] { env[k] = v }
    }
    r["env"] = env

    var sid: SecuritySessionId = 0
    var attrs = SessionAttributeBits(rawValue: 0)
    let st = SessionGetInfo(SecuritySessionId(UInt32.max), &sid, &attrs)  // callerSecuritySession
    let a = attrs.rawValue
    r["security_session"] = [
        "status": Int(st), "id": Int(sid), "attrs": String(format: "0x%x", a),
        "is_root": a & 0x1 != 0, "graphic_access": a & 0x10 != 0, "tty": a & 0x20 != 0,
        "remote": a & 0x1000 != 0,
    ]
    r["console"] = consoleReport()
    r["tcc"] = tccReport()
    r["displays"] = displaysReport()
    r["code_signing"] = selfSigning()
    return r
}

func windowListReport() -> [String: Any] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return ["error": "CGWindowListCopyWindowInfo returned nil"]
    }
    var owners: [String: Int] = [:]
    var titled = 0
    for w in list {
        let o = w[kCGWindowOwnerName as String] as? String ?? "?"
        owners[o, default: 0] += 1
        // Window titles of other processes are only visible with Screen Recording access.
        if let t = w[kCGWindowName as String] as? String, !t.isEmpty { titled += 1 }
    }
    return ["count": list.count, "with_title": titled, "owners": owners]
}

// MARK: - Images

struct ImageStats {
    let w: Int
    let h: Int
    let meanLuma: Double
    let nonBlack: Double
    let thumb: [UInt8]
    let tw: Int
    let th: Int
}

func analyze(_ img: CGImage) -> ImageStats {
    let tw = 512
    let th = max(1, Int(Double(img.height) * Double(tw) / Double(max(1, img.width))))
    var buf = [UInt8](repeating: 0, count: tw * th * 4)
    buf.withUnsafeMutableBytes { p in
        if let ctx = CGContext(
            data: p.baseAddress, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: tw, height: th))
        }
    }
    var sum = 0.0
    var nb = 0
    for i in stride(from: 0, to: buf.count, by: 4) {
        sum += 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
        if max(buf[i], buf[i + 1], buf[i + 2]) > 16 { nb += 1 }
    }
    let px = Double(tw * th)
    return ImageStats(w: img.width, h: img.height, meanLuma: sum / px, nonBlack: Double(nb) / px, thumb: buf, tw: tw, th: th)
}

/// Thumbnail pixels (512 px wide) whose colour moved by more than a small threshold.
func changedPixels(_ a: ImageStats, _ b: ImageStats) -> Int? {
    guard a.tw == b.tw, a.th == b.th else { return nil }
    var c = 0
    for i in stride(from: 0, to: a.thumb.count, by: 4) {
        let d = max(
            abs(Int(a.thumb[i]) - Int(b.thumb[i])), abs(Int(a.thumb[i + 1]) - Int(b.thumb[i + 1])),
            abs(Int(a.thumb[i + 2]) - Int(b.thumb[i + 2])))
        if d > 12 { c += 1 }
    }
    return c
}

func writePNG(_ img: CGImage, _ path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    let ok = CGImageDestinationFinalize(dest)
    Owner.give(path)
    return ok
}

func imageFromBGRA(base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
    let data = Data(bytes: base, count: bytesPerRow * height)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func imageFromSurface(_ s: IOSurfaceRef) -> CGImage? {
    IOSurfaceLock(s, .readOnly, nil)
    defer { IOSurfaceUnlock(s, .readOnly, nil) }
    return imageFromBGRA(
        base: IOSurfaceGetBaseAddress(s), width: IOSurfaceGetWidth(s), height: IOSurfaceGetHeight(s),
        bytesPerRow: IOSurfaceGetBytesPerRow(s))
}

// MARK: - Capture methods (B1)

enum Method: String, CaseIterable {
    case cgDisplayCreateImage = "cg-display-create-image"
    case cgWindowListCreateImage = "cg-windowlist-create-image"
    case cgDisplayStream = "cg-display-stream"
    case screencaptureCLI = "screencapture-cli"
    case sckScreenshot = "sck-screenshot"
    case sckStream = "sck-stream"
}

/// The pre-ScreenCaptureKit APIs are marked obsolete in the macOS 15+ SDK, so they are
/// looked up at runtime: the SDK refuses to compile direct calls, but the symbols may
/// still exist (and work) in the running OS. A missing symbol is itself a result.
func sym<T>(_ name: String, as _: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
    return unsafeBitCast(p, to: T.self)
}

typealias CGDisplayCreateImageFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
typealias CGWindowListCreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
typealias CGDisplayStreamFrameHandler = @convention(block) (Int32, UInt64, IOSurfaceRef?, OpaquePointer?) -> Void
typealias CGDisplayStreamCreateFn =
    @convention(c) (
        CGDirectDisplayID, Int, Int, Int32, CFDictionary?, UnsafeMutableRawPointer, CGDisplayStreamFrameHandler?
    ) -> OpaquePointer?
typealias CGDisplayStreamCtlFn = @convention(c) (OpaquePointer) -> Int32

func capCGDisplayCreateImage(_ id: CGDirectDisplayID) throws -> CGImage {
    guard let f = sym("CGDisplayCreateImage", as: CGDisplayCreateImageFn.self) else {
        throw ProbeError.msg("symbol CGDisplayCreateImage not found")
    }
    guard let img = f(id)?.takeRetainedValue() else { throw ProbeError.msg("CGDisplayCreateImage returned NULL") }
    return img
}

func capCGWindowList(_ rect: CGRect) throws -> CGImage {
    guard let f = sym("CGWindowListCreateImage", as: CGWindowListCreateImageFn.self) else {
        throw ProbeError.msg("symbol CGWindowListCreateImage not found")
    }
    // kCGWindowListOptionOnScreenOnly = 1, kCGNullWindowID = 0, kCGWindowImageDefault = 0
    guard let img = f(rect, 1, 0, 0)?.takeRetainedValue() else {
        throw ProbeError.msg("CGWindowListCreateImage returned NULL")
    }
    return img
}

/// First complete frame from a CGDisplayStream (the capture path RustDesk-style servers use).
final class DisplayStreamGrab: @unchecked Sendable {
    let once = Once()
    let lock = NSLock()
    var statuses: [Int32: Int] = [:]
    var stream: OpaquePointer?

    func run(_ id: CGDirectDisplayID, w: Int, h: Int) async throws -> CGImage {
        guard let create = sym("CGDisplayStreamCreateWithDispatchQueue", as: CGDisplayStreamCreateFn.self),
            let start = sym("CGDisplayStreamStart", as: CGDisplayStreamCtlFn.self),
            let stop = sym("CGDisplayStreamStop", as: CGDisplayStreamCtlFn.self)
        else { throw ProbeError.msg("CGDisplayStream symbols not found") }
        let q = DispatchQueue(label: "probe.cgdisplaystream")
        let result: Result<CGImage, Error> = await withCheckedContinuation { cont in
            let handler: CGDisplayStreamFrameHandler = { [self] status, _, surface, _ in
                lock.lock()
                statuses[status, default: 0] += 1
                lock.unlock()
                // kCGDisplayStreamFrameStatusFrameComplete = 0, ...Stopped = 3
                if status == 0, let s = surface {
                    if let img = imageFromSurface(s) {
                        if once.claim() { cont.resume(returning: .success(img)) }
                    }
                } else if status == 3 {
                    if once.claim() { cont.resume(returning: .failure(ProbeError.msg("stream stopped before a frame"))) }
                }
            }
            guard
                let s = create(
                    id, w, h, 0x4247_5241 /* 'BGRA' */, nil, Unmanaged.passUnretained(q).toOpaque(), handler)
            else {
                if once.claim() {
                    cont.resume(returning: .failure(ProbeError.msg("CGDisplayStreamCreateWithDispatchQueue returned NULL")))
                }
                return
            }
            stream = s
            let err = start(s)
            if err != 0 {
                if once.claim() { cont.resume(returning: .failure(ProbeError.msg("CGDisplayStreamStart CGError \(err)"))) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [self] in
                lock.lock()
                let seen = statuses
                lock.unlock()
                if once.claim() {
                    cont.resume(returning: .failure(ProbeError.msg("no complete frame in 6s (statuses seen: \(seen))")))
                }
            }
        }
        if let s = stream {
            _ = stop(s)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(s)).release()
            stream = nil
        }
        return try result.get()
    }
}

func capScreencaptureCLI() async throws -> CGImage {
    // Not the run dir: screencapture hands the write to another process, which was
    // refused for a sandboxed scratch dir in testing.
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("macrdp-lwprobe-\(getpid()).png").path
    unlink(path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-C", "-t", "png", path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
    if p.isRunning {
        p.terminate()
        throw ProbeError.timeout(10)
    }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    defer { unlink(path) }
    guard p.terminationStatus == 0 else { throw ProbeError.msg("exit \(p.terminationStatus): \(out)") }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        // Decode now: the image is otherwise read lazily from the file the defer deletes.
        let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw ProbeError.msg("no image written (\(out))") }
    return img
}

func sckContent() async throws -> SCShareableContent {
    try await withTimeout(8) { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
}

func sckDisplay(_ c: SCShareableContent, _ id: CGDirectDisplayID) throws -> SCDisplay {
    guard let d = c.displays.first(where: { $0.displayID == id }) ?? c.displays.first else {
        throw ProbeError.msg("SCShareableContent lists no displays")
    }
    return d
}

func capSCKScreenshot(_ id: CGDirectDisplayID, w: Int, h: Int) async throws -> CGImage {
    let d = try sckDisplay(try await sckContent(), id)
    let filter = SCContentFilter(display: d, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = w
    cfg.height = h
    cfg.showsCursor = true
    return try await withTimeout(8) {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

/// First complete frame from an SCStream: the path macrdp itself uses (via the
/// screencapturekit crate), so this is the result that matters most for B1.
final class FirstFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let once = Once()
    private let cont: CheckedContinuation<Result<CGImage, Error>, Never>
    private let lock = NSLock()
    private var lastStatus = "none"
    init(_ c: CheckedContinuation<Result<CGImage, Error>, Never>) { cont = c }

    var status: String {
        lock.lock()
        defer { lock.unlock() }
        return lastStatus
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let raw = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw)
        {
            lock.lock()
            lastStatus = "\(st.rawValue)"
            lock.unlock()
            guard st == .complete else { return }
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var img: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
        if let img {
            resolve(.success(img))
        } else {
            resolve(.failure(ProbeError.msg("VTCreateCGImageFromCVPixelBuffer failed")))
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { resolve(.failure(error)) }
    func resolve(_ r: Result<CGImage, Error>) { if once.claim() { cont.resume(returning: r) } }
}

func capSCKStream(_ id: CGDirectDisplayID, w: Int, h: Int) async throws -> CGImage {
    let d = try sckDisplay(try await sckContent(), id)
    let filter = SCContentFilter(display: d, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.width = w
    cfg.height = h
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)
    cfg.showsCursor = true
    cfg.queueDepth = 3
    let q = DispatchQueue(label: "probe.sckstream")
    var stream: SCStream?
    var grabber: FirstFrameGrabber?
    let result: Result<CGImage, Error> = await withCheckedContinuation { cont in
        let g = FirstFrameGrabber(cont)
        grabber = g
        let s = SCStream(filter: filter, configuration: cfg, delegate: g)
        stream = s
        do {
            try s.addStreamOutput(g, type: .screen, sampleHandlerQueue: q)
        } catch {
            g.resolve(.failure(error))
            return
        }
        s.startCapture { err in if let err { g.resolve(.failure(err)) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            g.resolve(.failure(ProbeError.msg("no complete frame in 6s (last frame status \(g.status))")))
        }
    }
    if let s = stream { _ = try? await withTimeout(3) { try await s.stopCapture() } }
    _ = grabber
    return try result.get()
}

// MARK: - Input (B2)

let usBase: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
]
let usShifted: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]
let namedKeys: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
    "fwddelete": 117, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
]

func usKey(_ ch: Character) -> (CGKeyCode, Bool)? {
    if let c = usBase[ch] { return (c, false) }
    if ch.isASCII, ch.isUppercase, let lower = ch.lowercased().first, let c = usBase[lower] { return (c, true) }
    if let base = usShifted[ch], let c = usBase[base] { return (c, true) }
    return nil
}

final class Input {
    var tap: CGEventTapLocation = .cghidEventTap  // what macrdp uses
    var sourceState: CGEventSourceStateID? = .combinedSessionState  // what macrdp uses
    var gapMs: UInt32 = 25

    var describe: String {
        let t: String
        switch tap {
        case .cghidEventTap: t = "hid"
        case .cgSessionEventTap: t = "session"
        case .cgAnnotatedSessionEventTap: t = "annotated"
        @unknown default: t = "?"
        }
        let s: String
        switch sourceState {
        case .some(.combinedSessionState): s = "combined"
        case .some(.hidSystemState): s = "hid"
        case .some(.privateState): s = "private"
        case .none: s = "none"
        case .some: s = "?"
        }
        return "tap=\(t) source=\(s) gap=\(gapMs)ms"
    }

    private func src() -> CGEventSource? { sourceState.flatMap { CGEventSource(stateID: $0) } }

    @discardableResult
    func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) -> Bool {
        guard let e = CGEvent(keyboardEventSource: src(), virtualKey: code, keyDown: down) else { return false }
        e.flags = flags
        e.post(tap: tap)
        return true
    }

    @discardableResult
    func shift(_ down: Bool) -> Bool {
        guard let e = CGEvent(keyboardEventSource: src(), virtualKey: 56, keyDown: down) else { return false }
        e.type = .flagsChanged
        e.flags = down ? .maskShift : []
        e.post(tap: tap)
        return true
    }

    @discardableResult
    func press(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard keyEvent(code, down: true, flags: flags) else { return false }
        usleep(8_000)
        return keyEvent(code, down: false, flags: flags)
    }

    /// Per-character keycode events on the US layout (the form upstream found the lock
    /// screen accepts). Resolves every character before posting anything. Errors name a
    /// position, never the character.
    func type(_ text: String) -> String? {
        var plan: [(CGKeyCode, Bool)] = []
        for ch in text {
            guard let k = usKey(ch) else { return "no US keycode for character #\(plan.count + 1)" }
            plan.append(k)
        }
        for (code, shifted) in plan {
            if shifted {
                shift(true)
                usleep(10_000)
            }
            guard press(code, flags: shifted ? .maskShift : []) else { return "CGEvent creation failed" }
            if shifted {
                usleep(5_000)
                shift(false)
            }
            usleep(gapMs * 1000)
        }
        return nil
    }

    /// The bulk Unicode-string form, for comparison (upstream: renders, but the lock
    /// screen field never becomes submittable).
    func unicodeType(_ text: String) {
        for ch in text {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src(), virtualKey: 0, keyDown: down) else { continue }
                u.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: $0.baseAddress) }
                e.post(tap: tap)
            }
            usleep(gapMs * 1000)
        }
    }

    func move(_ p: CGPoint) {
        CGEvent(mouseEventSource: src(), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: tap)
    }

    func click(_ p: CGPoint) {
        for t in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src(), mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: tap)
            usleep(40_000)
        }
    }

    static func cursor() -> CGPoint? { CGEvent(source: nil)?.location }
}

func axReport() -> [String: Any] {
    var r: [String: Any] = ["trusted": AXIsProcessTrusted()]
    func attr(_ el: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return (e, v)
    }
    let sys = AXUIElementCreateSystemWide()
    let (ae, app) = attr(sys, kAXFocusedApplicationAttribute)
    r["focused_app_err"] = Int(ae.rawValue)
    if ae == .success, let app, CFGetTypeID(app) == AXUIElementGetTypeID() {
        var pid: pid_t = 0
        AXUIElementGetPid(app as! AXUIElement, &pid)
        r["focused_app"] = "\(procName(pid)) (pid \(pid))"
    }
    let (ee, el) = attr(sys, kAXFocusedUIElementAttribute)
    r["focused_element_err"] = Int(ee.rawValue)
    if ee == .success, let el, CFGetTypeID(el) == AXUIElementGetTypeID() {
        let e = el as! AXUIElement
        for (k, a) in [
            ("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("role_description", kAXRoleDescriptionAttribute),
            ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
            ("placeholder", kAXPlaceholderValueAttribute),
        ] {
            let (err, v) = attr(e, a)
            if err == .success, let s = v as? String { r[k] = s }
        }
        let (nerr, n) = attr(e, kAXNumberOfCharactersAttribute)
        if nerr == .success, let n = n as? Int { r["num_characters"] = n }
        // Lengths only: this may be a password field.
        let (verr, v) = attr(e, kAXValueAttribute)
        if verr == .success, let s = v as? String { r["value_length"] = s.count } else { r["value_err"] = Int(verr.rawValue) }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        r["element_owner"] = "\(procName(pid)) (pid \(pid))"
    }
    return r
}

// MARK: - Probe

final class Probe {
    let o: Options
    let runDir: String
    let outRoot: String
    let report: Report
    let input = Input()
    private let lock = NSLock()
    private var working: [Method] = []
    private var lastStats: [String: ImageStats] = [:]
    private var token = ""
    private var shotCount = 0

    init(_ o: Options) {
        self.o = o
        Owner.configure(o.ownerUID)
        let fm = FileManager.default
        var root = o.outRoot
        if !fm.fileExists(atPath: root) {
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o1777])
            Owner.give(root)
        }
        if access(root, W_OK) != 0 {
            root = NSTemporaryDirectory() + "macrdp-lwprobe"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        outRoot = root
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(df.string(from: Date()))-\(o.session)-pid\(getpid())"
        runDir = root + "/" + name
        try? fm.createDirectory(atPath: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Owner.give(runDir)
        let link = root + "/latest-\(o.session)"
        unlink(link)
        symlink(name, link)
        Owner.give(link)
        Log.open(runDir + "/probe.log")
        report = Report(path: runDir + "/report.json")
    }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        Log.say("macrdp-lwprobe starting: session=\(o.session) run=\(runDir)")
        report.set("args", CommandLine.arguments)
        report.set("started", ISO8601DateFormatter().string(from: Date()))
        let env = environmentReport()
        report.set("environment", env)
        Log.say("environment: \(jsonString(env))")
        DispatchQueue.global().asyncAfter(deadline: .now() + o.lifetime) {
            Log.say("lifetime of \(Int(self.o.lifetime))s reached; exiting")
            exit(0)
        }
        Task.detached { await self.runAll() }
    }

    private func runAll() async {
        if o.request { requestPermissions() }
        if o.listen { startServer() }
        await captureTests()
        if o.autoInput ?? (o.session == "loginwindow") {
            try? await Task.sleep(nanoseconds: UInt64(o.autoDelay * 1e9))
            await autoInputSequence()
        }
        appendRunsLog()
        Log.say("probe idle (command socket \(o.listen ? "open" : "disabled"))")
    }

    private func requestPermissions() {
        let sc = CGRequestScreenCaptureAccess()
        let pe = CGRequestPostEventAccess()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        Log.say("TCC requests: screen_capture=\(sc) post_event=\(pe) ax_trusted(prompt)=\(ax)")
    }

    private func displayGeometry() -> (CGDirectDisplayID, Int, Int) {
        let id = CGMainDisplayID()
        if let m = CGDisplayCopyDisplayMode(id) { return (id, m.pixelWidth, m.pixelHeight) }
        let b = CGDisplayBounds(id)
        return (id, Int(b.width), Int(b.height))
    }

    private func capture(_ m: Method) async throws -> CGImage {
        let (id, w, h) = displayGeometry()
        switch m {
        case .cgDisplayCreateImage: return try await withTimeout(8) { try capCGDisplayCreateImage(id) }
        case .cgWindowListCreateImage: return try await withTimeout(8) { try capCGWindowList(CGDisplayBounds(id)) }
        case .cgDisplayStream: return try await DisplayStreamGrab().run(id, w: w, h: h)
        case .screencaptureCLI: return try await capScreencaptureCLI()
        case .sckScreenshot: return try await capSCKScreenshot(id, w: w, h: h)
        case .sckStream: return try await capSCKStream(id, w: w, h: h)
        }
    }

    func shot(_ label: String, methods: [Method]) async -> [String: Any] {
        let safeLabel = String(label.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(48))
        var res: [String: Any] = [:]
        for m in methods {
            Log.say("shot \(safeLabel) \(m.rawValue): start")
            let t0 = Date()
            do {
                let img = try await capture(m)
                let st = analyze(img)
                let file = "\(safeLabel)-\(m.rawValue).png"
                let wrote = writePNG(img, runDir + "/" + file)
                var r: [String: Any] = [
                    "ok": true, "ms": ms(since: t0), "size": "\(st.w)x\(st.h)",
                    "mean_luma": (st.meanLuma * 10).rounded() / 10, "nonblack": (st.nonBlack * 1000).rounded() / 1000,
                    "file": wrote ? file : "(png write failed)",
                ]
                let prev: ImageStats? = lock.withLock {
                    let p = lastStats[m.rawValue]
                    lastStats[m.rawValue] = st
                    return p
                }
                if let prev, let c = changedPixels(prev, st) { r["changed_thumb_px_vs_prev"] = c }
                res[m.rawValue] = r
                Log.say(
                    "shot \(safeLabel) \(m.rawValue): OK \(st.w)x\(st.h) luma=\(r["mean_luma"]!) nonblack=\(r["nonblack"]!)"
                        + " changed=\(r["changed_thumb_px_vs_prev"] ?? "-") \(ms(since: t0))ms")
            } catch {
                res[m.rawValue] = ["ok": false, "ms": ms(since: t0), "error": describe(error)]
                Log.say("shot \(safeLabel) \(m.rawValue): FAIL \(describe(error)) (\(ms(since: t0))ms)")
            }
        }
        report.setIn("shots", safeLabel, res)
        return res
    }

    private func methodsForShots() -> [Method] {
        lock.lock()
        defer { lock.unlock() }
        return working.isEmpty ? Method.allCases.filter { !o.skip.contains($0.rawValue) } : working
    }

    private func captureTests() async {
        let wl = windowListReport()
        report.set("window_list", wl)
        Log.say("window list: \(jsonString(wl))")
        if o.skip.contains("sck-content") {
            Log.say("sck content: skipped")
        } else {
            await sckContentReport()
        }
        let methods = Method.allCases.filter { !o.skip.contains($0.rawValue) }
        let res = await shot("initial", methods: methods)
        let ok = methods.filter { (res[$0.rawValue] as? [String: Any])?["ok"] as? Bool == true }
        lock.withLock { working = ok }
        report.set("working_methods", ok.map(\.rawValue))
        Log.say("working capture methods: \(ok.map(\.rawValue))")
    }

    private func sckContentReport() async {
        do {
            let c = try await sckContent()
            let r: [String: Any] = [
                "displays": c.displays.map { "\($0.displayID) \($0.width)x\($0.height)" },
                "windows": c.windows.count, "applications": c.applications.count,
                "bundle_ids": Array(Set(c.applications.map(\.bundleIdentifier))).sorted(),
            ]
            report.set("sck_content", r)
            Log.say("sck content: \(jsonString(r))")
        } catch {
            report.set("sck_content", ["error": describe(error)])
            Log.say("sck content: FAIL \(describe(error))")
        }
    }

    /// Net-zero: types 7 letters and erases exactly 7, per tap, so wherever the events
    /// land the end state is unchanged. Never presses Return.
    private func autoInputSequence() async {
        Log.say("auto-input: begin (\(input.describe))")
        let methods = methodsForShots()
        var steps: [[String: Any]] = []
        func record(_ step: String) async {
            let shots = await shot("auto-\(steps.count)-\(step)", methods: methods)
            let ax = axReport()
            steps.append(["step": step, "ax": ax, "shots": shots])
            report.set("auto_input", steps)
            Log.say("auto-input \(step): ax=\(jsonString(ax))")
        }
        await record("before")
        input.press(56)  // bare Shift: upstream found the lock screen eats the first keystroke as a wake
        try? await Task.sleep(nanoseconds: 400_000_000)
        let marker = "lwprobe"
        for (name, tap) in [("hid", CGEventTapLocation.cghidEventTap), ("session", .cgSessionEventTap)] {
            input.tap = tap
            if let err = input.type(marker) { Log.say("auto-input: type failed: \(err)") }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await record("typed-\(name)")
            for _ in 0..<marker.count {
                input.press(51)
                usleep(input.gapMs * 1000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await record("erased-\(name)")
        }
        input.tap = .cghidEventTap
        let (id, _, _) = displayGeometry()
        let b = CGDisplayBounds(id)
        let before = Input.cursor()
        let target = CGPoint(x: b.midX + 37, y: b.midY + 23)
        input.move(target)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let after = Input.cursor()
        let mouse: [String: Any] = [
            "before": before.map { "\(Int($0.x)),\($0.y)" } ?? "nil", "target": "\(Int(target.x)),\(Int(target.y))",
            "after": after.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil",
        ]
        report.set("auto_mouse", mouse)
        Log.say("auto-input mouse move: \(jsonString(mouse))")
        await record("after-mouse")
        Log.say("auto-input: end")
    }

    private func appendRunsLog() {
        lock.lock()
        let ok = working.map(\.rawValue)
        lock.unlock()
        var cuid: uid_t = 0
        var cgid: gid_t = 0
        let console = (SCDynamicStoreCopyConsoleUser(nil, &cuid, &cgid) as String?) ?? "nil"
        let line =
            "\(ISO8601DateFormatter().string(from: Date())) session=\(o.session) uid=\(getuid()) console=\(console)"
            + " screen_capture=\(CGPreflightScreenCaptureAccess()) ax=\(AXIsProcessTrusted()) working=\(ok)"
            + " run=\(runDir)\n"
        let path = outRoot + "/runs.log"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o666)
        if fd >= 0 {
            _ = line.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            Owner.give(path)  // so a later Aqua run (as the user) can still append
        }
    }

    // MARK: Command socket

    private func startServer() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return Log.say("server: socket() failed errno=\(errno)") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { return Log.say("server: bind/listen failed errno=\(errno)") }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        token = randomHex(16)
        let control: [String: Any] = ["port": port, "token": token, "pid": Int(getpid()), "session": o.session]
        let path = runDir + "/control.json"
        if let d = try? JSONSerialization.data(withJSONObject: control) {
            FileManager.default.createFile(atPath: path, contents: d, attributes: [.posixPermissions: 0o600])
            Owner.give(path)
        }
        Log.say("server: listening on 127.0.0.1:\(port) (token in control.json)")
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 {
                    if errno == EINTR { continue }
                    Log.say("server: accept failed errno=\(errno)")
                    return
                }
                Thread.detachNewThread { self.serve(c) }
            }
        }
    }

    private func serve(_ c: Int32) {
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 900, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let f = fdopen(c, "r") else {
            close(c)
            return
        }
        defer { fclose(f) }
        func send(_ s: String) {
            let out = s.hasSuffix("\n") ? s : s + "\n"
            _ = out.withCString { write(c, $0, strlen($0)) }
        }
        func line() -> String? {
            var p: UnsafeMutablePointer<CChar>?
            var cap = 0
            let n = getline(&p, &cap, f)
            defer { free(p) }
            guard n > 0, let p else { return nil }
            return String(cString: p).trimmingCharacters(in: .newlines)
        }
        guard let t = line(), constantTimeEqual(t, token) else {
            send("ERR bad token")
            Log.say("server: rejected a client with a bad token")
            return
        }
        send("OK macrdp-lwprobe session=\(o.session) pid=\(getpid()) (\(input.describe)); 'help' lists commands")
        while let l = line() {
            if l.isEmpty { continue }
            let (reply, done) = execute(l)
            send(reply)
            send(done ? "BYE" : "END")
            if done { break }
        }
    }

    private let help = """
        help                     this text
        env | console | tcc      environment / console user + CGSession / TCC preflight
        displays | windows       display list / on-screen window list summary
        shot [label] [m1,m2]     capture (default: methods that worked at startup); 'shot x all' = every method
        ax                       focused app + element (values reported as lengths only)
        type <text>              per-character US keycode events (logged as a length only)
        utype <text>             Unicode-string events, for comparison
        key <name> [count]       \(namedKeys.keys.sorted().joined(separator: " "))
        wake                     bare Shift tap
        move <x> <y> | click <x> <y>   global coordinates (points); 'cursor' prints the position
        tap hid|session|annotated      event tap location (default hid)
        source combined|hid|private|none   event source state (default combined)
        gap <ms>                 delay between typed characters (default 25)
        sleep <ms>
        bye | shutdown           close this connection / exit the probe
        """

    private func execute(_ l: String) -> (String, Bool) {
        let parts = l.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts.first.map { $0.lowercased() } ?? ""
        let rest = parts.count > 1 ? String(parts[1]) : ""
        let args = rest.split(separator: " ").map(String.init)
        let secret = verb == "type" || verb == "utype"
        Log.say("cmd \(verb)" + (secret ? " (\(rest.count) chars)" : (rest.isEmpty ? "" : " \(rest)")))
        switch verb {
        case "help": return (help, false)
        case "bye", "quit", "exit": return ("OK", true)
        case "shutdown":
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return ("OK exiting", true)
        case "env":
            let e = environmentReport()
            report.append("environment_snapshots", e)
            return (jsonString(e), false)
        case "console": return (jsonString(consoleReport()), false)
        case "tcc": return (jsonString(tccReport()), false)
        case "displays": return (jsonString(displaysReport()), false)
        case "windows": return (jsonString(windowListReport()), false)
        case "ax":
            let a = axReport()
            report.append("ax_snapshots", a)
            return (jsonString(a), false)
        case "shot":
            lock.lock()
            shotCount += 1
            let n = shotCount
            lock.unlock()
            let label = args.first ?? "shot\(n)"
            var methods = methodsForShots()
            if args.count > 1 {
                methods = args[1] == "all" ? Method.allCases : args[1].split(separator: ",").compactMap { Method(rawValue: String($0)) }
            }
            let ms = methods
            return (jsonString(runSync { await self.shot(label, methods: ms) }), false)
        case "type":
            if let err = input.type(rest) { return ("ERR \(err)", false) }
            return ("OK typed \(rest.count) chars (\(input.describe))", false)
        case "utype":
            input.unicodeType(rest)
            return ("OK posted \(rest.count) Unicode chars (\(input.describe))", false)
        case "key":
            guard let name = args.first?.lowercased(), let code = namedKeys[name] else { return ("ERR unknown key", false) }
            let count = max(1, min(64, Int(args.count > 1 ? args[1] : "1") ?? 1))
            for _ in 0..<count {
                input.press(code)
                usleep(input.gapMs * 1000)
            }
            return ("OK \(name) x\(count) (\(input.describe))", false)
        case "wake":
            input.press(56)
            return ("OK shift tap", false)
        case "move", "click":
            guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else { return ("ERR need <x> <y>", false) }
            let p = CGPoint(x: x, y: y)
            if verb == "move" { input.move(p) } else { input.click(p) }
            usleep(150_000)
            let now = Input.cursor().map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil"
            return ("OK \(verb) \(Int(x)),\(Int(y)); cursor now \(now)", false)
        case "cursor":
            return (Input.cursor().map { "OK \(Int($0.x)),\(Int($0.y))" } ?? "ERR no cursor", false)
        case "tap":
            switch args.first {
            case "hid": input.tap = .cghidEventTap
            case "session": input.tap = .cgSessionEventTap
            case "annotated": input.tap = .cgAnnotatedSessionEventTap
            default: return ("ERR tap hid|session|annotated", false)
            }
            return ("OK \(input.describe)", false)
        case "source":
            switch args.first {
            case "combined": input.sourceState = .combinedSessionState
            case "hid": input.sourceState = .hidSystemState
            case "private": input.sourceState = .privateState
            case "none": input.sourceState = nil
            default: return ("ERR source combined|hid|private|none", false)
            }
            return ("OK \(input.describe)", false)
        case "gap":
            guard let g = UInt32(args.first ?? ""), g <= 1000 else { return ("ERR gap <0-1000>", false) }
            input.gapMs = g
            return ("OK \(input.describe)", false)
        case "sleep":
            let t = min(30_000, Int(args.first ?? "0") ?? 0)
            usleep(UInt32(t) * 1000)
            return ("OK slept \(t)ms", false)
        default:
            return ("ERR unknown command '\(verb)' (try help)", false)
        }
    }
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)
let probe = Probe(Options.parse(CommandLine.arguments))
probe.start()
dispatchMain()
