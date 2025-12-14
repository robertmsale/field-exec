use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use async_ssh2_tokio::Error as SshError;
use codex_remote_adapters::ssh::{run_command, SshAuth, SshTimeouts};
use codex_remote_api::signals::{
    AuthProvide, AuthRequired, SshAuthorizedKeyRequest, SshAuthorizedKeyResponse, SshCancelStream,
    SshExecRequest, SshExecResponse, SshGenerateKeyRequest, SshGenerateKeyResponse,
    SshInstallPublicKeyRequest, SshInstallPublicKeyResponse, SshStartCommandRequest,
    SshStartCommandResponse, SshStreamExit, SshStreamLine, SshWriteFileRequest, SshWriteFileResponse,
};
use codex_remote_rinf::storage::StorageClient;
use rinf::{DartSignal, RustSignal};
use rand_core::OsRng;
use ssh_key::{Algorithm, LineEnding, PrivateKey};
use tokio::spawn;
use tokio::sync::{mpsc, Mutex, oneshot};
use tokio::time::timeout;

const AUTH_KIND_SSH_PASSWORD: i32 = 0;

const KEYCHAIN_KEY_SSH_PRIVATE_KEY_PEM: &str = "ssh_private_key_pem";

#[derive(Clone)]
struct AuthBroker {
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Option<String>>>>>,
}

impl AuthBroker {
    fn new() -> Self {
        let broker = Self {
            pending: Arc::new(Mutex::new(HashMap::new())),
        };
        broker.spawn_listener();
        broker
    }

    fn spawn_listener(&self) {
        let pending = self.pending.clone();
        spawn(async move {
            let receiver = AuthProvide::get_dart_signal_receiver();
            while let Some(pack) = receiver.recv().await {
                let request_id = pack.message.request_id;
                let tx = { pending.lock().await.remove(&request_id) };
                if let Some(tx) = tx {
                    let _ = tx.send(pack.message.value);
                }
            }
        });
    }

    async fn request_password(&self, request_id: u64, message: String) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(request_id, tx);

        AuthRequired {
            request_id,
            kind: AUTH_KIND_SSH_PASSWORD,
            message,
        }
        .send_signal_to_dart();

        let value = timeout(Duration::from_secs(300), rx)
            .await
            .map_err(|_| "Password prompt timed out".to_owned())?
            .map_err(|_| "Password prompt cancelled".to_owned())?;

        value.ok_or_else(|| "Password prompt cancelled".to_owned())
    }
}

pub async fn run() {
    let storage = StorageClient::new();
    let auth = AuthBroker::new();

    let exec_rx = SshExecRequest::get_dart_signal_receiver();
    let start_rx = SshStartCommandRequest::get_dart_signal_receiver();
    let write_rx = SshWriteFileRequest::get_dart_signal_receiver();
    let gen_rx = SshGenerateKeyRequest::get_dart_signal_receiver();
    let authkey_rx = SshAuthorizedKeyRequest::get_dart_signal_receiver();
    let install_rx = SshInstallPublicKeyRequest::get_dart_signal_receiver();

    let streams = StreamRegistry::new();

    loop {
        tokio::select! {
            Some(pack) = exec_rx.recv() => {
                let req = pack.message;
                let storage = storage.clone();
                let auth = auth.clone();
                spawn(async move {
                    let response = handle_exec(storage, auth, req).await;
                    response.send_signal_to_dart();
                });
            }
            Some(pack) = start_rx.recv() => {
                let req = pack.message;
                let storage = storage.clone();
                let auth = auth.clone();
                let streams = streams.clone();
                spawn(async move {
                    let response = streams.start(storage, auth, req).await;
                    response.send_signal_to_dart();
                });
            }
            Some(pack) = write_rx.recv() => {
                let req = pack.message;
                let storage = storage.clone();
                let auth = auth.clone();
                spawn(async move {
                    let response = handle_write_file(storage, auth, req).await;
                    response.send_signal_to_dart();
                });
            }
            Some(pack) = gen_rx.recv() => {
                let req = pack.message;
                spawn(async move {
                    let response = handle_generate_key(req);
                    response.send_signal_to_dart();
                });
            }
            Some(pack) = authkey_rx.recv() => {
                let req = pack.message;
                spawn(async move {
                    let response = handle_authorized_key(req);
                    response.send_signal_to_dart();
                });
            }
            Some(pack) = install_rx.recv() => {
                let req = pack.message;
                spawn(async move {
                    let response = handle_install_public_key(req).await;
                    response.send_signal_to_dart();
                });
            }
            else => break,
        }
    }
}

async fn handle_exec(
    storage: StorageClient,
    auth: AuthBroker,
    req: SshExecRequest,
) -> SshExecResponse {
    let request_id = req.request_id;

    let port: u16 = match u16::try_from(req.port) {
        Ok(p) => p,
        Err(_) => {
            return SshExecResponse {
                request_id,
                ok: false,
                stdout: String::new(),
                stderr: String::new(),
                exit_status: -1,
                error: Some("Invalid port".to_owned()),
            };
        }
    };

    let timeouts = SshTimeouts {
        connect: Duration::from_millis(req.connect_timeout_ms.max(1) as u64),
        command: Duration::from_millis(req.command_timeout_ms.max(1) as u64),
    };

    let private_key_pem = req
        .private_key_pem
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(String::new);

    let private_key_pem = if private_key_pem.trim().is_empty() {
        storage
            .get_keychain_string(KEYCHAIN_KEY_SSH_PRIVATE_KEY_PEM)
            .await
            .ok()
            .flatten()
            .unwrap_or_default()
    } else {
        private_key_pem
    };

    let last_err = if !private_key_pem.trim().is_empty() {
        match run_command(
            &req.host,
            port,
            &req.username,
            SshAuth::Key {
                private_key_pem: &private_key_pem,
                passphrase: req.private_key_passphrase.as_deref(),
            },
            &req.command,
            timeouts,
        )
        .await
        {
            Ok(r) => {
                return SshExecResponse {
                    request_id,
                    ok: true,
                    stdout: r.stdout,
                    stderr: r.stderr,
                    exit_status: r.exit_status,
                    error: None,
                };
            }
            Err(SshError::KeyAuthFailed) => Some("SSH key authentication failed".to_owned()),
            Err(SshError::KeyInvalid(_)) => {
                return SshExecResponse {
                    request_id,
                    ok: false,
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_status: -1,
                    error: Some("SSH private key is invalid or passphrase is wrong".to_owned()),
                };
            }
            Err(e) => {
                return SshExecResponse {
                    request_id,
                    ok: false,
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_status: -1,
                    error: Some(e.to_string()),
                };
            }
        }
    } else {
        Some("No SSH private key set".to_owned())
    };

    let prompt = format!(
        "{}. Password required for {}@{}.",
        last_err.unwrap_or_else(|| "SSH auth failed".to_owned()),
        req.username,
        req.host
    );
    let password = match auth.request_password(request_id, prompt).await {
        Ok(pw) => pw,
        Err(e) => {
            return SshExecResponse {
                request_id,
                ok: false,
                stdout: String::new(),
                stderr: String::new(),
                exit_status: -1,
                error: Some(e),
            };
        }
    };

    match run_command(
        &req.host,
        port,
        &req.username,
        SshAuth::Password(&password),
        &req.command,
        timeouts,
    )
    .await
    {
        Ok(r) => SshExecResponse {
            request_id,
            ok: true,
            stdout: r.stdout,
            stderr: r.stderr,
            exit_status: r.exit_status,
            error: None,
        },
        Err(e) => SshExecResponse {
            request_id,
            ok: false,
            stdout: String::new(),
            stderr: String::new(),
            exit_status: -1,
            error: Some(e.to_string()),
        },
    }
}

#[derive(Clone)]
struct StreamRegistry {
    next_stream_id: Arc<std::sync::atomic::AtomicU64>,
    tasks: Arc<Mutex<HashMap<u64, tokio::task::JoinHandle<()>>>>,
}

impl StreamRegistry {
    fn new() -> Self {
        let reg = Self {
            next_stream_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
            tasks: Arc::new(Mutex::new(HashMap::new())),
        };

        let tasks = reg.tasks.clone();
        spawn(async move {
            let cancel_rx = SshCancelStream::get_dart_signal_receiver();
            while let Some(pack) = cancel_rx.recv().await {
                let stream_id = pack.message.stream_id;
                let handle = { tasks.lock().await.remove(&stream_id) };
                if let Some(handle) = handle {
                    handle.abort();
                    SshStreamExit {
                        stream_id,
                        exit_status: -1,
                        error: Some("cancelled".to_owned()),
                    }
                    .send_signal_to_dart();
                }
            }
        });

        reg
    }

    async fn start(
        &self,
        storage: StorageClient,
        auth: AuthBroker,
        req: SshStartCommandRequest,
    ) -> SshStartCommandResponse {
        let request_id = req.request_id;
        let port: u16 = match u16::try_from(req.port) {
            Ok(p) => p,
            Err(_) => {
                return SshStartCommandResponse {
                    request_id,
                    ok: false,
                    stream_id: 0,
                    error: Some("Invalid port".to_owned()),
                };
            }
        };

        let stream_id = self
            .next_stream_id
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        let private_key_pem = resolve_key_pem(
            &storage,
            req.private_key_pem.clone(),
            KEYCHAIN_KEY_SSH_PRIVATE_KEY_PEM,
        )
        .await;

        let connect_timeout = Duration::from_millis(req.connect_timeout_ms.max(1) as u64);

        let command = req.command.clone();
        let host = req.host.clone();
        let username = req.username.clone();
        let passphrase = req.private_key_passphrase.clone();

        let auth_result = connect_with_optional_password(
            &auth,
            request_id,
            &host,
            port,
            &username,
            private_key_pem,
            passphrase,
            connect_timeout,
        )
        .await;

        let (client, _password_used) = match auth_result {
            Ok(v) => v,
            Err(e) => {
                return SshStartCommandResponse {
                    request_id,
                    ok: false,
                    stream_id: 0,
                    error: Some(e),
                };
            }
        };

        let handle = spawn(async move {
            tokio::task::yield_now().await;
            let (stdout_tx, mut stdout_rx) = mpsc::channel::<Vec<u8>>(16);
            let (stderr_tx, mut stderr_rx) = mpsc::channel::<Vec<u8>>(16);

            let exec_future = client.execute_io(&command, stdout_tx, Some(stderr_tx), None, false, None);

            let mut out_pending = String::new();
            let mut err_pending = String::new();

            tokio::pin!(exec_future);
            let exit_status = loop {
                tokio::select! {
                    result = &mut exec_future => break result,
                    Some(bytes) = stdout_rx.recv() => {
                        push_lines(stream_id, false, &mut out_pending, &bytes);
                    }
                    Some(bytes) = stderr_rx.recv() => {
                        push_lines(stream_id, true, &mut err_pending, &bytes);
                    }
                }
            };

            while let Some(bytes) = stdout_rx.recv().await {
                push_lines(stream_id, false, &mut out_pending, &bytes);
            }
            while let Some(bytes) = stderr_rx.recv().await {
                push_lines(stream_id, true, &mut err_pending, &bytes);
            }

            flush_pending(stream_id, false, &mut out_pending);
            flush_pending(stream_id, true, &mut err_pending);

            match exit_status {
                Ok(code) => {
                    SshStreamExit {
                        stream_id,
                        exit_status: i32::try_from(code).unwrap_or(-1),
                        error: None,
                    }
                    .send_signal_to_dart();
                }
                Err(e) => {
                    SshStreamExit {
                        stream_id,
                        exit_status: -1,
                        error: Some(e.to_string()),
                    }
                    .send_signal_to_dart();
                }
            }
        });

        self.tasks.lock().await.insert(stream_id, handle);

        SshStartCommandResponse {
            request_id,
            ok: true,
            stream_id,
            error: None,
        }
    }
}

fn push_lines(stream_id: u64, is_stderr: bool, pending: &mut String, bytes: &[u8]) {
    let chunk = String::from_utf8_lossy(bytes);
    pending.push_str(&chunk);
    while let Some(idx) = pending.find('\n') {
        let line = pending[..idx].trim_end_matches('\r').to_owned();
        pending.drain(..idx + 1);
        SshStreamLine {
            stream_id,
            is_stderr,
            line,
        }
        .send_signal_to_dart();
    }
}

fn flush_pending(stream_id: u64, is_stderr: bool, pending: &mut String) {
    let line = pending.trim().to_owned();
    if line.is_empty() {
        pending.clear();
        return;
    }
    pending.clear();
    SshStreamLine {
        stream_id,
        is_stderr,
        line,
    }
    .send_signal_to_dart();
}

async fn resolve_key_pem(storage: &StorageClient, override_pem: Option<String>, keychain_key: &str) -> String {
    if let Some(s) = override_pem.filter(|s| !s.trim().is_empty()) {
        return s;
    }
    storage
        .get_keychain_string(keychain_key)
        .await
        .ok()
        .flatten()
        .unwrap_or_default()
}

async fn connect_with_optional_password(
    auth: &AuthBroker,
    request_id: u64,
    host: &str,
    port: u16,
    username: &str,
    private_key_pem: String,
    private_key_passphrase: Option<String>,
    connect_timeout: Duration,
) -> Result<(async_ssh2_tokio::Client, bool), String> {
    if !private_key_pem.trim().is_empty() {
        let auth_method = async_ssh2_tokio::AuthMethod::with_key(
            &private_key_pem,
            private_key_passphrase.as_deref(),
        );
        match timeout(
            connect_timeout,
            async_ssh2_tokio::Client::connect(
                (host, port),
                username,
                auth_method,
                async_ssh2_tokio::ServerCheckMethod::NoCheck,
            ),
        )
        .await
        {
            Ok(Ok(client)) => return Ok((client, false)),
            Ok(Err(SshError::KeyAuthFailed)) => {}
            Ok(Err(SshError::KeyInvalid(_))) => {
                return Err("SSH private key is invalid or passphrase is wrong".to_owned());
            }
            Ok(Err(e)) => return Err(e.to_string()),
            Err(_) => return Err("SSH connect timeout".to_owned()),
        }
    }

    let password = auth
        .request_password(
            request_id,
            format!("Password required for {}@{}.", username, host),
        )
        .await?;

    let auth_method = async_ssh2_tokio::AuthMethod::with_password(&password);
    timeout(
        connect_timeout,
        async_ssh2_tokio::Client::connect(
            (host, port),
            username,
            auth_method,
            async_ssh2_tokio::ServerCheckMethod::NoCheck,
        ),
    )
    .await
    .map_err(|_| "SSH connect timeout".to_owned())?
    .map(|c| (c, true))
    .map_err(|e| e.to_string())
}

async fn handle_write_file(
    storage: StorageClient,
    auth: AuthBroker,
    req: SshWriteFileRequest,
) -> SshWriteFileResponse {
    let request_id = req.request_id;
    let port: u16 = match u16::try_from(req.port) {
        Ok(p) => p,
        Err(_) => {
            return SshWriteFileResponse {
                request_id,
                ok: false,
                error: Some("Invalid port".to_owned()),
            };
        }
    };

    let private_key_pem =
        resolve_key_pem(&storage, req.private_key_pem.clone(), KEYCHAIN_KEY_SSH_PRIVATE_KEY_PEM).await;

    let connect_timeout = Duration::from_millis(req.connect_timeout_ms.max(1) as u64);
    let command_timeout = Duration::from_millis(req.command_timeout_ms.max(1) as u64);

    let (client, _pw) = match connect_with_optional_password(
        &auth,
        request_id,
        &req.host,
        port,
        &req.username,
        private_key_pem,
        req.private_key_passphrase.clone(),
        connect_timeout,
    )
    .await
    {
        Ok(v) => v,
        Err(e) => {
            return SshWriteFileResponse {
                request_id,
                ok: false,
                error: Some(e),
            };
        }
    };

    let remote_dir = match req.remote_path.rfind('/') {
        Some(idx) => &req.remote_path[..idx],
        None => ".",
    };
    let cmd = format!(
        "mkdir -p {} && cat > {}",
        sh_quote(remote_dir),
        sh_quote(&req.remote_path)
    );

    let (stdout_tx, mut stdout_rx) = mpsc::channel::<Vec<u8>>(8);
    let (stderr_tx, mut stderr_rx) = mpsc::channel::<Vec<u8>>(8);
    let (stdin_tx, stdin_rx) = mpsc::channel::<Vec<u8>>(2);

    let exec_future = client.execute_io(&cmd, stdout_tx, Some(stderr_tx), Some(stdin_rx), false, None);
    tokio::pin!(exec_future);

    let send_stdin = async move {
        let _ = stdin_tx.send(req.contents.into_bytes()).await;
        let _ = stdin_tx.send(Vec::new()).await;
    };
    spawn(send_stdin);

    let mut out = Vec::new();
    let mut err = Vec::new();

    let status = timeout(command_timeout, async {
        loop {
            tokio::select! {
                result = &mut exec_future => break result,
                Some(bytes) = stdout_rx.recv() => out.extend_from_slice(&bytes),
                Some(bytes) = stderr_rx.recv() => err.extend_from_slice(&bytes),
            }
        }
    })
    .await;

    let status = match status {
        Ok(Ok(code)) => i32::try_from(code).unwrap_or(-1),
        Ok(Err(e)) => {
            return SshWriteFileResponse {
                request_id,
                ok: false,
                error: Some(e.to_string()),
            };
        }
        Err(_) => {
            return SshWriteFileResponse {
                request_id,
                ok: false,
                error: Some("SSH command timeout".to_owned()),
            };
        }
    };

    if status == 0 {
        return SshWriteFileResponse {
            request_id,
            ok: true,
            error: None,
        };
    }

    let stderr = String::from_utf8_lossy(&err).to_string();
    let stdout = String::from_utf8_lossy(&out).to_string();
    let msg = if stderr.trim().is_empty() {
        stdout
    } else {
        stderr
    };

    SshWriteFileResponse {
        request_id,
        ok: false,
        error: Some(format!("write failed (exit={status}): {}", msg.trim())),
    }
}

fn sh_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_owned();
    }
    if s.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '/' | ':' | '=' | '@' | '-'))
    {
        return s.to_owned();
    }
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn handle_generate_key(req: SshGenerateKeyRequest) -> SshGenerateKeyResponse {
    let request_id = req.request_id;
    let mut rng = OsRng;
    let mut key = match PrivateKey::random(&mut rng, Algorithm::Ed25519) {
        Ok(k) => k,
        Err(e) => {
            return SshGenerateKeyResponse {
                request_id,
                ok: false,
                private_key_pem: String::new(),
                error: Some(e.to_string()),
            };
        }
    };
    key.set_comment(req.comment);
    match key.to_openssh(LineEnding::LF) {
        Ok(pem) => SshGenerateKeyResponse {
            request_id,
            ok: true,
            private_key_pem: pem.to_string(),
            error: None,
        },
        Err(e) => SshGenerateKeyResponse {
            request_id,
            ok: false,
            private_key_pem: String::new(),
            error: Some(e.to_string()),
        },
    }
}

fn handle_authorized_key(req: SshAuthorizedKeyRequest) -> SshAuthorizedKeyResponse {
    let request_id = req.request_id;
    let parsed = russh::keys::decode_secret_key(&req.private_key_pem, req.private_key_passphrase.as_deref())
        .map_err(|e| e.to_string());
    let mut key = match parsed {
        Ok(k) => k,
        Err(e) => {
            return SshAuthorizedKeyResponse {
                request_id,
                ok: false,
                authorized_key_line: String::new(),
                error: Some(e),
            };
        }
    };
    key.set_comment(req.comment);
    match key.public_key().to_openssh() {
        Ok(line) => SshAuthorizedKeyResponse {
            request_id,
            ok: true,
            authorized_key_line: line,
            error: None,
        },
        Err(e) => SshAuthorizedKeyResponse {
            request_id,
            ok: false,
            authorized_key_line: String::new(),
            error: Some(e.to_string()),
        },
    }
}

async fn handle_install_public_key(req: SshInstallPublicKeyRequest) -> SshInstallPublicKeyResponse {
    let request_id = req.request_id;
    let at = match req.user_at_host.find('@') {
        Some(i) => i,
        None => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some("user_at_host must be username@host".to_owned()),
            };
        }
    };
    let username = &req.user_at_host[..at];
    let host = &req.user_at_host[at + 1..];
    let port: u16 = match u16::try_from(req.port) {
        Ok(p) => p,
        Err(_) => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some("Invalid port".to_owned()),
            };
        }
    };

    let parsed = russh::keys::decode_secret_key(&req.private_key_pem, req.private_key_passphrase.as_deref());
    let mut key = match parsed {
        Ok(k) => k,
        Err(e) => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some(e.to_string()),
            };
        }
    };
    key.set_comment(req.comment);
    let public_line = match key.public_key().to_openssh() {
        Ok(l) => l,
        Err(e) => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some(e.to_string()),
            };
        }
    };

    let escaped = public_line.replace('\'', "'\\''");
    let remote_command = [
        "umask 077",
        "mkdir -p ~/.ssh",
        "chmod 700 ~/.ssh",
        "touch ~/.ssh/authorized_keys",
        "chmod 600 ~/.ssh/authorized_keys",
        &format!(
            "grep -qxF '{}' ~/.ssh/authorized_keys || printf '%s\\n' '{}' >> ~/.ssh/authorized_keys",
            escaped, escaped
        ),
    ]
    .join("; ");

    let connect_timeout = Duration::from_secs(10);
    let command_timeout = Duration::from_secs(30);

    let auth_method = async_ssh2_tokio::AuthMethod::with_password(&req.password);
    let client = match timeout(
        connect_timeout,
        async_ssh2_tokio::Client::connect(
            (host, port),
            username,
            auth_method,
            async_ssh2_tokio::ServerCheckMethod::NoCheck,
        ),
    )
    .await
    {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some(e.to_string()),
            };
        }
        Err(_) => {
            return SshInstallPublicKeyResponse {
                request_id,
                ok: false,
                error: Some("SSH connect timeout".to_owned()),
            };
        }
    };

    match timeout(command_timeout, client.execute(&remote_command)).await {
        Ok(Ok(_)) => SshInstallPublicKeyResponse {
            request_id,
            ok: true,
            error: None,
        },
        Ok(Err(e)) => SshInstallPublicKeyResponse {
            request_id,
            ok: false,
            error: Some(e.to_string()),
        },
        Err(_) => SshInstallPublicKeyResponse {
            request_id,
            ok: false,
            error: Some("SSH command timeout".to_owned()),
        },
    }
}
