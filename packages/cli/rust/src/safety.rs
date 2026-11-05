//! Shared filesystem, Git, SSH, and plan safety gates. Operator files never
//! enter the Nix store. All target commands fail closed on unexpected state.
use fs2::FileExt;
use serde::{de::DeserializeOwned, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
pub fn err(message: impl Into<String>) -> Box<dyn std::error::Error> {
    message.into().into()
}
pub fn ensure(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(err(message))
    }
}
pub fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}
pub fn file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file())
}
pub fn dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_dir())
}
pub fn mode(path: &Path) -> Result<u32> {
    Ok(fs::symlink_metadata(path)?.permissions().mode() & 0o7777)
}
pub fn unlinked(path: &Path) -> Result<()> {
    let mut part = PathBuf::new();
    for component in path.components() {
        part.push(component);
        if fs::symlink_metadata(&part).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(err(format!("linked path: {}", part.display())));
        }
    }
    Ok(())
}
pub fn private(path: &Path) -> Result<()> {
    ensure(
        path.is_absolute() && !path.components().any(|c| c.as_os_str() == ".."),
        "private file must have an absolute path without traversal",
    )?;
    ensure(
        file(path) && mode(path)? == 0o600,
        &format!("expected mode-600 private file: {}", path.display()),
    )?;
    unlinked(path)
}
pub fn private_dir(path: &Path) -> Result<()> {
    ensure(
        dir(path) && mode(path)? == 0o700,
        &format!("expected mode-700 directory: {}", path.display()),
    )?;
    unlinked(path)
}
pub fn create_private_dir(path: &Path) -> Result<()> {
    if !exists(path) {
        fs::create_dir(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    private_dir(path)
}
pub fn write_new(path: &Path, content: &[u8]) -> Result<()> {
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    out.write_all(content)?;
    out.sync_all()?;
    Ok(())
}
pub fn atomic(path: &Path, content: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| err("missing parent"))?;
    let mut staged = tempfile::NamedTempFile::new_in(dir)?;
    staged
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    staged.write_all(content)?;
    staged.as_file().sync_all()?;
    staged.persist(path)?;
    Ok(())
}
pub fn json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    write_new(path, &serde_json::to_vec_pretty(value)?)
}
pub fn hash(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut chunk = [0u8; 8192];
    loop {
        let n = file.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        hash.update(&chunk[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn run(command: &mut Command) -> Result<String> {
    let result = command.output()?;
    ensure(
        result.status.success(),
        &format!(
            "{} failed: {}",
            command.get_program().to_string_lossy(),
            String::from_utf8_lossy(&result.stderr)
        ),
    )?;
    Ok(String::from_utf8(result.stdout)?)
}
pub fn status(command: &mut Command) -> Result<()> {
    let result = command.status()?;
    ensure(
        result.success(),
        &format!(
            "{} failed ({result})",
            command.get_program().to_string_lossy()
        ),
    )
}
pub fn input(command: &mut Command, content: &[u8]) -> Result<String> {
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| err("missing child stdin"))?
        .write_all(content)?;
    let output = child.wait_with_output()?;
    ensure(
        output.status.success(),
        &format!(
            "{} failed: {}",
            command.get_program().to_string_lossy(),
            String::from_utf8_lossy(&output.stderr)
        ),
    )?;
    Ok(String::from_utf8(output.stdout)?)
}
pub fn git(repo: &Path, args: &[&str]) -> Result<String> {
    run(Command::new("git").arg("-C").arg(repo).args(args))
}
pub fn git_ok(repo: &Path, args: &[&str]) -> Result<bool> {
    Ok(Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()?
        .status
        .success())
}
pub fn root_target(s: &str) -> bool {
    s.strip_prefix("root@").is_some_and(|host| {
        !host.is_empty()
            && host
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.:-".contains(&c))
    })
}
pub fn host(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
}
pub fn branch(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.contains("..")
        && !s.contains("//")
        && !s.ends_with('/')
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_/-".contains(&c))
        && git_ok(
            Path::new("."),
            &["check-ref-format", &format!("refs/heads/{s}")],
        )
        .unwrap_or(false)
}
pub fn hex(s: &str, len: usize) -> bool {
    s.len() == len
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
pub fn reference(s: &str) -> bool {
    s.strip_prefix("commit:").is_some_and(|s| hex(s, 40))
        || s.strip_prefix("branch:").is_some_and(branch)
}
pub fn remote_path(s: &str) -> bool {
    s.starts_with('/')
        && !s.contains("..")
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_./-".contains(&c))
}
pub fn disk_path(s: &str) -> bool {
    s.starts_with("/dev/")
        && !s.contains("..")
        && s.bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_./-".contains(&c))
}
pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
pub fn ssh(target: &str, command: &str) -> Result<String> {
    ensure(root_target(target), "invalid root SSH target")?;
    run(Command::new("ssh").args(["-o", "StrictHostKeyChecking=yes", target, command]))
}
pub fn ssh_input(target: &str, command: &str, content: &[u8]) -> Result<String> {
    ensure(root_target(target), "invalid root SSH target")?;
    input(
        Command::new("ssh").args(["-o", "StrictHostKeyChecking=yes", target, command]),
        content,
    )
}
pub fn pushed_tip(repo: &Path, name: &str) -> Result<String> {
    ensure(branch(name), "invalid branch")?;
    let result = git(
        repo,
        &[
            "ls-remote",
            "--exit-code",
            "origin",
            &format!("refs/heads/{name}"),
        ],
    )?;
    Ok(result
        .split_whitespace()
        .next()
        .ok_or_else(|| err("empty branch tip"))?
        .to_owned())
}
pub fn verify_tip(repo: &Path, name: &str, expected: &str) -> Result<()> {
    ensure(
        pushed_tip(repo, name)? == expected,
        "branch tip changed during deployment; retry",
    )
}
pub fn workspace() -> Result<PathBuf> {
    let cwd = std::env::current_dir()?;
    let root = git(&cwd, &["rev-parse", "--show-toplevel"])
        .ok()
        .map(|s| PathBuf::from(s.trim()))
        .unwrap_or(cwd);
    ensure(dir(&root), "unsafe operator directory")?;
    unlinked(&root)?;
    Ok(root)
}
pub fn check_store(root: &Path) -> Result<()> {
    let store = root.join(".moss");
    if exists(&store) {
        private_dir(&store)?;
    }
    if git_ok(root, &["rev-parse", "--show-toplevel"])? {
        ensure(
            git(root, &["ls-files", "--", ".moss"])?.is_empty(),
            "tracked .moss files; remove them from Git",
        )?;
        ensure(
            git_ok(root, &["check-ignore", "-q", "--no-index", "--", ".moss/"])?,
            "add .moss/ to .gitignore and commit before planning",
        )?;
    }
    Ok(())
}
pub fn operator_path(path: &Path) -> Result<()> {
    let root = workspace()?;
    check_store(&root)?;
    ensure(
        path.is_absolute() && !path.components().any(|c| c.as_os_str() == ".."),
        "operator path must be absolute without traversal",
    )?;
    let parent = path.parent().ok_or_else(|| err("missing parent"))?;
    ensure(dir(parent), "invalid parent")?;
    unlinked(parent)?;
    if let Ok(repo_str) = git(parent, &["rev-parse", "--show-toplevel"]) {
        let repo = PathBuf::from(repo_str.trim());
        check_store(&repo)?;
        let relative = path
            .strip_prefix(&repo)
            .map_err(|_| err("operator file outside detected Git root"))?;
        let rel = relative.to_string_lossy();
        ensure(
            git(&repo, &["ls-files", "--", &rel])?.is_empty(),
            "tracked operator file",
        )?;
        ensure(
            git_ok(&repo, &["check-ignore", "-q", "--no-index", "--", &rel])?,
            "operator file must be Git-ignored",
        )?;
    }
    Ok(())
}
pub fn state_lock(state: &Path) -> Result<(File, String, String)> {
    private_dir(state)?;
    let test = std::env::var("THEMOSS_TEST_ROOT").as_deref() == Ok("1");
    ensure(unsafe { libc::geteuid() } == 0 || test, "root required")?;
    ensure(
        fs::metadata(state)?.uid() == 0 || test,
        "state must be root-owned",
    )?;
    let lock = state.join("lock");
    ensure(!exists(&lock) || file(&lock), "linked lock")?;
    let lock_file = OpenOptions::new()
        .create(true)
        .write(true)
        .mode(0o600)
        .open(&lock)?;
    lock_file.try_lock_exclusive()?;
    ensure(
        !exists(&state.join("needs-inspection")),
        "switch outcome requires operator inspection",
    )?;
    ensure(file(&state.join("revision")), "missing known-good revision")?;
    let revision = fs::read_to_string(state.join("revision"))?
        .trim()
        .to_owned();
    ensure(hex(&revision, 40), "invalid known-good revision")?;
    private(&state.join("selector"))?;
    ensure(
        fs::metadata(state.join("selector"))?.uid() == 0 || test,
        "selector must be root-owned",
    )?;
    let selected = fs::read_to_string(state.join("selector"))?
        .trim()
        .to_owned();
    ensure(reference(&selected), "invalid selector")?;
    Ok((lock_file, revision, selected))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disallow_unsafe_target_arguments() {
        assert!(root_target("root@example"));
        assert!(!root_target("user@example;rm -rf /"));
        assert!(branch("main"));
        assert!(!branch("../main"));
        assert!(!remote_path("/tmp/../bad"));
        assert!(!disk_path("/dev/../vda"));
    }
}
