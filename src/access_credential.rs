//! Access-credential mode (`--auth access-credential`, config
//! `AUTH_MODE=access-credential`): RDP clients authenticate with a random
//! secret that macrdp generates, never with the Mac account password.
//!
//! In the default `account` mode the Mac password is checked with PAM at
//! startup and becomes the credential NLA compares, so macrdp has to store it
//! (Keychain or password file) and can type it into the lock screen
//! (`--auto-unlock`). In this mode macrdp never asks for, stores or checks the
//! Mac password. NLA gates the network with the access credential, and the
//! remote user authenticates to macOS only through Apple's own lock screen.
//! Leaking the access credential gives an attacker the lock screen, not the
//! account. (A session left unlocked is reachable with the access credential
//! alone, exactly as it is with the account password in `account` mode, which
//! is why `--lock-on-disconnect` is the recommended pairing.)
//!
//! The credential lives in the login Keychain as a generic password, service
//! [`KEYCHAIN_SERVICE`], account = the RDP username. It is separate from the
//! account-password item (service `macrdp`). Both ends go through
//! `/usr/bin/security`, as the account-password path does
//! (docs/macos-gotchas.md): the item's trusted application is then
//! `/usr/bin/security`, so the headless LaunchAgent reads it with no prompt.
//! Writing goes through `security -i` on stdin, so the secret is never on a
//! command line where `ps` could show it.
//!
//! Rotation takes effect without a restart. After storing a new secret,
//! `macrdp credential rotate` rewrites a stamp file ([`CHANGE_STAMP`]) in the
//! config directory; the running server checks it every [`STAMP_POLL`] and,
//! when it changes, re-reads the item and passes it to IronRDP. The Keychain is
//! read only then (and at startup), never on a timer: a login keychain set to
//! lock itself would raise an unlock prompt on every read. A change made
//! another way (Keychain Access, `security`) applies at the next start. A validator
//! compares every client's password with the *current* secret, because IronRDP
//! checks a client that tries to take over a live session against the
//! credentials captured when that session began; without the validator the old
//! secret could still evict a session after a rotation. A live session is not
//! ended by a rotation.

use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use ironrdp_server::{
    CredentialDecision, CredentialValidationError, CredentialValidator, Credentials,
};
use tracing::{error, info, warn};
use zeroize::Zeroizing;

use crate::auth_status;

/// Keychain service of the access-credential item (account = RDP username).
pub const KEYCHAIN_SERVICE: &str = "macrdp-access";

/// File in the config directory that `macrdp credential rotate` rewrites after
/// storing a new secret. Its content (a timestamp) isn't secret.
pub const CHANGE_STAMP: &str = "access-credential-changed";

/// How often a running server checks [`CHANGE_STAMP`].
pub const STAMP_POLL: Duration = Duration::from_secs(2);

/// Lower-case Crockford base32: no `i`, `l`, `o` or `u`, so a secret read off a
/// screen and typed by hand has no look-alike characters.
const SECRET_ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
/// Characters in a secret, 5 bits each: 140 bits of entropy.
const SECRET_CHARS: usize = 28;
/// Random bytes drawn per secret (144 bits, of which 140 are used).
const SECRET_RANDOM_BYTES: usize = 18;
const _: () = assert!(
    SECRET_CHARS * 5 >= 128,
    "the plan requires at least 128 bits"
);
const _: () = assert!(SECRET_RANDOM_BYTES * 8 >= SECRET_CHARS * 5);

/// How RDP clients authenticate (`--auth`, config `AUTH_MODE`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, clap::ValueEnum)]
pub enum AuthMode {
    /// The Mac account password, checked with PAM at startup (the default).
    #[default]
    Account,
    /// A random access credential from `macrdp credential rotate`; the Mac
    /// password is never asked for, stored or checked.
    AccessCredential,
}

impl AuthMode {
    pub fn as_str(self) -> &'static str {
        match self {
            AuthMode::Account => "account",
            AuthMode::AccessCredential => "access-credential",
        }
    }
}

/// `macrdp credential …`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::Subcommand)]
pub enum CredentialCommand {
    /// Generate a new access credential, store it in the login Keychain and
    /// print it once on stdout. A running server switches to it within seconds.
    Rotate,
    /// Print the RDP username the access credential belongs to.
    ShowUsername,
    /// Show the configured auth mode and whether an access credential exists.
    Status,
}

/// Settings that can't be combined with access-credential mode, as the error
/// to stop on. `--keychain` is allowed (and ignored): the access credential is
/// always read from the Keychain, and `config.env` turns it on by default.
pub fn conflicting_setting(
    password: bool,
    password_file: bool,
    skip_auth: bool,
    auto_unlock: bool,
) -> Option<&'static str> {
    if auto_unlock {
        return Some(
            "--auto-unlock (AUTO_UNLOCK=1) types the Mac account password into the lock \
             screen, and access-credential mode never stores that password. Unlock at the \
             real lock screen from your RDP client instead, and remove --auto-unlock",
        );
    }
    if password || password_file {
        return Some(
            "--password / --password-file (PASSWORD_FILE) supply the Mac account password, \
             which access-credential mode never uses; remove them. The access credential \
             comes from the Keychain (`macrdp credential rotate`)",
        );
    }
    if skip_auth {
        return Some(
            "--skip-auth can't be combined with --auth access-credential, which always \
             checks the access credential",
        );
    }
    None
}

// ---- secret generation ------------------------------------------------------

/// A new random secret: 28 characters from [`SECRET_ALPHABET`] in groups of
/// four, e.g. `7k2m-q9vd-…` (140 bits).
pub fn generate() -> Result<Zeroizing<String>> {
    let mut random = Zeroizing::new([0u8; SECRET_RANDOM_BYTES]);
    getrandom::getrandom(&mut *random)
        .map_err(|e| anyhow!("generating the access credential: {e}"))?;
    Ok(format_secret(&random))
}

/// Encodes `random` as the first 140 bits, 5 bits per character.
fn format_secret(random: &[u8; SECRET_RANDOM_BYTES]) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::with_capacity(SECRET_CHARS + SECRET_CHARS / 4));
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    let mut next = 0;
    for n in 0..SECRET_CHARS {
        if bits < 5 {
            acc = (acc << 8) | u32::from(random[next]);
            next += 1;
            bits += 8;
        }
        bits -= 5;
        let index = (acc >> bits) & 0x1f;
        acc &= (1 << bits) - 1;
        if n > 0 && n % 4 == 0 {
            out.push('-');
        }
        out.push(char::from(SECRET_ALPHABET[index as usize]));
    }
    out
}

// ---- Keychain ---------------------------------------------------------------

/// What the Keychain holds for an account.
pub enum Stored {
    Found(Zeroizing<String>),
    Missing,
}

/// `security` exits with 44 for errSecItemNotFound.
const SECURITY_ITEM_NOT_FOUND: i32 = 44;

/// Read the access credential for `account`. `Err` means the Keychain couldn't
/// be asked (or answered with an error other than "not found"), which is not
/// the same as the item being absent.
pub fn read(account: &str) -> Result<Stored> {
    let out = std::process::Command::new("/usr/bin/security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            account,
            "-w",
        ])
        .output()
        .context("invoke security(1)")?;
    if out.status.code() == Some(SECURITY_ITEM_NOT_FOUND) {
        return Ok(Stored::Missing);
    }
    if !out.status.success() {
        return Err(anyhow!(
            "reading the access credential from the Keychain failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let mut s = Zeroizing::new(
        String::from_utf8(out.stdout)
            .map_err(|_| anyhow!("the Keychain returned a non-UTF-8 access credential"))?,
    );
    if s.ends_with('\n') {
        s.pop();
    }
    if s.is_empty() {
        return Ok(Stored::Missing);
    }
    Ok(Stored::Found(s))
}

/// The `security -i` command that stores `secret` for `account`, or `None`
/// when either holds a character its line parser can't take safely.
fn store_command(account: &str, secret: &str) -> Option<Zeroizing<String>> {
    let unsafe_char = |c: char| c == '"' || c == '\\' || c.is_control();
    if account.is_empty() || account.chars().any(unsafe_char) || secret.chars().any(unsafe_char) {
        return None;
    }
    Some(Zeroizing::new(format!(
        "add-generic-password -U -s \"{KEYCHAIN_SERVICE}\" -a \"{account}\" -w \"{secret}\"\n"
    )))
}

/// Store `secret` for `account`, replacing any previous one, and check it reads
/// back. The secret goes to `security -i` on stdin, never on a command line.
pub fn store(account: &str, secret: &str) -> Result<()> {
    use std::io::Write as _;
    use std::process::Stdio;

    let line = store_command(account, secret)
        .ok_or_else(|| anyhow!("the username {account:?} can't be used as a Keychain account"))?;
    let mut child = std::process::Command::new("/usr/bin/security")
        .arg("-i")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("invoke security(1)")?;
    child
        .stdin
        .take()
        .context("security(1) stdin")?
        .write_all(line.as_bytes())
        .context("writing to security(1)")?;
    let out = child
        .wait_with_output()
        .context("waiting for security(1)")?;
    if !out.status.success() {
        return Err(anyhow!(
            "storing the access credential in the Keychain failed ({}): {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    match read(account)? {
        Stored::Found(s) if *s == secret => Ok(()),
        _ => Err(anyhow!(
            "the Keychain didn't return the access credential that was just stored"
        )),
    }
}

// ---- validation -------------------------------------------------------------

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The access credential the server accepts right now; `None` accepts nothing.
#[derive(Clone, Default)]
pub struct CurrentSecret(Arc<RwLock<Option<Zeroizing<String>>>>);

impl CurrentSecret {
    pub fn new(secret: Zeroizing<String>) -> Self {
        Self(Arc::new(RwLock::new(Some(secret))))
    }

    /// Replace the secret; true when it changed.
    pub fn replace(&self, secret: Option<Zeroizing<String>>) -> bool {
        let mut slot = self.0.write().expect("access credential lock poisoned");
        let same = match (slot.as_ref(), secret.as_ref()) {
            (Some(a), Some(b)) => constant_time_eq(a.as_bytes(), b.as_bytes()),
            (None, None) => true,
            _ => false,
        };
        if !same {
            *slot = secret;
        }
        !same
    }

    pub fn matches(&self, password: &str) -> bool {
        let slot = self.0.read().expect("access credential lock poisoned");
        slot.as_ref()
            .is_some_and(|s| constant_time_eq(s.as_bytes(), password.as_bytes()))
    }
}

/// Accepts a client only when its password is the current access credential.
///
/// IronRDP calls it with the credentials the client delegates at the end of
/// the NLA exchange, before anything else happens on the connection. That
/// includes a client trying to take over a live session, which IronRDP
/// authenticates against the credentials captured when that session began, so
/// without this check the old secret could still evict a session after a
/// rotation (`conn_test::a_rotated_access_credential_cannot_take_over_a_live_session`).
/// The username isn't compared: NLA already did, and it doesn't change on
/// rotation.
pub struct AccessCredentialValidator {
    current: CurrentSecret,
}

impl AccessCredentialValidator {
    pub fn new(current: CurrentSecret) -> Self {
        Self { current }
    }
}

#[async_trait::async_trait]
impl CredentialValidator for AccessCredentialValidator {
    async fn validate(
        &self,
        credentials: &Credentials,
    ) -> Result<CredentialDecision, CredentialValidationError> {
        Ok(if self.current.matches(&credentials.password) {
            CredentialDecision::Accept
        } else {
            CredentialDecision::Reject
        })
    }
}

/// Switch the server to `secret` (None: accept nothing); true when it changed.
/// Updates both what the validator accepts and the credential IronRDP's NLA
/// exchange checks for new connections. A live session isn't touched, and,
/// because IronRDP keeps the credentials captured when it began for takeover
/// candidates, the new secret can take it over only once it has ended.
pub fn apply(
    current: &CurrentSecret,
    server: &ironrdp_server::RdpServerHandle,
    account: &str,
    secret: Option<Zeroizing<String>>,
) -> bool {
    // With no secret, NLA gets a throwaway one so nothing can complete it.
    let nla_password = match secret.as_ref() {
        Some(s) => Some(Zeroizing::new((**s).clone())),
        None => generate().ok(),
    };
    if !current.replace(secret) {
        return false;
    }
    if let Some(password) = nla_password {
        let creds = Credentials {
            username: account.to_owned(),
            password: (*password).clone(),
            domain: None,
        };
        if let Err(e) = server.set_credentials(creds) {
            error!(error = %e, "access credential: couldn't pass the change to the server");
        }
    }
    true
}

fn stamp_path(dir: &Path) -> PathBuf {
    dir.join(CHANGE_STAMP)
}

/// Tell a running server that the stored credential changed.
pub fn touch_stamp(dir: &Path) -> std::io::Result<()> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    std::fs::create_dir_all(dir)?;
    std::fs::write(stamp_path(dir), format!("{nanos}\n"))
}

fn read_stamp(dir: &Path) -> Option<String> {
    std::fs::read_to_string(stamp_path(dir)).ok()
}

/// Watch [`CHANGE_STAMP`] in `status_dir` and switch the server to the stored
/// credential each time it changes. An item found missing then refuses every
/// new connection until one is set again, and is reported to the controller
/// like a missing one at startup. A Keychain that can't be read changes
/// nothing. Without a config directory there is nothing to watch, and a
/// rotation applies at the next start.
pub fn spawn_rotation_watcher(
    account: String,
    current: CurrentSecret,
    server: ironrdp_server::RdpServerHandle,
    status_dir: Option<PathBuf>,
) -> Option<tokio::task::JoinHandle<()>> {
    let Some(dir) = status_dir else {
        warn!(
            "access credential: no config directory to watch; a rotation applies at the next start"
        );
        return None;
    };
    Some(tokio::spawn(async move {
        let mut seen = read_stamp(&dir);
        let mut tick = tokio::time::interval(STAMP_POLL);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            let stamp = read_stamp(&dir);
            if stamp == seen {
                continue;
            }
            seen = stamp;
            let acct = account.clone();
            let stored = match tokio::task::spawn_blocking(move || read(&acct)).await {
                Ok(Ok(stored)) => stored,
                Ok(Err(e)) => {
                    warn!(error = format!("{e:#}"), "access credential: couldn't read the Keychain after a change; keeping the current one");
                    continue;
                }
                Err(e) => {
                    warn!(error = %e, "access credential: Keychain read task failed");
                    continue;
                }
            };
            match stored {
                Stored::Found(secret) => {
                    if apply(&current, &server, &account, Some(secret)) {
                        info!(user = %account, "access credential changed — new connections must use the new one; a live session stays connected");
                        let _ = auth_status::clear(&dir);
                    }
                }
                Stored::Missing => {
                    if apply(&current, &server, &account, None) {
                        error!(user = %account, "access credential removed from the Keychain — refusing new connections until one is set (`macrdp credential rotate`)");
                        let _ = auth_status::write(
                            &dir,
                            auth_status::Failure::NoAccessCredential,
                            &account,
                        );
                    }
                }
            }
        }
    }))
}

// ---- `macrdp credential …` ----------------------------------------------------

/// Run a `macrdp credential` subcommand for `account`; `mode` is the auth mode
/// the given arguments (or `--config` file) select, and `stamp_dir` the config
/// directory a running server watches for [`CHANGE_STAMP`].
pub fn run_command(
    cmd: CredentialCommand,
    account: &str,
    mode: AuthMode,
    stamp_dir: Option<&Path>,
) -> Result<()> {
    match cmd {
        CredentialCommand::ShowUsername => {
            println!("{account}");
        }
        CredentialCommand::Status => {
            let present = match read(account)? {
                Stored::Found(_) => "present",
                Stored::Missing => "missing (create one with `macrdp credential rotate`)",
            };
            println!("auth mode:         {}", mode.as_str());
            println!("username:          {account}");
            println!("access credential: {present}");
            println!("keychain item:     service \"{KEYCHAIN_SERVICE}\", account \"{account}\"");
        }
        CredentialCommand::Rotate => {
            let secret = generate()?;
            store(account, &secret)?;
            // stdout carries only the secret, so the menu-bar controller (or a
            // script) can capture it; everything for a person goes to stderr.
            eprintln!("New RDP access credential for user \"{account}\" (shown only this once):");
            println!("{}", *secret);
            eprintln!(
                "Enter it as the password in your RDP client, with the username above. It is \
                 stored in your login Keychain (service \"{KEYCHAIN_SERVICE}\"); macrdp can't \
                 show it again, so rotate again if you lose it."
            );
            match stamp_dir.map(touch_stamp) {
                Some(Ok(())) => eprintln!(
                    "A running server switches to it within {} s, after which the previous \
                     one is refused.",
                    STAMP_POLL.as_secs()
                ),
                Some(Err(e)) => eprintln!(
                    "Couldn't tell a running server ({e}); it switches to the new credential \
                     when it next starts."
                ),
                None => eprintln!("A running server switches to it when it next starts."),
            }
            if mode != AuthMode::AccessCredential {
                eprintln!(
                    "Note: macrdp is set to --auth {}. Set AUTH_MODE=access-credential in \
                     config.env (or pass --auth access-credential) to use this credential.",
                    mode.as_str()
                );
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_format_is_seven_groups_of_four_from_the_alphabet() {
        for seed in [
            [0u8; SECRET_RANDOM_BYTES],
            [0xff; SECRET_RANDOM_BYTES],
            [0x5a; SECRET_RANDOM_BYTES],
        ] {
            let s = format_secret(&seed);
            let groups: Vec<&str> = s.split('-').collect();
            assert_eq!(groups.len(), 7, "{}", *s);
            assert!(groups.iter().all(|g| g.len() == 4), "{}", *s);
            assert!(s.bytes().all(|b| b == b'-' || SECRET_ALPHABET.contains(&b)));
        }
        assert_eq!(
            *format_secret(&[0; SECRET_RANDOM_BYTES]),
            "0000-0000-0000-0000-0000-0000-0000"
        );
        assert_eq!(
            *format_secret(&[0xff; SECRET_RANDOM_BYTES]),
            "zzzz-zzzz-zzzz-zzzz-zzzz-zzzz-zzzz"
        );
    }

    #[test]
    fn secret_encoding_uses_the_bits_in_order() {
        // 0b00001_00010_00011_00100_0000... -> "1234" then zeros.
        let mut seed = [0u8; SECRET_RANDOM_BYTES];
        seed[0] = 0b0000_1000;
        seed[1] = 0b1000_0110;
        seed[2] = 0b0100_0000;
        assert_eq!(&format_secret(&seed)[..4], "1234");
        // The last 4 of the 144 random bits are unused.
        let mut tail = [0u8; SECRET_RANDOM_BYTES];
        tail[SECRET_RANDOM_BYTES - 1] = 0x0f;
        assert_eq!(
            *format_secret(&tail),
            *format_secret(&[0; SECRET_RANDOM_BYTES])
        );
        tail[SECRET_RANDOM_BYTES - 1] = 0x10;
        assert_ne!(
            *format_secret(&tail),
            *format_secret(&[0; SECRET_RANDOM_BYTES])
        );
    }

    #[test]
    fn generated_secrets_differ() {
        let a = generate().unwrap();
        let b = generate().unwrap();
        assert_ne!(*a, *b);
        assert_eq!(a.len(), SECRET_CHARS + SECRET_CHARS / 4 - 1);
    }

    #[test]
    fn store_command_quotes_safe_input_and_refuses_the_rest() {
        assert_eq!(
            store_command("alice", "ab12-cd34")
                .as_deref()
                .map(String::as_str),
            Some("add-generic-password -U -s \"macrdp-access\" -a \"alice\" -w \"ab12-cd34\"\n")
        );
        assert!(store_command("", "x").is_none());
        assert!(store_command("a\"b", "x").is_none());
        assert!(store_command("a\\b", "x").is_none());
        assert!(store_command("a\nb", "x").is_none());
        assert!(store_command("alice", "x\"y").is_none());
    }

    #[test]
    fn current_secret_tracks_rotation_and_removal() {
        let current = CurrentSecret::new(Zeroizing::new("old".into()));
        assert!(current.matches("old"));
        assert!(!current.matches("new"));
        assert!(
            !current.replace(Some(Zeroizing::new("old".into()))),
            "same secret is no change"
        );
        assert!(current.replace(Some(Zeroizing::new("new".into()))));
        assert!(current.matches("new"));
        assert!(!current.matches("old"));
        assert!(current.replace(None));
        assert!(!current.matches("new"));
        assert!(!current.matches(""));
        assert!(!current.replace(None));
    }

    #[test]
    fn conflicts_name_the_setting() {
        assert_eq!(conflicting_setting(false, false, false, false), None);
        assert!(conflicting_setting(false, false, false, true)
            .unwrap()
            .contains("--auto-unlock"));
        assert!(conflicting_setting(true, false, false, false)
            .unwrap()
            .contains("--password"));
        assert!(conflicting_setting(false, true, false, false)
            .unwrap()
            .contains("PASSWORD_FILE"));
        assert!(conflicting_setting(false, false, true, false)
            .unwrap()
            .contains("--skip-auth"));
    }

    #[test]
    fn stamp_changes_on_every_touch() {
        let dir = std::env::temp_dir().join(format!("macrdp-ac-stamp-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(read_stamp(&dir), None);
        touch_stamp(&dir).unwrap();
        let first = read_stamp(&dir);
        assert!(first.is_some());
        touch_stamp(&dir).unwrap();
        assert_ne!(read_stamp(&dir), first);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn validator_follows_the_current_secret() {
        let current = CurrentSecret::new(Zeroizing::new("s1".into()));
        let v = AccessCredentialValidator::new(current.clone());
        let creds = |p: &str| Credentials {
            username: "anyone".into(),
            password: p.into(),
            domain: None,
        };
        assert_eq!(
            v.validate(&creds("s1")).await.unwrap(),
            CredentialDecision::Accept
        );
        assert_eq!(
            v.validate(&creds("s2")).await.unwrap(),
            CredentialDecision::Reject
        );
        current.replace(Some(Zeroizing::new("s2".into())));
        assert_eq!(
            v.validate(&creds("s1")).await.unwrap(),
            CredentialDecision::Reject
        );
        assert_eq!(
            v.validate(&creds("s2")).await.unwrap(),
            CredentialDecision::Accept
        );
        current.replace(None);
        assert_eq!(
            v.validate(&creds("s2")).await.unwrap(),
            CredentialDecision::Reject
        );
    }
}
