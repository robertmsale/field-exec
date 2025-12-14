use rinf::{DartSignal, RustSignal};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, DartSignal)]
pub struct CorePing {
    pub nonce: u64,
}

#[derive(Serialize, RustSignal)]
pub struct CorePong {
    pub nonce: u64,
}

/// `kind`
/// - 0: ssh_password
#[derive(Serialize, RustSignal)]
pub struct AuthRequired {
    pub request_id: u64,
    pub kind: i32,
    pub message: String,
}

#[derive(Deserialize, DartSignal)]
pub struct AuthProvide {
    pub request_id: u64,
    pub value: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshExecRequest {
    pub request_id: u64,
    pub host: String,
    pub port: i32,
    pub username: String,
    pub command: String,
    pub private_key_pem: Option<String>,
    pub private_key_passphrase: Option<String>,
    pub connect_timeout_ms: i32,
    pub command_timeout_ms: i32,
}

#[derive(Serialize, RustSignal)]
pub struct SshExecResponse {
    pub request_id: u64,
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    pub exit_status: i32,
    pub error: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshStartCommandRequest {
    pub request_id: u64,
    pub host: String,
    pub port: i32,
    pub username: String,
    pub command: String,
    pub private_key_pem: Option<String>,
    pub private_key_passphrase: Option<String>,
    pub connect_timeout_ms: i32,
}

#[derive(Serialize, RustSignal)]
pub struct SshStartCommandResponse {
    pub request_id: u64,
    pub ok: bool,
    pub stream_id: u64,
    pub error: Option<String>,
}

#[derive(Serialize, RustSignal)]
pub struct SshStreamLine {
    pub stream_id: u64,
    pub is_stderr: bool,
    pub line: String,
}

#[derive(Serialize, RustSignal)]
pub struct SshStreamExit {
    pub stream_id: u64,
    pub exit_status: i32,
    pub error: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshCancelStream {
    pub stream_id: u64,
}

#[derive(Deserialize, DartSignal)]
pub struct SshWriteFileRequest {
    pub request_id: u64,
    pub host: String,
    pub port: i32,
    pub username: String,
    pub remote_path: String,
    pub contents: String,
    pub private_key_pem: Option<String>,
    pub private_key_passphrase: Option<String>,
    pub connect_timeout_ms: i32,
    pub command_timeout_ms: i32,
}

#[derive(Serialize, RustSignal)]
pub struct SshWriteFileResponse {
    pub request_id: u64,
    pub ok: bool,
    pub error: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshGenerateKeyRequest {
    pub request_id: u64,
    pub comment: String,
}

#[derive(Serialize, RustSignal)]
pub struct SshGenerateKeyResponse {
    pub request_id: u64,
    pub ok: bool,
    pub private_key_pem: String,
    pub error: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshAuthorizedKeyRequest {
    pub request_id: u64,
    pub private_key_pem: String,
    pub private_key_passphrase: Option<String>,
    pub comment: String,
}

#[derive(Serialize, RustSignal)]
pub struct SshAuthorizedKeyResponse {
    pub request_id: u64,
    pub ok: bool,
    pub authorized_key_line: String,
    pub error: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct SshInstallPublicKeyRequest {
    pub request_id: u64,
    pub user_at_host: String,
    pub port: i32,
    pub password: String,
    pub private_key_pem: String,
    pub private_key_passphrase: Option<String>,
    pub comment: String,
}

#[derive(Serialize, RustSignal)]
pub struct SshInstallPublicKeyResponse {
    pub request_id: u64,
    pub ok: bool,
    pub error: Option<String>,
}

/// `scope`
/// - 0: shared_preferences
/// - 1: keychain
///
/// `op`
/// - 0: get_string
/// - 1: set_string
/// - 2: remove
#[derive(Serialize, RustSignal)]
pub struct StorageRequest {
    pub request_id: u64,
    pub scope: i32,
    pub op: i32,
    pub key: String,
    pub value: Option<String>,
}

#[derive(Deserialize, DartSignal)]
pub struct StorageResponse {
    pub request_id: u64,
    pub ok: bool,
    pub value: Option<String>,
    pub error: Option<String>,
}
