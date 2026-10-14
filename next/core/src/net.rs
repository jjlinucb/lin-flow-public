//! HTTP for the shared totals, the shared dictionary and the language models, behind a trait so
//! a test can play the server. Blocking calls: each runs on a worker thread, never the UI's.

use std::io::Read;
use std::time::Duration;

#[derive(Clone, Debug, PartialEq)]
pub struct HttpRequest {
    pub method: &'static str,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub timeout_seconds: u64,
}

impl HttpRequest {
    pub fn get(url: impl Into<String>) -> Self {
        HttpRequest { method: "GET", url: url.into(), headers: vec![], body: None, timeout_seconds: 20 }
    }

    pub fn post(url: impl Into<String>, body: Vec<u8>) -> Self {
        HttpRequest { method: "POST", url: url.into(), headers: vec![], body: Some(body), timeout_seconds: 20 }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.to_string(), value.to_string()));
        self
    }

    pub fn timeout(mut self, seconds: u64) -> Self {
        self.timeout_seconds = seconds;
        self
    }

    pub fn header_value(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum NetError {
    TimedOut,
    Other(String),
}

impl std::fmt::Display for NetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NetError::TimedOut => write!(f, "no answer in time"),
            NetError::Other(why) => write!(f, "{why}"),
        }
    }
}

pub trait Transport: Send + Sync {
    /// Any status comes back as a response; only a failure to get one is an error.
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, NetError>;
}

/// The real network: the operating system's TLS and certificate store, no cookies, no cache.
pub struct Ureq;

impl Transport for Ureq {
    fn send(&self, request: &HttpRequest) -> Result<HttpResponse, NetError> {
        let tls = native_tls::TlsConnector::new().map_err(|e| NetError::Other(e.to_string()))?;
        let agent = ureq::AgentBuilder::new()
            .tls_connector(std::sync::Arc::new(tls))
            .timeout(Duration::from_secs(request.timeout_seconds))
            .build();
        let mut req = agent.request(request.method, &request.url);
        for (k, v) in &request.headers {
            req = req.set(k, v);
        }
        let result = match &request.body {
            Some(body) => req.send_bytes(body),
            None => req.call(),
        };
        let response = match result {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(ureq::Error::Transport(t)) => {
                let text = t.to_string();
                let timed_out = text.contains("timed out") || text.contains("Timeout") || text.contains("timeout");
                return Err(if timed_out { NetError::TimedOut } else { NetError::Other(text) });
            }
        };
        let status = response.status();
        let mut body = vec![];
        response.into_reader().take(50 * 1024 * 1024).read_to_end(&mut body).map_err(|e| NetError::Other(e.to_string()))?;
        Ok(HttpResponse { status, body })
    }
}

/// None when the exchange worked; otherwise one line saying why it did not.
pub fn problem(result: &Result<HttpResponse, NetError>, timeout_seconds: u64) -> Option<String> {
    match result {
        Err(NetError::TimedOut) => Some(format!("no answer in {timeout_seconds} seconds")),
        Err(NetError::Other(why)) => Some(why.clone()),
        Ok(r) if (200..300).contains(&r.status) => None,
        Ok(r) => {
            let body = String::from_utf8_lossy(&r.body);
            let body = crate::text::unicode::trim_ws_nl(&body);
            let body = crate::text::unicode::split_at_grapheme(body, 200).0;
            Some(if body.is_empty() { format!("HTTP {}", r.status) } else { format!("HTTP {}: {}", r.status, body) })
        }
    }
}

/// Streams a large file, a speech model, to `dest`: into `<dest>.part` first and renamed only
/// once complete, so a dropped connection never leaves a truncated model that looks installed.
/// `progress` gets 0 to 1 as it goes; returning false from `keep_going` stops it.
pub fn download(url: &str, dest: &std::path::Path, progress: &mut dyn FnMut(f64), keep_going: &dyn Fn() -> bool) -> Result<(), String> {
    use std::io::Write;
    let tls = native_tls::TlsConnector::new().map_err(|e| e.to_string())?;
    let agent = ureq::AgentBuilder::new().tls_connector(std::sync::Arc::new(tls)).timeout_connect(Duration::from_secs(20)).timeout_read(Duration::from_secs(60)).build();
    let response = agent.get(url).call().map_err(|e| e.to_string())?;
    let total: Option<u64> = response.header("Content-Length").and_then(|v| v.parse().ok());
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let part = dest.with_extension("part");
    let mut file = std::fs::File::create(&part).map_err(|e| e.to_string())?;
    let mut reader = response.into_reader();
    let mut buf = vec![0u8; 1 << 20];
    let mut done: u64 = 0;
    let mut last_report = 0.0;
    loop {
        if !keep_going() {
            drop(file);
            let _ = std::fs::remove_file(&part);
            return Err("download stopped".into());
        }
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if let Some(t) = total.filter(|t| *t > 0) {
            let p = done as f64 / t as f64;
            if p - last_report >= 0.01 {
                last_report = p;
                progress(p.min(1.0));
            }
        }
    }
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);
    if let Some(t) = total {
        if done != t {
            let _ = std::fs::remove_file(&part);
            return Err(format!("the download stopped at {done} of {t} bytes"));
        }
    }
    std::fs::rename(&part, dest).map_err(|e| e.to_string())?;
    progress(1.0);
    Ok(())
}
