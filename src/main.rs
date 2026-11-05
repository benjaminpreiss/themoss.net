use clap::{CommandFactory, Parser, Subcommand};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn error(message: impl Into<String>) -> Box<dyn std::error::Error> {
    message.into().into()
}

/// Deploy and update a consumer-owned NixOS machine. Never use install to repair a host.
#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Action,
}
#[derive(Subcommand)]
enum Action {
    /// Record the target's hardware and selected whole disk (no changes to target).
    Discover {
        /// Verified rescue-environment SSH target (e.g. root@HOST).
        target: String,
        /// Whole-disk path, checked against lsblk (e.g. /dev/vda).
        disk: String,
        /// New private JSON record path (created mode 0600).
        record: PathBuf,
    },
    /// Recheck a private discovery record against the live target.
    Preflight {
        /// Private JSON record from discover.
        record: PathBuf,
    },
    /// Build a pushed commit and, after typed confirmation, erase the selected disk.
    Install {
        /// Discovery record, rechecked before build and before disk erase.
        record: PathBuf,
        /// Clean consumer Git checkout.
        repo: PathBuf,
        /// Full 40-character pushed commit ID.
        rev: String,
        /// Private credential-free machine.nix directory.
        machine: PathBuf,
        /// NixOS flake output name.
        host: String,
        /// Pushed branch whose head must equal REV.
        branch: String,
        /// New off-host install receipt path (created mode 0600).
        receipt: PathBuf,
    },
    /// Seed the installed host with its exact installed commit and private machine facts.
    Bootstrap {
        /// Off-host install receipt.
        receipt: PathBuf,
        /// Local consumer Git checkout with matching origin and commit.
        repo: PathBuf,
        /// Local installed machine.nix directory.
        machine: PathBuf,
        /// Absolute target-side checkout path.
        remote_checkout: String,
        /// Absolute target-side private machine directory.
        remote_machine: String,
        /// Absolute target-side state directory.
        remote_state: String,
    },
    /// Fetch a descendant commit, build and switch; never partitions a disk.
    Update {
        /// Target-side consumer Git checkout.
        repo: PathBuf,
        /// Reviewed upstream branch.
        branch: String,
        /// Target-side private machine directory.
        machine: PathBuf,
        /// NixOS flake output name.
        host: String,
        /// Target-side state directory containing revision.
        state: PathBuf,
        #[arg(hide = true)]
        reviewed: Option<PathBuf>,
        #[arg(hide = true)]
        expected_rev: Option<String>,
        #[arg(hide = true)]
        expected_sha: Option<String>,
    },
    /// Move an installed candidate to a reviewed branch with a reviewed machine file.
    Transition {
        /// Off-host candidate install receipt.
        receipt: PathBuf,
        /// Installed SSH target (must match receipt).
        target: String,
        /// Absolute target-side consumer checkout path.
        remote_checkout: String,
        /// Reviewed descendant branch.
        branch: String,
        /// Local directory with reviewed credential-free machine.nix.
        new_machine: PathBuf,
        /// Absolute target-side private machine directory.
        remote_machine: String,
        /// NixOS flake output name.
        host: String,
        /// Absolute target-side state directory.
        remote_state: String,
    },
    #[command(hide = true)]
    PrepareTransition {
        repo: PathBuf,
        machine: PathBuf,
        state: PathBuf,
        rev: String,
        sha: String,
    },
    #[command(hide = true)]
    BootstrapRemote {
        phase: String,
        url: String,
        rev: String,
        repo: PathBuf,
        machine: PathBuf,
        state: PathBuf,
        branch: String,
    },
    /// Generate the Markdown CLI reference from clap; CI checks it has not drifted.
    #[command(hide = true)]
    GenerateDocs { output: PathBuf },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Disk {
    path: String,
    #[serde(rename = "type")]
    kind: String,
    size: u64,
    model: Option<String>,
    serial: Option<String>,
}
#[derive(Debug, Serialize, Deserialize)]
struct Record {
    target: String,
    arch: String,
    boot: String,
    nic: String,
    mac: String,
    disk: Disk,
}
#[derive(Debug, Deserialize)]
struct Probe {
    arch: String,
    boot: String,
    nic: String,
    mac: String,
    disks: Vec<Disk>,
}
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    target: String,
    revision: String,
    branch: String,
    origin: String,
    machine_sha256: String,
    facter_sha256: String,
}

fn run(cmd: &mut Command) -> Result<String> {
    let output = cmd.output()?;
    if !output.status.success() {
        return Err(error(format!(
            "{} failed ({}): {}",
            cmd.get_program().to_string_lossy(),
            output.status,
            String::from_utf8_lossy(&output.stderr)
        )));
    }
    Ok(String::from_utf8(output.stdout)?)
}
fn run_status(cmd: &mut Command) -> Result<()> {
    let status = cmd.status()?;
    ensure(
        status.success(),
        &format!("{} failed ({status})", cmd.get_program().to_string_lossy()),
    )
}
fn run_input(cmd: &mut Command, input: &[u8]) -> Result<String> {
    let mut child = cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| error("missing child stdin"))?
        .write_all(input)?;
    let out = child.wait_with_output()?;
    if !out.status.success() {
        return Err(error(format!(
            "{} failed ({}): {}",
            cmd.get_program().to_string_lossy(),
            out.status,
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    Ok(String::from_utf8(out.stdout)?)
}
fn git(repo: &Path, args: &[&str]) -> Result<String> {
    run(Command::new("git").arg("-C").arg(repo).args(args))
}
fn ssh(target: &str, args: &[&str]) -> Result<String> {
    // OpenSSH uses the user's previously verified known_hosts, never accept-new.
    let command = args
        .iter()
        .map(|s| shell_quote(s))
        .collect::<Vec<_>>()
        .join(" ");
    run(Command::new("ssh").args(["-o", "StrictHostKeyChecking=yes", target, &command]))
}
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
fn valid_hex(s: &str, n: usize) -> bool {
    s.len() == n
        && s.bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn valid_branch(s: &str) -> bool {
    !s.is_empty()
        && !s.contains("..")
        && !s.starts_with('-')
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_/-".contains(&b))
}
fn valid_host(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
}
fn remote_path(s: &str) -> bool {
    s.starts_with('/')
        && !s.contains("..")
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_./-".contains(&b))
}
fn root_target(s: &str) -> bool {
    s.strip_prefix("root@").is_some_and(|v| {
        !v.is_empty()
            && v.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
    })
}
fn ensure(ok: bool, message: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(error(message))
    }
}
fn mode(path: &Path) -> Result<u32> {
    Ok(fs::symlink_metadata(path)?.permissions().mode() & 0o7777)
}
fn regular(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_file())
}
fn directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_dir())
}
fn absent(path: &Path) -> bool {
    fs::symlink_metadata(path).is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
}
fn private_file(path: &Path) -> Result<()> {
    ensure(
        regular(path) && mode(path)? == 0o600,
        &format!("missing or unsafe private file: {}", path.display()),
    )
}
fn write_new(path: &Path, data: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(data)?;
    file.sync_all()?;
    Ok(())
}
fn atomic(path: &Path, data: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    if !absent(&tmp) {
        ensure(regular(&tmp), "unsafe temporary file")?;
        fs::remove_file(&tmp)?; // Interrupted writes are disposable; destination is not.
    }
    write_new(&tmp, data)?;
    fs::rename(tmp, path)?;
    Ok(())
}
fn hash(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 8192];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(format!("{:x}", h.finalize()))
}
fn json_file<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
const PROBE_SCRIPT: &str = "set -euo pipefail\nuname -m\nif [[ -d /sys/firmware/efi ]]; then echo uefi; else echo bios; fi\nip -j route show default\nlsblk -J -d -b -o PATH,TYPE,SIZE,MODEL,SERIAL\n";
fn live_probe(target: &str) -> Result<Probe> {
    ensure(root_target(target), "expected root@HOST SSH target")?;
    let raw = run_input(
        Command::new("ssh").args(["-o", "StrictHostKeyChecking=yes", target, "bash -s"]),
        PROBE_SCRIPT.as_bytes(),
    )?;
    // Parse the same probe output but avoid a second remote probe: replace probe's
    // SSH call with a parser below.
    parse_probe(target, &raw)
}
fn parse_probe(target: &str, raw: &str) -> Result<Probe> {
    let mut lines = raw.lines();
    let arch = lines
        .next()
        .ok_or_else(|| error("missing architecture"))?
        .to_owned();
    let boot = lines
        .next()
        .ok_or_else(|| error("missing boot mode"))?
        .to_owned();
    let routes: serde_json::Value =
        serde_json::from_str(lines.next().ok_or_else(|| error("missing routes"))?)?;
    let routes = routes.as_array().ok_or_else(|| error("invalid routes"))?;
    ensure(routes.len() == 1, "ambiguous default route")?;
    let nic = routes[0]["dev"]
        .as_str()
        .ok_or_else(|| error("missing NIC"))?
        .to_owned();
    ensure(
        !nic.is_empty()
            && nic
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b)),
        "invalid NIC",
    )?;
    let block: serde_json::Value = serde_json::from_str(&lines.collect::<Vec<_>>().join("\n"))?;
    let disks: Vec<Disk> = serde_json::from_value(serde_json::Value::Array(
        block["blockdevices"]
            .as_array()
            .ok_or_else(|| error("invalid disks"))?
            .iter()
            .filter(|v| v["type"] == "disk")
            .cloned()
            .collect(),
    ))?;
    let mac = ssh(target, &["cat", &format!("/sys/class/net/{nic}/address")])?
        .trim()
        .to_owned();
    Ok(Probe {
        arch,
        boot,
        nic,
        mac,
        disks,
    })
}
fn check(path: &Path) -> Result<Record> {
    private_file(path)?;
    let record: Record = json_file(path)?;
    let p = live_probe(&record.target)?;
    ensure(
        record.arch == p.arch
            && record.boot == p.boot
            && record.nic == p.nic
            && record.mac == p.mac,
        "target architecture, boot, NIC/MAC changed",
    )?;
    ensure(
        p.disks
            .iter()
            .filter(|d| {
                d.path == record.disk.path
                    && d.kind == "disk"
                    && d.size == record.disk.size
                    && d.model == record.disk.model
                    && d.serial == record.disk.serial
            })
            .count()
            == 1,
        "whole-disk identity changed",
    )?;
    println!(
        "Target: {}; arch={} boot={} NIC={} MAC={}",
        record.target, record.arch, record.boot, record.nic, record.mac
    );
    println!(
        "WHOLE DISK TO ERASE: {}; size={} model={} serial={}",
        record.disk.path,
        record.disk.size,
        record.disk.model.as_deref().unwrap_or("null"),
        record.disk.serial.as_deref().unwrap_or("null")
    );
    Ok(record)
}
fn stage(repo: &Path, rev: &str, machine: &Path, dest: &Path) -> Result<()> {
    ensure(
        directory(machine) && regular(&machine.join("machine.nix")),
        "missing private machine.nix",
    )?;
    let tree = git(repo, &["ls-tree", "-r", rev])?;
    ensure(
        !tree.lines().any(|line| line.starts_with("120000 ")),
        "linked source in commit",
    )?;
    // Keep large consumer archives on disk, not in the CLI's address space.
    let archive = tempfile::NamedTempFile::new()?;
    let status = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["archive", "--format=tar", rev])
        .stdout(archive.reopen()?)
        .status()?;
    ensure(status.success(), "git archive failed")?;
    let listing = run(Command::new("tar").arg("-tf").arg(archive.path()))?;
    ensure(
        listing
            .lines()
            .all(|p| !p.starts_with('/') && !p.split('/').any(|c| c == "..")),
        "unsafe archive path",
    )?;
    run(Command::new("tar")
        .arg("-xf")
        .arg(archive.path())
        .arg("-C")
        .arg(dest)
        .arg("--no-same-owner"))?;
    ensure(
        regular(&dest.join("flake.lock")) && absent(&dest.join("generated")),
        "committed lock required; generated/ must not be committed",
    )?;
    let links = run(Command::new("find")
        .arg(dest)
        .args(["-type", "l", "-print", "-quit"]))?;
    ensure(links.is_empty(), "linked source in archive")?;
    fs::create_dir(dest.join("generated"))?;
    fs::set_permissions(dest.join("generated"), fs::Permissions::from_mode(0o700))?;
    fs::copy(
        machine.join("machine.nix"),
        dest.join("generated/machine.nix"),
    )?;
    if !absent(&machine.join("facter.json")) {
        ensure(
            regular(&machine.join("facter.json")),
            "linked facter report",
        )?;
        fs::copy(
            machine.join("facter.json"),
            dest.join("generated/facter.json"),
        )?;
    }
    Ok(())
}
fn build(dest: &Path, host: &str) -> Result<()> {
    ensure(valid_host(host), "invalid host")?;
    run_status(
        Command::new("nix")
            .args(["build", "--no-link", "--no-write-lock-file"])
            .arg(format!(
                "{}#nixosConfigurations.{host}.config.system.build.toplevel",
                dest.display()
            )),
    )
}
fn receipt(path: &Path) -> Result<Receipt> {
    private_file(path)?;
    json_file(path)
}
fn lock(state: &Path, name: &str) -> Result<File> {
    ensure(!state.is_symlink(), "linked state")?;
    fs::create_dir_all(state)?;
    fs::set_permissions(state, fs::Permissions::from_mode(0o700))?;
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .mode(0o600)
        .open(state.join(name))?;
    file.try_lock_exclusive()?;
    Ok(file)
}
fn revision(state: &Path) -> Result<String> {
    let path = state.join("revision");
    ensure(regular(&path), "missing known-good revision")?;
    let v = fs::read_to_string(path)?.trim().to_owned();
    ensure(valid_hex(&v, 40), "invalid known-good revision")?;
    Ok(v)
}
fn update(
    repo: &Path,
    branch: &str,
    machine: &Path,
    host: &str,
    state: &Path,
    reviewed: Option<&Path>,
    baseline: Option<(&str, &str)>,
) -> Result<()> {
    ensure(valid_branch(branch), "invalid branch")?;
    let _guard = lock(state, "lock")?;
    let current = revision(state)?;
    if let Some(r) = reviewed {
        let (rev, sha) = baseline.ok_or_else(|| error("missing transition baseline"))?;
        ensure(
            rev == current
                && valid_hex(sha, 64)
                && r == state.join("transition-incoming/machine.nix"),
            "invalid transition baseline",
        )?;
        ensure(
            regular(r)
                && regular(&machine.join("machine.nix"))
                && hash(&machine.join("machine.nix"))? == sha,
            "machine facts changed since install",
        )?;
        ensure(
            directory(&state.join("transition-incoming"))
                && mode(&state.join("transition-incoming"))? == 0o700,
            "unsafe reviewed upload",
        )?;
    }
    git(
        repo,
        &[
            "fetch",
            "--no-tags",
            "origin",
            &format!("refs/heads/{branch}"),
        ],
    )?;
    let next = git(repo, &["rev-parse", "FETCH_HEAD"])?.trim().to_owned();
    git(repo, &["merge-base", "--is-ancestor", &current, &next])?;
    if next == current && reviewed.is_none() {
        println!("Already at {next}");
        return Ok(());
    }
    let tmp = tempfile::tempdir()?;
    let stage_machine = if let Some(r) = reviewed {
        let dir = tmp.path().join("private");
        fs::create_dir(&dir)?;
        fs::copy(r, dir.join("machine.nix"))?;
        if regular(&machine.join("facter.json")) {
            fs::copy(machine.join("facter.json"), dir.join("facter.json"))?;
        }
        dir
    } else {
        machine.to_owned()
    };
    let source = tmp.path().join("source");
    fs::create_dir(&source)?;
    stage(repo, &next, &stage_machine, &source)?;
    build(&source, host)?;
    run_status(
        Command::new("nixos-rebuild")
            .args(["switch", "--flake"])
            .arg(format!("{}#{host}", source.display()))
            .arg("--no-write-lock-file"),
    )?;
    if let Some(r) = reviewed {
        atomic(&machine.join("machine.nix"), &fs::read(r)?)?;
    }
    atomic(&state.join("revision"), format!("{next}\n").as_bytes())?;
    if reviewed.is_some() {
        fs::remove_dir_all(state.join("transition-incoming"))?;
    }
    println!("UPDATE OK {current} -> {next}");
    Ok(())
}
const REMOTE: &str = "/run/current-system/sw/bin/moss";
fn require_remote_version(target: &str) -> Result<()> {
    // The host executes its installed binary, not code streamed by the operator.
    // Refuse an incompatible protocol instead of silently misreading a receipt.
    let version = ssh(target, &[REMOTE, "--version"])?;
    ensure(
        version.trim() == format!("moss {}", env!("CARGO_PKG_VERSION")),
        "operator and target moss versions differ; use the CLI pinned by the installed consumer",
    )
}
fn bootstrap_remote(
    phase: &str,
    url: &str,
    rev: &str,
    repo: &Path,
    machine: &Path,
    state: &Path,
    branch: &str,
) -> Result<()> {
    ensure(
        valid_hex(rev, 40) && valid_branch(branch) && !url.starts_with('-') && !url.contains('\n'),
        "invalid revision, branch or origin",
    )?;
    for p in [repo, machine, state] {
        ensure(
            remote_path(&p.to_string_lossy()) && !p.is_symlink(),
            "unsafe remote path",
        )?;
    }
    ensure(
        !repo.starts_with(state)
            && !machine.starts_with(state)
            && !repo.starts_with(machine)
            && !machine.starts_with(repo),
        "overlapping paths",
    )?;
    ensure(
        unsafe { libc::geteuid() } == 0 || std::env::var("THEMOSS_TEST_ROOT").as_deref() == Ok("1"),
        "root required",
    )?;
    let _guard = lock(state, "bootstrap.lock")?;
    ensure(
        mode(state)? == 0o700
            && !state.join("revision").is_symlink()
            && !state.join("incoming").is_symlink(),
        "unsafe state",
    )?;
    if !absent(&state.join("revision")) {
        ensure(
            regular(&state.join("revision"))
                && fs::read_to_string(state.join("revision"))?.trim() == rev,
            "different known-good revision",
        )?;
    }
    if !absent(repo) {
        ensure(
            directory(repo) && directory(&repo.join(".git")),
            "unrelated checkout",
        )?;
        ensure(
            git(repo, &["remote", "get-url", "origin"])?.trim() == url
                && git(repo, &["rev-parse", "HEAD"])?.trim() == rev,
            "checkout does not match installed commit/origin",
        )?;
    }
    let incoming = state.join("incoming");
    if phase == "prepare" {
        fs::create_dir_all(&incoming)?;
        fs::set_permissions(&incoming, fs::Permissions::from_mode(0o700))?;
        for name in ["machine.nix", "facter.json"] {
            if !absent(&incoming.join(name)) {
                fs::remove_file(incoming.join(name))?;
            }
        }
        return Ok(());
    }
    ensure(
        phase == "finish" && regular(&incoming.join("machine.nix")),
        "missing machine.nix upload or unknown phase",
    )?;
    for name in ["machine.nix", "facter.json"] {
        let src = incoming.join(name);
        if absent(&src) {
            continue;
        }
        ensure(regular(&src), "invalid uploaded file")?;
        let dst = machine.join(name);
        if !absent(&dst) {
            ensure(
                regular(&dst) && fs::read(&src)? == fs::read(&dst)?,
                "different existing machine file",
            )?;
        }
    }
    if absent(repo) {
        let tmp = state.join("checkout.tmp");
        if !absent(&tmp) {
            fs::remove_dir_all(&tmp)?;
        }
        run(Command::new("git")
            .args([
                "clone",
                "--no-checkout",
                "--single-branch",
                "--branch",
                branch,
                "--",
                url,
            ])
            .arg(&tmp))?;
        git(
            &tmp,
            &[
                "merge-base",
                "--is-ancestor",
                rev,
                &format!("origin/{branch}"),
            ],
        )?;
        git(&tmp, &["checkout", "--detach", rev])?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o700))?;
        fs::create_dir_all(repo.parent().ok_or_else(|| error("invalid checkout"))?)?;
        ensure(absent(repo), "checkout appeared during bootstrap")?;
        fs::rename(tmp, repo)?;
    }
    fs::create_dir_all(machine)?;
    ensure(
        mode(machine)? == 0o700,
        "private machine directory must be mode 700",
    )?;
    for name in ["machine.nix", "facter.json"] {
        let src = incoming.join(name);
        let dst = machine.join(name);
        if regular(&src) && absent(&dst) {
            atomic(&dst, &fs::read(src)?)?;
        }
    }
    atomic(&state.join("revision"), format!("{rev}\n").as_bytes())?;
    fs::remove_dir_all(incoming)?;
    println!("Bootstrapped installed revision {rev}; timer policy unchanged");
    Ok(())
}
fn main_action(action: Action) -> Result<()> {
    match action {
        Action::Discover {
            target,
            disk,
            record,
        } => {
            ensure(root_target(&target), "expected root@HOST SSH target")?;
            ensure(
                disk.starts_with("/dev/") && !disk.contains("..") && absent(&record),
                "expected a whole /dev disk and new record",
            )?;
            let p = live_probe(&target)?;
            let mut selected = p
                .disks
                .into_iter()
                .filter(|d| d.path == disk && d.kind == "disk");
            let chosen = selected
                .next()
                .ok_or_else(|| error("disk not unique whole disk"))?;
            ensure(selected.next().is_none(), "disk not unique whole disk")?;
            let r = Record {
                target,
                arch: p.arch,
                boot: p.boot,
                nic: p.nic,
                mac: p.mac,
                disk: chosen,
            };
            write_new(&record, &serde_json::to_vec_pretty(&r)?)?;
            println!(
                "Private machine record created: {} (verify with provider console)",
                record.display()
            );
        }
        Action::Preflight { record } => {
            check(&record)?;
        }
        Action::Install {
            record,
            repo,
            rev,
            machine,
            host,
            branch,
            receipt: out,
        } => {
            ensure(
                absent(&out)
                    && directory(out.parent().ok_or_else(|| error("invalid receipt path"))?)
                    && valid_hex(&rev, 40)
                    && valid_branch(&branch),
                "invalid receipt, revision or branch",
            )?;
            ensure(
                git(&repo, &["status", "--porcelain"])?.is_empty(),
                "commit/review local changes before install",
            )?;
            ensure(
                git(&repo, &["cat-file", "-t", &rev])?.trim() == "commit",
                "invalid commit",
            )?;
            ensure(
                git(
                    &repo,
                    &[
                        "ls-remote",
                        "--exit-code",
                        "origin",
                        &format!("refs/heads/{branch}"),
                    ],
                )?
                .split_whitespace()
                .next()
                    == Some(&rev),
                "install commit must be pushed as exact branch head",
            )?;
            let r = check(&record)?;
            let stage_dir = tempfile::tempdir()?;
            stage(&repo, &rev, &machine, stage_dir.path())?;
            build(stage_dir.path(), &host)?;
            print!("Type ERASE {} to install on {}: ", r.disk.path, r.target);
            io::stdout().flush()?;
            let mut answer = String::new();
            io::stdin().read_line(&mut answer)?;
            ensure(
                answer.trim_end_matches(['\n', '\r']) == format!("ERASE {}", r.disk.path),
                "confirmation denied",
            )?;
            check(&record)?;
            run_status(
                Command::new("nixos-anywhere")
                    .args(["--flake"])
                    .arg(format!("{}#{host}", stage_dir.path().display()))
                    .args(["--target-host", &r.target]),
            )?;
            let installed = Receipt {
                target: r.target,
                revision: rev,
                branch,
                origin: git(&repo, &["remote", "get-url", "origin"])?
                    .trim()
                    .to_owned(),
                machine_sha256: hash(&machine.join("machine.nix"))?,
                facter_sha256: if regular(&machine.join("facter.json")) {
                    hash(&machine.join("facter.json"))?
                } else {
                    String::new()
                },
            };
            ensure(absent(&out), "receipt appeared during install")?;
            write_new(&out, &serde_json::to_vec_pretty(&installed)?)?;
            println!(
                "Install receipt: {} (back up off-host; do not reinstall to repair bootstrap)",
                out.display()
            );
        }
        Action::Bootstrap {
            receipt: file,
            repo,
            machine,
            remote_checkout,
            remote_machine,
            remote_state,
        } => {
            let r = receipt(&file)?;
            ensure(root_target(&r.target), "bootstrap requires root SSH target")?;
            for path in [&remote_checkout, &remote_machine, &remote_state] {
                ensure(remote_path(path), "unsafe remote path")?;
            }
            ensure(
                valid_hex(&r.revision, 40)
                    && valid_branch(&r.branch)
                    && git(&repo, &["cat-file", "-t", &r.revision])?.trim() == "commit",
                "invalid installed commit",
            )?;
            private_file(&machine.join("machine.nix"))?;
            ensure(
                hash(&machine.join("machine.nix"))? == r.machine_sha256,
                "machine.nix differs from installed input",
            )?;
            if r.facter_sha256.is_empty() {
                ensure(
                    absent(&machine.join("facter.json")),
                    "unexpected facter report",
                )?;
            } else {
                ensure(
                    regular(&machine.join("facter.json"))
                        && hash(&machine.join("facter.json"))? == r.facter_sha256,
                    "facter report differs from installed input",
                )?;
            }
            ensure(
                git(&repo, &["remote", "get-url", "origin"])?.trim() == r.origin,
                "origin differs from install receipt",
            )?;
            require_remote_version(&r.target)?;
            let args = [
                r.origin.as_str(),
                r.revision.as_str(),
                remote_checkout.as_str(),
                remote_machine.as_str(),
                remote_state.as_str(),
                r.branch.as_str(),
            ];
            let mut prepare = vec![REMOTE, "bootstrap-remote", "prepare"];
            prepare.extend(args);
            ssh(&r.target, &prepare)?;
            let mut tar = Command::new("tar");
            tar.arg("-C")
                .arg(&machine)
                .args(["-cf", "-", "machine.nix"]);
            if regular(&machine.join("facter.json")) {
                tar.arg("facter.json");
            }
            let bytes = tar.output()?;
            ensure(bytes.status.success(), "tar upload failed")?;
            run_input(
                Command::new("ssh").args([
                    "-o",
                    "StrictHostKeyChecking=yes",
                    &r.target,
                    &format!(
                        "tar -xf - -C {} --no-same-owner",
                        shell_quote(&format!("{remote_state}/incoming"))
                    ),
                ]),
                &bytes.stdout,
            )?;
            let mut finish = vec![REMOTE, "bootstrap-remote", "finish"];
            finish.extend(args);
            ssh(&r.target, &finish)?;
        }
        Action::Update {
            repo,
            branch,
            machine,
            host,
            state,
            reviewed,
            expected_rev,
            expected_sha,
        } => {
            let baseline = expected_rev.as_deref().zip(expected_sha.as_deref());
            update(
                &repo,
                &branch,
                &machine,
                &host,
                &state,
                reviewed.as_deref(),
                baseline,
            )?;
        }
        Action::Transition {
            receipt: file,
            target,
            remote_checkout,
            branch,
            new_machine,
            remote_machine,
            host,
            remote_state,
        } => {
            let r = receipt(&file)?;
            ensure(
                target == r.target
                    && root_target(&target)
                    && valid_branch(&branch)
                    && valid_host(&host),
                "invalid target, branch or host",
            )?;
            for path in [&remote_checkout, &remote_machine, &remote_state] {
                ensure(remote_path(path), "unsafe remote path")?;
            }
            private_file(&new_machine.join("machine.nix"))?;
            ensure(
                valid_hex(&r.revision, 40) && valid_hex(&r.machine_sha256, 64),
                "invalid receipt",
            )?;
            require_remote_version(&target)?;
            ssh(
                &target,
                &[
                    REMOTE,
                    "prepare-transition",
                    &remote_checkout,
                    &remote_machine,
                    &remote_state,
                    &r.revision,
                    &r.machine_sha256,
                ],
            )?;
            let bytes = Command::new("tar")
                .arg("-C")
                .arg(&new_machine)
                .args(["-cf", "-", "machine.nix"])
                .output()?;
            ensure(bytes.status.success(), "tar proposal failed")?;
            run_input(
                Command::new("ssh").args([
                    "-o",
                    "StrictHostKeyChecking=yes",
                    &target,
                    &format!(
                        "tar -xf - -C {} --no-same-owner",
                        shell_quote(&format!("{remote_state}/transition-incoming"))
                    ),
                ]),
                &bytes.stdout,
            )?;
            ssh(
                &target,
                &[
                    REMOTE,
                    "update",
                    &remote_checkout,
                    &branch,
                    &remote_machine,
                    &host,
                    &remote_state,
                    &format!("{remote_state}/transition-incoming/machine.nix"),
                    &r.revision,
                    &r.machine_sha256,
                ],
            )?;
        }
        Action::PrepareTransition {
            repo,
            machine,
            state,
            rev,
            sha,
        } => {
            ensure(
                directory(&repo.join(".git"))
                    && directory(&machine)
                    && directory(&state)
                    && valid_hex(&rev, 40)
                    && valid_hex(&sha, 64),
                "missing target checkout/private state or invalid receipt",
            )?;
            ensure(
                revision(&state)? == rev
                    && regular(&machine.join("machine.nix"))
                    && hash(&machine.join("machine.nix"))? == sha,
                "baseline or machine facts differ from installed input",
            )?;
            let incoming = state.join("transition-incoming");
            ensure(!incoming.is_symlink(), "linked upload directory")?;
            fs::create_dir_all(&incoming)?;
            fs::set_permissions(&incoming, fs::Permissions::from_mode(0o700))?;
            if !absent(&incoming.join("machine.nix")) {
                fs::remove_file(incoming.join("machine.nix"))?;
            }
        }
        Action::BootstrapRemote {
            phase,
            url,
            rev,
            repo,
            machine,
            state,
            branch,
        } => bootstrap_remote(&phase, &url, &rev, &repo, &machine, &state, &branch)?,
        Action::GenerateDocs { output } => {
            let mut cmd = Cli::command();
            let mut reference = format!(
                "# `moss` command reference\n\nGenerated by `moss generate-docs docs/cli.md`. Do not edit by hand.\n\n```text\n{}\n```\n",
                cmd.render_long_help()
            );
            for sub in Cli::command()
                .get_subcommands()
                .filter(|s| !s.is_hide_set() && s.get_name() != "help")
            {
                let mut page = sub.clone();
                page.set_bin_name(format!("moss {}", sub.get_name()));
                reference.push_str(&format!(
                    "\n## `moss {}`\n\n```text\n{}\n```\n",
                    sub.get_name(),
                    page.render_long_help()
                ));
            }
            fs::write(output, reference)?;
        }
    }
    Ok(())
}
fn main() {
    unsafe {
        libc::umask(0o077);
    }
    if let Err(e) = main_action(Cli::parse().command) {
        eprintln!("moss: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reject_unsafe_remote_inputs() {
        assert!(remote_path("/var/lib/themoss"));
        for p in ["relative", "/tmp/../etc", "/tmp/evil space", "/tmp/a;rm"] {
            assert!(!remote_path(p), "accepted {p}");
        }
        assert!(root_target("root@host.example"));
        assert!(!root_target("operator@host.example"));
        assert!(!valid_branch("../main"));
        assert!(!valid_branch("-evil"));
    }

    #[test]
    fn shell_arguments_are_individually_quoted() {
        assert_eq!(shell_quote("it's $(unsafe)"), "'it'\\''s $(unsafe)'");
    }

    #[test]
    fn receipt_fields_remain_compatible_with_bash_toolkit() {
        let r = Receipt {
            target: "root@host".into(),
            revision: "a".repeat(40),
            branch: "main".into(),
            origin: "ssh://example/repo".into(),
            machine_sha256: "b".repeat(64),
            facter_sha256: String::new(),
        };
        let json = serde_json::to_value(r).unwrap();
        assert_eq!(json["machineSha256"], "b".repeat(64));
        assert_eq!(json["facterSha256"], "");
    }
}
