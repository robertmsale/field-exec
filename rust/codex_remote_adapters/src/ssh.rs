use std::time::Duration;

use async_ssh2_tokio::client::{AuthMethod, Client, ServerCheckMethod};
use tokio::time::timeout;

pub struct SshCommandResult {
    pub stdout: String,
    pub stderr: String,
    pub exit_status: i32,
}

pub enum SshAuth<'a> {
    Key {
        private_key_pem: &'a str,
        passphrase: Option<&'a str>,
    },
    Password(&'a str),
}

#[derive(Clone, Copy)]
pub struct SshTimeouts {
    pub connect: Duration,
    pub command: Duration,
}

pub async fn run_command(
    host: &str,
    port: u16,
    username: &str,
    auth: SshAuth<'_>,
    command: &str,
    timeouts: SshTimeouts,
) -> Result<SshCommandResult, async_ssh2_tokio::Error> {
    let auth_method = match auth {
        SshAuth::Key {
            private_key_pem,
            passphrase,
        } => AuthMethod::with_key(private_key_pem, passphrase),
        SshAuth::Password(password) => AuthMethod::with_password(password),
    };

    let client = timeout(
        timeouts.connect,
        Client::connect(
            (host, port),
            username,
            auth_method,
            ServerCheckMethod::NoCheck,
        ),
    )
    .await
    .map_err(|_| {
        async_ssh2_tokio::Error::IoError(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "SSH connect timeout",
        ))
    })??;

    let result = timeout(timeouts.command, client.execute(command))
        .await
        .map_err(|_| {
            async_ssh2_tokio::Error::IoError(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "SSH command timeout",
            ))
        })??;

    Ok(SshCommandResult {
        stdout: result.stdout,
        stderr: result.stderr,
        exit_status: i32::try_from(result.exit_status).unwrap_or(-1),
    })
}
