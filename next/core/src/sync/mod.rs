//! One set of word totals and one dictionary across every computer John dictates on, through a
//! Supabase project. The same tables, rows and rules as both current apps, so the new app joins
//! the fleet's sync without a migration. `SYNC-PLAN.md` has the reasoning.

pub mod dictionary;
pub mod totals;

use crate::net::HttpRequest;
use crate::text::unicode::{count, has_prefix, split_at_grapheme, trim_ws, uppercased};

/// Where the shared data lives and what this computer is called there: `sync.env` in the data
/// folder, KEY=VALUE lines that `scripts/setup-sync.sh` writes. The same file and keys everywhere.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncConfig {
    pub url: String,
    pub key: String,
    pub device: String,
}

pub const FILE_NAME: &str = "sync.env";

impl SyncConfig {
    /// The old anon keys are JWTs and also go in Authorization. The publishable keys that replace
    /// them go in apikey only.
    pub fn key_is_jwt(&self) -> bool {
        self.key.starts_with("eyJ")
    }

    pub fn rest_base(&self) -> String {
        format!("{}/rest/v1", self.url)
    }

    /// What "already sent" is remembered against. A new project or a new name starts over.
    pub fn identity(&self) -> String {
        format!("{}|{}", self.url, self.device)
    }

    pub fn authorize(&self, request: HttpRequest) -> HttpRequest {
        let r = request.timeout(20).header("apikey", &self.key);
        if self.key_is_jwt() {
            r.header("Authorization", &format!("Bearer {}", self.key))
        } else {
            r
        }
    }

    /// No config and no problem when there is no file, the normal state of a computer that has not
    /// been set up; no config and a reason when the file is there but unusable.
    pub fn read(path: &std::path::Path, default_device: &str) -> (Option<SyncConfig>, Option<String>) {
        if !path.exists() {
            return (None, None);
        }
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text, default_device),
            Err(_) => (None, Some(format!("could not read {}", path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()))),
        }
    }

    pub fn parse(text: &str, default_device: &str) -> (Option<SyncConfig>, Option<String>) {
        let mut values = std::collections::HashMap::new();
        for raw in text.split(['\n', '\r', '\u{B}', '\u{C}', '\u{85}', '\u{2028}', '\u{2029}']) {
            let line = trim_ws(raw);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some(eq) = line.find('=') else { continue };
            if eq == 0 {
                continue;
            }
            let mut value = trim_ws(&line[eq + 1..]).to_string();
            let g = crate::text::unicode::graphemes(&value);
            if g.len() >= 2 && g[0] == g[g.len() - 1] && (g[0] == "\"" || g[0] == "'") {
                value = value[1..value.len() - 1].to_string();
            }
            values.insert(uppercased(trim_ws(&line[..eq])), value);
        }
        let url = values.get("SUPABASE_URL").map(|s| trim_ws(s).to_string()).unwrap_or_default();
        let key = values.get("SUPABASE_KEY").map(|s| trim_ws(s).to_string()).unwrap_or_default();
        if url.is_empty() || key.is_empty() {
            return (None, Some("sync.env needs both SUPABASE_URL and SUPABASE_KEY".into()));
        }
        let mut url = url.trim_end_matches('/').to_string();
        // The dashboard shows the project URL; a copy of the API URL with its path is the same place.
        if url.to_lowercase().ends_with("/rest/v1") {
            url.truncate(url.len() - "/rest/v1".len());
        }
        let host = url.strip_prefix("https://").map(|rest| rest.split(['/', '?', '#']).next().unwrap_or(""));
        if host.is_none_or(str::is_empty) {
            return (None, Some(format!("SUPABASE_URL is not an https address: {url}")));
        }
        // A secret key skips every row rule in the table. It must never sit in a file the app reads.
        if has_prefix(&key, "sb_secret_") {
            return (None, Some("SUPABASE_KEY is a secret key; use the project's publishable key".into()));
        }
        let mut device = values.get("DEVICE").map(|s| trim_ws(s).to_string()).unwrap_or_default();
        if device.is_empty() {
            device = default_device.to_string();
        }
        if count(&device) > 64 {
            device = split_at_grapheme(&device, 64).0.to_string();
        }
        (Some(SyncConfig { url, key, device }), None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_setup_scripts_file() {
        let (c, p) = SyncConfig::parse("# shared\r\nSUPABASE_URL = \"https://abc.supabase.co/rest/v1/\"\nsupabase_key='sb_publishable_x'\nDEVICE=DESK-01\n", "Mac");
        assert_eq!(p, None);
        let c = c.unwrap();
        assert_eq!(c.url, "https://abc.supabase.co");
        assert_eq!(c.device, "DESK-01");
        assert!(!c.key_is_jwt());
        assert_eq!(c.rest_base(), "https://abc.supabase.co/rest/v1");
    }

    #[test]
    fn refuses_what_it_must() {
        assert!(SyncConfig::parse("SUPABASE_URL=https://a.co", "Mac").1.unwrap().contains("needs both"));
        assert!(SyncConfig::parse("SUPABASE_URL=http://a.co\nSUPABASE_KEY=k", "Mac").1.unwrap().contains("not an https"));
        assert!(SyncConfig::parse("SUPABASE_URL=https://a.co\nSUPABASE_KEY=sb_secret_1", "Mac").1.unwrap().contains("secret key"));
        assert_eq!(SyncConfig::parse("SUPABASE_URL=https://a.co\nSUPABASE_KEY=eyJx", "Mac").0.unwrap().device, "Mac");
    }
}
