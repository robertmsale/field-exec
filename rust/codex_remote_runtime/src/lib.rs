mod ssh;

use tokio::spawn;

pub fn spawn_services() {
    spawn(ssh::run());
}

