//! Windows updates on a click (John, 2026-10-27: "build it in the app to just pull the latest
//! version, and I'll give them the updates by clicking on it themselves"). Nothing checks or
//! installs by itself: the fleet stays manual (2026-10-09). CI publishes each green build of `main`
//! as the `windows-latest` release of the public repo (`windows-app` in .github/workflows/next.yml),
//! so a laptop needs no GitHub sign-in to fetch it. The Mac's app is signed with an identity only
//! the Mac has, so the Mac keeps updating through `next/scripts/mac-build.sh --install`.

use crate::net::HttpRequest;
use serde_json::Value;

pub const REPO: &str = "jjlinucb/lin-flow-public";
pub const TAG: &str = "windows-latest";
pub const ASSET: &str = "lin-flow-windows.zip";

/// The commit this build came from, short, or empty outside a git checkout.
pub fn current() -> &'static str {
    option_env!("LINFLOW_COMMIT").unwrap_or("")
}

#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    /// The full commit the release was built from.
    pub commit: String,
    pub published: String,
    pub zip_url: String,
}

impl Release {
    pub fn short(&self) -> &str {
        &self.commit[..self.commit.len().min(7)]
    }

    /// Whether this build is older than the release. A build that does not know its commit
    /// always is, so it can still update.
    pub fn is_newer_than(&self, current: &str) -> bool {
        current.is_empty() || !self.commit.starts_with(current)
    }
}

pub fn latest_request() -> HttpRequest {
    HttpRequest::get(format!("https://api.github.com/repos/{REPO}/releases/tags/{TAG}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "lin-flow")
}

/// The release's commit, date and zip, or None when the answer is not a release with the zip.
pub fn parse_release(body: &[u8]) -> Option<Release> {
    let v: Value = serde_json::from_slice(body).ok()?;
    let commit = v.get("target_commitish")?.as_str()?.trim();
    // A branch name is no commit to compare with; CI always targets the commit itself.
    if commit.len() < 7 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let zip_url = v.get("assets")?.as_array()?.iter().find(|a| a.get("name").and_then(Value::as_str) == Some(ASSET))?
        .get("browser_download_url")?.as_str()?;
    if !zip_url.starts_with(&format!("https://github.com/{REPO}/releases/download/")) {
        return None;
    }
    let published = v.get("published_at").and_then(Value::as_str).unwrap_or("").get(..10).unwrap_or("").to_string();
    Some(Release { commit: commit.to_lowercase(), published, zip_url: zip_url.to_string() })
}

/// Run by PowerShell once the app has quit: unpack the zip, check the new copy starts, swap the
/// folders, and open Lin Flow again. A failure at any step keeps the old copy and opens it, and
/// every step is logged to `lin-flow-update.log` in TEMP.
pub const SWAP_SCRIPT: &str = include_str!("../../scripts/update-swap.ps1");

#[cfg(test)]
mod tests {
    use super::*;

    fn release(commit: &str, asset: &str, url: &str) -> Vec<u8> {
        serde_json::json!({
            "tag_name": TAG, "target_commitish": commit, "published_at": "2026-10-27T19:23:37Z",
            "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/x"},
                       {"name": asset, "browser_download_url": url}]
        })
        .to_string()
        .into_bytes()
    }

    const URL: &str = "https://github.com/jjlinucb/lin-flow-public/releases/download/windows-latest/lin-flow-windows.zip";

    #[test]
    fn reads_the_release_and_compares_commits() {
        let r = parse_release(&release("b0168ec1234567890abcdef1234567890abcdef0", ASSET, URL)).unwrap();
        assert_eq!((r.short(), r.published.as_str(), r.zip_url.as_str()), ("b0168ec", "2026-10-27", URL));
        assert!(!r.is_newer_than("b0168ec"));
        assert!(!r.is_newer_than("b0168ec12"));
        assert!(r.is_newer_than("caafe1d"));
        assert!(r.is_newer_than(""));
    }

    #[test]
    fn refuses_what_is_not_this_repos_zip() {
        assert_eq!(parse_release(&release("main", ASSET, URL)), None);
        assert_eq!(parse_release(&release("b0168ec1234", "other.zip", URL)), None);
        assert_eq!(parse_release(&release("b0168ec1234", ASSET, "https://evil.example/lin-flow-windows.zip")), None);
        assert_eq!(parse_release(b"{\"message\": \"Not Found\"}"), None);
        assert_eq!(parse_release(b"not json"), None);
    }

    #[test]
    fn asks_github_without_a_sign_in() {
        let r = latest_request();
        assert_eq!(r.url, "https://api.github.com/repos/jjlinucb/lin-flow-public/releases/tags/windows-latest");
        assert!(r.header_value("User-Agent").is_some() && r.header_value("Authorization").is_none());
    }
}
