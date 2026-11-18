use cloudflare_quick_tunnel::{QuickTunnelHandle, QuickTunnelManager};
use std::ffi::c_char;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::runtime::Runtime;

type State = Option<Result<QuickTunnelHandle, ()>>;

pub struct NxGameTunnel {
    runtime: Runtime,
    state: Arc<Mutex<State>>,
}

#[unsafe(no_mangle)]
pub extern "C" fn nx_game_tunnel_start(port: u16) -> *mut NxGameTunnel {
    if port == 0 {
        return std::ptr::null_mut();
    }
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
    else {
        return std::ptr::null_mut();
    };
    let state = Arc::new(Mutex::new(None));
    let result = state.clone();
    runtime.spawn(async move {
        // A single connection keeps the mobile session small. Errors can contain
        // service responses, so do not expose them or credentials to the UI/log.
        let tunnel = QuickTunnelManager::new(port)
            .with_ha_connections(1)
            .start()
            .await
            .map_err(|_| ());
        *result.lock().unwrap() = Some(tunnel);
    });
    Box::into_raw(Box::new(NxGameTunnel { runtime, state }))
}

/// # Safety
/// Handle must be live, buffer writable for capacity bytes, and calls serialized.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nx_game_tunnel_poll(
    handle: *const NxGameTunnel,
    text: *mut c_char,
    capacity: usize,
) -> i32 {
    if handle.is_null() || text.is_null() || capacity == 0 {
        return -2;
    }
    let state = unsafe { &*handle }.state.lock().unwrap();
    let (status, value) = match state.as_ref() {
        None => (0, ""),
        Some(Ok(tunnel)) => (1, tunnel.url.as_str()),
        Some(Err(())) => (-1, ""),
    };
    if value.len() >= capacity {
        unsafe { *text = 0 };
        return -2;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(value.as_ptr(), text.cast(), value.len());
        *text.add(value.len()) = 0;
    }
    status
}

/// # Safety
/// Consumes a live handle exactly once, after all poll calls finish. Worker only.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nx_game_tunnel_stop(handle: *mut NxGameTunnel) {
    if handle.is_null() {
        return;
    }
    let NxGameTunnel { runtime, state } = *unsafe { Box::from_raw(handle) };
    let handle = state.lock().unwrap().take();
    // Cancel, do not drain, an ephemeral sharing session. Keep the handle alive
    // until reactors are cancelled so its Notify cannot start a 30s graceful RPC.
    runtime.shutdown_timeout(Duration::from_secs(2));
    drop(handle);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stopped_session_cancels_pending_work_without_network() {
        let runtime = Runtime::new().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        runtime.spawn(async move {
            struct Finished(std::sync::mpsc::Sender<()>);
            impl Drop for Finished {
                fn drop(&mut self) {
                    let _ = self.0.send(());
                }
            }
            let _finished = Finished(tx);
            ready_tx.send(()).unwrap();
            std::future::pending::<()>().await;
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let handle = Box::into_raw(Box::new(NxGameTunnel {
            runtime,
            state: Arc::new(Mutex::new(Some(Err(())))),
        }));
        let mut text = [0_i8; 128];
        assert_eq!(
            unsafe { nx_game_tunnel_poll(handle, text.as_mut_ptr(), text.len()) },
            -1
        );
        assert_eq!(
            unsafe { nx_game_tunnel_poll(handle, text.as_mut_ptr(), 0) },
            -2
        );
        unsafe { nx_game_tunnel_stop(handle) };
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(nx_game_tunnel_start(0).is_null());
    }
}
