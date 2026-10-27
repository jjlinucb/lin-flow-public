//! Check for updates and Update, on Windows (`linflow_core::update` has the why). Both run only on
//! John's click. Update downloads the newest release, hands the swap to PowerShell, and the app
//! quits so its files can be replaced; PowerShell opens it again either way.

use crate::Service;
use linflow_core::net::problem;
use linflow_core::update::{self, Release};
use serde::Serialize;

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    pub current: String,
    pub latest: Option<String>,
    pub published: Option<String>,
    pub newer: bool,
    pub error: Option<String>,
}

impl Service {
    fn latest_release(&self) -> Result<Release, String> {
        let request = update::latest_request();
        let result = self.ctx.net.send(&request);
        if let Some(why) = problem(&result, request.timeout_seconds) {
            return Err(format!("Could not reach GitHub: {why}"));
        }
        update::parse_release(&result.unwrap().body).ok_or_else(|| "GitHub has no Windows build to offer yet.".into())
    }

    pub fn check_update(&self) -> UpdateView {
        let current = update::current().to_string();
        match self.latest_release() {
            Ok(r) => UpdateView { newer: r.is_newer_than(&current), latest: Some(r.short().into()), published: Some(r.published.clone()), current, error: None },
            Err(e) => UpdateView { current, error: Some(e), ..UpdateView::default() },
        }
    }

    /// Downloads the newest build and starts the swap. The caller quits the app right after.
    pub fn install_update(&self) -> Result<(), String> {
        if !cfg!(windows) {
            return Err("This Mac updates from next/scripts/mac-build.sh, not from here.".into());
        }
        // Quitting closes an open meeting, and the recording is the product.
        if self.meetings.recording_id().is_some() {
            return Err("A meeting is recording. Stop it first, then update.".into());
        }
        let release = self.latest_release()?;
        if !release.is_newer_than(update::current()) {
            return Err("This is already the newest build.".into());
        }
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let dest = exe.parent().ok_or("Lin Flow's folder is unknown")?.to_path_buf();
        let temp = std::env::temp_dir();
        let zip = temp.join(update::ASSET);
        log::info!("update: downloading {} from {}", release.short(), release.zip_url);
        linflow_core::net::download(&release.zip_url, &zip, &mut |_| {}, &|| true)?;
        let script = temp.join("lin-flow-update.ps1");
        std::fs::write(&script, update::SWAP_SCRIPT).map_err(|e| e.to_string())?;
        let mut cmd = powershell(&script);
        cmd.arg("-Zip").arg(&zip).arg("-Dest").arg(&dest).arg("-ProcId").arg(std::process::id().to_string());
        cmd.spawn().map_err(|e| format!("Could not start the update: {e}"))?;
        log::info!("update: swapping to {} in {}; Lin Flow quits now", release.short(), dest.display());
        Ok(())
    }
}

/// Windows PowerShell running `script`, with no window, as Update starts the swap. Only
/// CREATE_NO_WINDOW: with DETACHED_PROCESS as well, PowerShell 5.1 exits 0 without running the
/// script, so Lin Flow quit and never came back (MBC253, 2026-10-27, the first Update of 0d2d8ab).
/// A child outlives the app on Windows without it. The test below starts it this same way.
fn powershell(script: &std::path::Path) -> std::process::Command {
    let mut cmd = std::process::Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"])
        .arg(script)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn powershell_runs_the_swap_script() {
        let dir = std::env::temp_dir().join(format!("linflow-update-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ran = dir.join("ran.txt");
        let script = dir.join("swap.ps1");
        std::fs::write(&script, format!("param([string]$Zip) Set-Content -LiteralPath '{}' -Value $Zip", ran.display())).unwrap();
        let status = super::powershell(&script).arg("-Zip").arg("a.zip").status().unwrap();
        let wrote = std::fs::read_to_string(&ran).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(status.success());
        assert_eq!(wrote.trim(), "a.zip", "PowerShell started but never ran the script");
    }
}
