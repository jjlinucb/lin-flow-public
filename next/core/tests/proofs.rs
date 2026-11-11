//! Has Lean check every proof in `next/proofs/`, and checks that `next/proofs/vectors.json` is
//! what the proved models answer today. Where Lean is not installed (the Windows runner, a cloud
//! session) it says so and passes, unless `LINFLOW_REQUIRE_LEAN` is set, as CI's Linux job sets
//! it. `next/proofs/README.md` lists the promises.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Lake, asked from the proofs folder so elan reads its `lean-toolchain`.
fn lake(dir: &Path) -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(|h| Path::new(&h).join(".elan/bin/lake"));
    home.into_iter()
        .chain([PathBuf::from("lake")])
        .find(|p| Command::new(p).arg("--version").current_dir(dir).output().is_ok_and(|o| o.status.success()))
}

#[test]
fn the_lean_proofs_hold() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../proofs");
    let Some(lake) = lake(&dir) else {
        assert!(std::env::var_os("LINFLOW_REQUIRE_LEAN").is_none(), "LINFLOW_REQUIRE_LEAN is set and Lean is not installed");
        eprintln!("Lean is not installed here, so the proofs in next/proofs were not rechecked.");
        return;
    };
    // `sorry` is an error through the lakefile; an axiom would prove anything, so none may appear.
    for f in std::fs::read_dir(dir.join("LinFlow")).unwrap() {
        let text = std::fs::read_to_string(f.unwrap().path()).unwrap();
        assert!(!text.lines().any(|l| l.trim_start().starts_with("axiom ")), "an axiom in next/proofs/LinFlow");
    }
    let path = format!("{}:{}", lake.parent().unwrap_or(Path::new("")).display(), std::env::var("PATH").unwrap_or_default());
    let build = Command::new(&lake).arg("build").current_dir(&dir).env("PATH", &path).output().unwrap();
    assert!(build.status.success(), "A Lean proof failed: one of the promises in next/proofs no longer holds.\n{}{}",
        String::from_utf8_lossy(&build.stdout), String::from_utf8_lossy(&build.stderr));
    let run = Command::new(&lake).args(["env", "lean", "--run", "Vectors.lean"]).current_dir(&dir).env("PATH", &path).output().unwrap();
    assert!(run.status.success(), "{}", String::from_utf8_lossy(&run.stderr));
    let file = dir.join("vectors.json");
    if std::fs::read(&file).ok().as_deref() != Some(&run.stdout[..]) {
        std::fs::write(&file, &run.stdout).unwrap();
        panic!("next/proofs/vectors.json was out of date with the models; it is rewritten now, so commit it.");
    }
}
