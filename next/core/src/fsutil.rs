//! File writing that a crash cannot half-finish.

use std::fs;
use std::io::Write;
use std::path::Path;

/// Writes beside the target and renames over it, so a reader sees the old file or the new one,
/// never a torn one. The same as Swift's `.atomic` and the C# app's temp-and-move.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("{}.tmp-{}", path.extension().and_then(|e| e.to_str()).unwrap_or(""), std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}
