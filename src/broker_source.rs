//! (Fork spike C, not for upstream as is) Take accepted connections from a
//! broker over a Unix socket instead of binding a port, and move the live
//! session when the broker says the console changed hands.
//!
//! See `docs/fork/PLAN.md` (Phase 0, Spike C) and `spikes/broker-handover/`.
//! The broker owns the TCP listener and never parses RDP: it hands each
//! accepted socket to the instance for the current console session.
//!
//! Wire protocol over the Unix stream socket, every message exactly
//! [`MSG_LEN`] bytes of ASCII padded with spaces, so a file descriptor
//! (SCM_RIGHTS) always arrives with the message it belongs to:
//! - instance → broker: `HELLO <name>`
//! - broker → instance: `CONN` with one descriptor attached (a connected TCP
//!   socket); `MOVE redirect <address>` (Server Redirection PDU pointing at
//!   `<address>`); `MOVE drop` (end the connection with no reason, like a
//!   network failure, so clients with an auto-reconnect cookie retry);
//!   `MOVE errinfo` (Set Error Info "disconnected by another connection",
//!   what Windows sends when the console is taken).

use std::io::{self, Read as _, Write as _};
use std::net::TcpStream as StdTcpStream;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::Path;

use anyhow::{Context as _, Result};
use ironrdp_pdu::rdp::server_error_info::{ErrorInfo, ProtocolIndependentCode};
use ironrdp_pdu::rdp::server_redirection::{ServerRedirectionFlags, ServerRedirectionPdu};
use ironrdp_server::{
    ConnectionSource, ErrorInfoDisconnectHandle, IncomingConnection, ServerEvent,
    ServerRedirectionHandle, TransportTls,
};
use tokio::sync::mpsc;
use tracing::{info, warn};

/// Every message on the broker socket is this many bytes.
pub const MSG_LEN: usize = 64;

/// What the instance needs to move its live session.
pub struct MoveHandles {
    pub redirect: ServerRedirectionHandle,
    pub disconnect: ErrorInfoDisconnectHandle,
    pub events: mpsc::UnboundedSender<ServerEvent>,
}

/// Connections the broker handed over, for [`ironrdp_server::RdpServer::serve`].
pub struct BrokerSource {
    rx: mpsc::UnboundedReceiver<StdTcpStream>,
}

#[async_trait::async_trait]
impl ConnectionSource for BrokerSource {
    type Stream = tokio::net::TcpStream;

    // Cancel safe: nothing awaits after `recv` returns a connection.
    async fn accept(&mut self) -> io::Result<Option<IncomingConnection<Self::Stream>>> {
        let Some(std_stream) = self.rx.recv().await else {
            return Ok(None);
        };
        std_stream.set_nonblocking(true)?;
        if let Err(error) = std_stream.set_nodelay(true) {
            warn!(%error, "broker connection: failed to set TCP_NODELAY");
        }
        let peer = std_stream.peer_addr().ok();
        let local = std_stream.local_addr().ok();
        let stream = tokio::net::TcpStream::from_std(std_stream)?;
        // No accept-time RTT here: IronRDP keeps that field (macrdp divergence 15)
        // crate-private, so blank recovery treats a brokered link as LAN.
        let mut incoming = IncomingConnection::new(stream, TransportTls::Managed, peer);
        if let Some(local) = local {
            incoming = incoming.with_local_addr(local);
        }
        info!(?peer, "broker handed over a connection");
        Ok(Some(incoming))
    }
}

/// Connect to the broker at `path`, register as `name`, and start reading its
/// messages on a thread of its own.
pub fn connect(path: &Path, name: &str, handles: MoveHandles) -> Result<BrokerSource> {
    let mut sock = UnixStream::connect(path)
        .with_context(|| format!("connect to the broker socket {}", path.display()))?;
    sock.write_all(&pad(&format!("HELLO {name}"))?)
        .context("register with the broker")?;
    let (tx, rx) = mpsc::unbounded_channel();
    let name = name.to_owned();
    std::thread::Builder::new()
        .name("broker-source".into())
        .spawn(move || read_loop(sock, &name, &tx, &handles))
        .context("spawn the broker reader thread")?;
    Ok(BrokerSource { rx })
}

fn read_loop(
    mut sock: UnixStream,
    name: &str,
    tx: &mpsc::UnboundedSender<StdTcpStream>,
    handles: &MoveHandles,
) {
    info!(instance = name, "registered with the broker");
    loop {
        let mut buf = [0u8; MSG_LEN];
        let (got, fd) = match recv_with_fd(sock.as_raw_fd(), &mut buf) {
            Ok((0, _)) => {
                warn!("broker closed the socket; accepting no more connections");
                return;
            }
            Ok(r) => r,
            Err(error) => {
                warn!(%error, "broker socket read failed; accepting no more connections");
                return;
            }
        };
        if got < MSG_LEN {
            if let Err(error) = sock.read_exact(&mut buf[got..]) {
                warn!(%error, "broker message cut short; accepting no more connections");
                return;
            }
        }
        let text = String::from_utf8_lossy(&buf);
        let words: Vec<&str> = text.split_whitespace().collect();
        match (words.as_slice(), fd) {
            (["CONN"], Some(fd)) => {
                if tx.send(StdTcpStream::from(fd)).is_err() {
                    return;
                }
            }
            (["MOVE", "redirect", target], _) => {
                info!(target, "broker: console moved; redirecting the client");
                let pdu = ServerRedirectionPdu {
                    flags: ServerRedirectionFlags::TARGET_NET_ADDRESS,
                    target_net_address: Some((*target).to_owned()),
                    ..Default::default()
                };
                if handles.redirect.redirect(pdu).is_err() {
                    warn!("redirect: server event channel closed");
                }
            }
            (["MOVE", "drop"], _) => {
                info!("broker: console moved; dropping the connection");
                let _ = handles
                    .events
                    .send(ServerEvent::Quit("console moved (broker)".into()));
            }
            (["MOVE", "errinfo"], _) => {
                info!("broker: console moved; disconnecting with Set Error Info");
                let code = ErrorInfo::ProtocolIndependentCode(
                    ProtocolIndependentCode::DisconnectedByOtherconnection,
                );
                if handles.disconnect.disconnect(code).is_err() {
                    warn!("errinfo disconnect: server event channel closed");
                }
            }
            (other, fd) => {
                warn!(message = ?other, with_fd = fd.is_some(), "unknown broker message")
            }
        }
    }
}

fn pad(text: &str) -> Result<[u8; MSG_LEN]> {
    anyhow::ensure!(text.len() <= MSG_LEN, "broker message too long: {text}");
    let mut buf = [b' '; MSG_LEN];
    buf[..text.len()].copy_from_slice(text.as_bytes());
    Ok(buf)
}

/// `recvmsg` into `buf`, returning the byte count and the first descriptor
/// passed with it (any extra ones are closed). The descriptor is marked
/// close-on-exec, since macOS has no `MSG_CMSG_CLOEXEC` and macrdp spawns
/// helpers that must not inherit a client socket.
fn recv_with_fd(sock: RawFd, buf: &mut [u8]) -> io::Result<(usize, Option<OwnedFd>)> {
    let mut iov = libc::iovec {
        iov_base: buf.as_mut_ptr().cast(),
        iov_len: buf.len(),
    };
    // u64 storage keeps the control buffer aligned for cmsghdr.
    let mut control = [0u64; 8];
    // SAFETY: an all-zero msghdr is valid; the pointers set below outlive the call.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = std::mem::size_of_val(&control) as _;
    // SAFETY: msg points at live, correctly sized buffers.
    let n = unsafe { libc::recvmsg(sock, &mut msg, 0) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut received = None;
    // SAFETY: CMSG_* walk the control buffer recvmsg just filled, within msg_controllen.
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(cmsg).cast::<RawFd>();
                let bytes = (*cmsg).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                for i in 0..bytes / std::mem::size_of::<RawFd>() {
                    let fd = OwnedFd::from_raw_fd(std::ptr::read_unaligned(data.add(i)));
                    libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
                    if received.is_none() {
                        received = Some(fd);
                    }
                }
            }
            cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
        }
    }
    if msg.msg_flags & libc::MSG_CTRUNC != 0 {
        warn!("broker message's control data was truncated");
    }
    Ok((n as usize, received))
}
