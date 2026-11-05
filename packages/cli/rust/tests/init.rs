use std::{
    fs,
    os::unix::fs::{symlink, PermissionsExt},
    process::Command,
};

fn root() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "moss-init-test-{}-{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("unnamed")
    ));
    fs::create_dir(&dir).unwrap();
    assert!(Command::new("git")
        .arg("init")
        .arg("-q")
        .arg(&dir)
        .status()
        .unwrap()
        .success());
    dir
}

fn moss(dir: &std::path::Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_moss-rust-preview"))
        .arg("init")
        .current_dir(dir)
        .output()
        .unwrap()
}

#[test]
fn init_is_local_and_idempotent() {
    let dir = root();
    let first = moss(&dir);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    assert_eq!(
        fs::metadata(dir.join(".moss"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert!(moss(&dir).status.success());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn init_refuses_linked_and_world_readable_stores() {
    let dir = root();
    let other = dir.join("other");
    fs::create_dir(&other).unwrap();
    symlink(&other, dir.join(".moss")).unwrap();
    assert!(!moss(&dir).status.success());
    fs::remove_file(dir.join(".moss")).unwrap();
    fs::create_dir(dir.join(".moss")).unwrap();
    fs::set_permissions(dir.join(".moss"), fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!moss(&dir).status.success());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn init_guides_unignored_git_checkouts() {
    let dir = root();
    let result = moss(&dir);
    assert!(result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("add .moss/"));
    fs::remove_dir_all(dir).unwrap();
}
