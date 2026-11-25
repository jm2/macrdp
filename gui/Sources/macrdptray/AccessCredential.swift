import AppKit

// Access-credential mode (config AUTH_MODE=access-credential, server side in
// src/access_credential.rs): RDP clients sign in with a random secret macrdp
// generates, and the controller never asks for, checks or stores the Mac
// account password. The secret lives in the login Keychain (service
// "macrdp-access", account = the RDP username). Only the server binary writes
// it (`macrdp credential rotate`, which hands it to /usr/bin/security on stdin),
// so it never appears on a command line, and the controller only shows it once.

enum AccessCredential {
    /// Keychain service of the access-credential item. Keep in step with
    /// `KEYCHAIN_SERVICE` in src/access_credential.rs.
    static let keychainService = "macrdp-access"
    /// config.env value of AUTH_MODE that selects this mode.
    static let modeValue = "access-credential"

    static func isSelected(_ config: [String: String]) -> Bool {
        config["AUTH_MODE"] == modeValue
    }
}

extension AppController {
    /// Whether config.env selects access-credential mode.
    var usesAccessCredential: Bool { AccessCredential.isSelected(readConfig()) }

    /// The RDP username, as the server resolves it: USERNAME, else this account.
    var rdpUsername: String {
        let u = readConfig()["USERNAME"] ?? ""
        return u.isEmpty ? NSUserName() : u
    }

    func hasAccessCredential() -> Bool {
        run("/usr/bin/security",
            ["find-generic-password", "-s", AccessCredential.keychainService, "-a", rdpUsername]).code == 0
    }

    /// Generate a new access credential with the server binary and show it once.
    /// A running server switches to it within seconds. Returns false if it
    /// couldn't be created.
    @discardableResult
    func rotateAccessCredential() -> Bool {
        guard let serverApp = locateServerApp() else {
            alert(style: .warning, "Can't find macrdp.app",
                  "Move macrdp.app into /Applications (or next to the controller), then try again.")
            return false
        }
        ensureConfigExists()
        let bin = serverApp.appendingPathComponent("Contents/MacOS/macrdp").path
        let r = runCapturingStdout(bin, ["--config", configURL.path, "credential", "rotate"])
        let secret = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.code == 0, !secret.isEmpty, !secret.contains("\n") else {
            alert(style: .critical, "Couldn't create an access credential",
                  r.stderr.isEmpty ? "macrdp returned an error." : r.stderr)
            return false
        }
        showAccessCredentialOnce(secret)
        return true
    }

    /// The server is waiting for an access credential: create one, then restart
    /// the server so it starts at once instead of at its next 30 s check.
    @objc func fixAccessCredential() {
        guard rotateAccessCredential() else { return }
        _ = run("/bin/launchctl", ["kickstart", "-k", service])
        refreshGlyph()
    }

    @objc func rotateAccessCredentialAction() { rotateAccessCredential() }

    private func showAccessCredentialOnce(_ secret: String) {
        let a = NSAlert()
        a.messageText = "New RDP access credential"
        a.informativeText = """
            In your RDP client, sign in as “\(rdpUsername)” with this password. It's shown \
            only now: macrdp keeps it in your login Keychain but won't show it again, so \
            create a new one if you lose it. A running server switches to it within a few \
            seconds, and the previous one stops working.

            This isn't your Mac password, which macrdp never stores. When the Mac is locked, \
            unlock it at the lock screen from your RDP client.
            """
        let field = NSTextField(labelWithString: secret)
        field.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Copy and Close")
        a.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            copyConcealed(secret)
        }
    }

    /// Copy without Universal Clipboard (this Mac only) and with the
    /// nspasteboard.org concealed marker that clipboard managers skip.
    private func copyConcealed(_ s: String) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(s, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    /// Like `run`, but keeps stdout (the secret) apart from stderr (messages).
    func runCapturingStdout(_ path: String, _ args: [String]) -> (code: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}
