// Stamps the commit this build came from: `linflow version`, and the Windows app's Check for updates,
// which compares it with the newest release. Outside a git checkout it
// says so instead.
fn main() {
    let commit = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    if let Some(c) = commit {
        println!("cargo:rustc-env=LINFLOW_COMMIT={c}");
    }
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/refs/heads");
}
