//! This `hub` crate is the
//! entry point of the Rust logic.

use codex_remote_api::signals::{CorePing, CorePong};
use codex_remote_runtime::spawn_services;
use rinf::{dart_shutdown, write_interface, DartSignal, RustSignal};
use tokio::spawn;

// Uncomment below to target the web.
// use tokio_with_wasm::alias as tokio;

write_interface!();

// You can go with any async library, not just `tokio`.
#[tokio::main(flavor = "current_thread")]
async fn main() {
    spawn_services();

    spawn(async move {
        let receiver = CorePing::get_dart_signal_receiver();
        while let Some(signal_pack) = receiver.recv().await {
            CorePong {
                nonce: signal_pack.message.nonce,
            }
            .send_signal_to_dart();
        }
    });

    // Keep the main function running until Dart shutdown.
    dart_shutdown().await;
}
