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
        let release = self.latest_release()?;
        if !release.is_newer_than(update::current()) {
            return Err("This is already the newest build.".into());
        }
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let dest = exe.parent().ok_or("Lin Flow Next's folder is unknown")?.to_path_buf();
        let temp = std::env::temp_dir();
        let zip = temp.join(update::ASSET);
        log::info!("update: downloading {} from {}", release.short(), release.zip_url);
        linflow_core::net::download(&release.zip_url, &zip, &mut |_| {}, &|| true)?;
        let script = temp.join("lin-flow-next-update.ps1");
        std::fs::write(&script, update::SWAP_SCRIPT).map_err(|e| e.to_string())?;
        let mut cmd = std::process::Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File"])
            .arg(&script)
            .arg("-Zip")
            .arg(&zip)
            .arg("-Dest")
            .arg(&dest)
            .arg("-ProcId")
            .arg(std::process::id().to_string());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            // No console window, and not a child the app's exit takes down with it.
            cmd.creation_flags(0x0800_0000 | 0x0000_0008);
        }
        cmd.spawn().map_err(|e| format!("Could not start the update: {e}"))?;
        log::info!("update: swapping to {} in {}; Lin Flow Next quits now", release.short(), dest.display());
        Ok(())
    }
}
