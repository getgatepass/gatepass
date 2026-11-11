use std::io::{BufRead, Write};

use serde_json::Value;

/// Write one JSON event line to stdout and flush immediately.
pub fn emit(value: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

/// Emit a prompt event and block until the app writes one answer line on stdin.
pub fn prompt(value: Value) -> std::io::Result<String> {
    emit(value);
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(line.trim().to_string())
}

pub fn progress(stage: &str, percent: i32) {
    emit(serde_json::json!({ "type": "progress", "stage": stage, "percent": percent }));
}

static CRITICAL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// While alive, the app hides its Stop button: stopping here could waste a certificate
/// slot or leave the account store half-written.
pub struct Critical;

impl Critical {
    pub fn enter() -> Self {
        if CRITICAL.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
            emit(serde_json::json!({ "type": "cancellable", "value": false }));
        }
        Critical
    }
}

impl Drop for Critical {
    fn drop(&mut self) {
        if CRITICAL.fetch_sub(1, std::sync::atomic::Ordering::SeqCst) == 1 {
            emit(serde_json::json!({ "type": "cancellable", "value": true }));
        }
    }
}
