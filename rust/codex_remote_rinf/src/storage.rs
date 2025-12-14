use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use codex_remote_api::signals::{StorageRequest, StorageResponse};
use rinf::{DartSignal, RustSignal};
use tokio::spawn;
use tokio::sync::{Mutex, oneshot};

pub const SCOPE_SHARED_PREFERENCES: i32 = 0;
pub const SCOPE_KEYCHAIN: i32 = 1;

pub const OP_GET_STRING: i32 = 0;
pub const OP_SET_STRING: i32 = 1;
pub const OP_REMOVE: i32 = 2;

#[derive(Clone)]
pub struct StorageClient {
    next_request_id: Arc<AtomicU64>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<StorageResponse>>>>,
}

impl StorageClient {
    pub fn new() -> Self {
        let client = Self {
            next_request_id: Arc::new(AtomicU64::new(1)),
            pending: Arc::new(Mutex::new(HashMap::new())),
        };

        client.spawn_response_router();
        client
    }

    fn spawn_response_router(&self) {
        let pending = self.pending.clone();
        spawn(async move {
            let receiver = StorageResponse::get_dart_signal_receiver();
            while let Some(pack) = receiver.recv().await {
                let request_id = pack.message.request_id;
                let tx = { pending.lock().await.remove(&request_id) };
                if let Some(tx) = tx {
                    let _ = tx.send(pack.message);
                }
            }
        });
    }

    pub async fn get_shared_pref_string(
        &self,
        key: impl Into<String>,
    ) -> Result<Option<String>, String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_SHARED_PREFERENCES,
            op: OP_GET_STRING,
            key: key.into(),
            value: None,
        })
        .await
    }

    pub async fn set_shared_pref_string(
        &self,
        key: impl Into<String>,
        value: impl Into<String>,
    ) -> Result<(), String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_SHARED_PREFERENCES,
            op: OP_SET_STRING,
            key: key.into(),
            value: Some(value.into()),
        })
        .await
        .map(|_| ())
    }

    pub async fn remove_shared_pref(&self, key: impl Into<String>) -> Result<(), String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_SHARED_PREFERENCES,
            op: OP_REMOVE,
            key: key.into(),
            value: None,
        })
        .await
        .map(|_| ())
    }

    pub async fn get_keychain_string(&self, key: impl Into<String>) -> Result<Option<String>, String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_KEYCHAIN,
            op: OP_GET_STRING,
            key: key.into(),
            value: None,
        })
        .await
    }

    pub async fn set_keychain_string(
        &self,
        key: impl Into<String>,
        value: impl Into<String>,
    ) -> Result<(), String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_KEYCHAIN,
            op: OP_SET_STRING,
            key: key.into(),
            value: Some(value.into()),
        })
        .await
        .map(|_| ())
    }

    pub async fn remove_keychain(&self, key: impl Into<String>) -> Result<(), String> {
        self.request(StorageRequest {
            request_id: self.next_id(),
            scope: SCOPE_KEYCHAIN,
            op: OP_REMOVE,
            key: key.into(),
            value: None,
        })
        .await
        .map(|_| ())
    }

    fn next_id(&self) -> u64 {
        self.next_request_id.fetch_add(1, Ordering::Relaxed)
    }

    async fn request(&self, req: StorageRequest) -> Result<Option<String>, String> {
        let request_id = req.request_id;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(request_id, tx);

        req.send_signal_to_dart();

        let resp = rx.await.map_err(|_| "Storage response channel closed".to_owned())?;
        if resp.ok {
            Ok(resp.value)
        } else {
            Err(resp
                .error
                .unwrap_or_else(|| "Storage operation failed".to_owned()))
        }
    }
}
