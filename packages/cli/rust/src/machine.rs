//! Domain facts shared by reviewed plans and target-side deployment.
use crate::safety::{self as s, Result};
use serde::{Deserialize, Serialize};
use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Disk {
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub size: u64,
    pub model: Option<String>,
    pub serial: Option<String>,
}
#[derive(Debug, Deserialize, Serialize, PartialEq)]
pub struct Record {
    pub target: String,
    pub arch: String,
    pub boot: String,
    pub nic: String,
    pub mac: String,
    pub disk: Disk,
}
#[derive(Debug)]
pub struct Probe {
    pub arch: String,
    pub boot: String,
    pub nic: String,
    pub mac: String,
    pub disks: Vec<Disk>,
}

/// No auto-accept of SSH fingerprints. The route must name exactly one NIC.
pub fn probe(target: &str) -> Result<Probe> {
    s::ensure(s::root_target(target), "invalid SSH target")?;
    let raw = s::ssh_input(
        target,
        "bash -s",
        b"set -euo pipefail\nuname -m\nif [[ -d /sys/firmware/efi ]]; then echo uefi; else echo bios; fi\nip -j route show default\nlsblk -J -d -b -o PATH,TYPE,SIZE,MODEL,SERIAL\n",
    )?;
    let mut lines = raw.lines();
    let arch = lines
        .next()
        .ok_or_else(|| s::err("missing architecture"))?
        .to_owned();
    let boot = lines
        .next()
        .ok_or_else(|| s::err("missing boot mode"))?
        .to_owned();
    let routes: serde_json::Value = serde_json::from_str(
        lines
            .next()
            .ok_or_else(|| s::err("missing default route"))?,
    )?;
    let routes = routes.as_array().ok_or_else(|| s::err("invalid routes"))?;
    s::ensure(routes.len() == 1, "ambiguous default route")?;
    let nic = routes[0]["dev"]
        .as_str()
        .ok_or_else(|| s::err("missing NIC"))?
        .to_owned();
    s::ensure(
        !nic.is_empty()
            && nic
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.:-".contains(&c)),
        "invalid NIC",
    )?;
    let block: serde_json::Value = serde_json::from_str(&lines.collect::<Vec<_>>().join("\n"))?;
    let disks: Vec<Disk> = serde_json::from_value(serde_json::Value::Array(
        block["blockdevices"]
            .as_array()
            .ok_or_else(|| s::err("invalid block devices"))?
            .iter()
            .filter(|v| v["type"] == "disk")
            .cloned()
            .collect(),
    ))?;
    let mac = s::ssh(target, &format!("cat /sys/class/net/{nic}/address"))?
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

pub fn discover(target: &str, disk: &str) -> Result<Record> {
    s::ensure(s::disk_path(disk), "expected a whole /dev disk")?;
    let probed = probe(target)?;
    let mut matches = probed
        .disks
        .into_iter()
        .filter(|d| d.path == disk && d.kind == "disk");
    let selected = matches.next().ok_or_else(|| s::err("disk not found"))?;
    s::ensure(matches.next().is_none(), "disk not unique")?;
    Ok(Record {
        target: target.to_owned(),
        arch: probed.arch,
        boot: probed.boot,
        nic: probed.nic,
        mac: probed.mac,
        disk: selected,
    })
}
pub fn preflight(record: &Record) -> Result<()> {
    let actual = probe(&record.target)?;
    s::ensure(
        actual.arch == record.arch
            && actual.boot == record.boot
            && actual.nic == record.nic
            && actual.mac == record.mac
            && actual.disks.iter().filter(|d| **d == record.disk).count() == 1,
        "target architecture, boot, NIC/MAC or whole-disk identity changed",
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
    Ok(())
}

/// Extract only a pinned Git tree; local edits, symlinks, Git metadata and
/// credential-bearing recovery material are excluded from the Nix stage.
pub fn stage(repo: &Path, revision: &str, machine: &Path, destination: &Path) -> Result<()> {
    s::ensure(
        s::dir(machine) && s::file(&machine.join("machine.nix")),
        "missing private machine.nix",
    )?;
    let tree = s::git(repo, &["ls-tree", "-r", revision])?;
    s::ensure(
        !tree.lines().any(|line| line.starts_with("120000 ")),
        "linked source in commit",
    )?;
    let archive = tempfile::NamedTempFile::new()?;
    s::status(
        Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(["archive", "--format=tar", revision])
            .stdout(archive.reopen()?),
    )?;
    let names = s::run(Command::new("tar").arg("-tf").arg(archive.path()))?;
    s::ensure(
        names
            .lines()
            .all(|name| !name.starts_with('/') && !name.split('/').any(|p| p == "..")),
        "unsafe archive path",
    )?;
    s::status(
        Command::new("tar")
            .arg("-xf")
            .arg(archive.path())
            .arg("-C")
            .arg(destination)
            .arg("--no-same-owner"),
    )?;
    s::ensure(
        s::file(&destination.join("flake.lock")) && !s::exists(&destination.join("generated")),
        "committed lock required; generated/ must not be committed",
    )?;
    s::ensure(
        s::run(
            Command::new("find")
                .arg(destination)
                .args(["-type", "l", "-print", "-quit"]),
        )?
        .is_empty(),
        "linked source in archive",
    )?;
    let generated = destination.join("generated");
    fs::create_dir(&generated)?;
    fs::set_permissions(&generated, fs::Permissions::from_mode(0o700))?;
    fs::copy(machine.join("machine.nix"), generated.join("machine.nix"))?;
    if s::exists(&machine.join("facter.json")) {
        s::ensure(
            s::file(&machine.join("facter.json")),
            "linked facter report",
        )?;
        fs::copy(machine.join("facter.json"), generated.join("facter.json"))?;
    }
    Ok(())
}
pub fn build(source: &Path, host: &str) -> Result<()> {
    s::ensure(s::host(host), "invalid NixOS output")?;
    s::status(
        Command::new("nix")
            .args(["build", "--no-link", "--no-write-lock-file"])
            .arg(format!(
                "{}#nixosConfigurations.{host}.config.system.build.toplevel",
                source.display()
            )),
    )
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Receipt {
    pub target: String,
    pub revision: String,
    pub branch: String,
    pub origin: String,
    pub machine_sha256: String,
    pub facter_sha256: String,
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub version: u8,
    pub repo: String,
    pub revision: String,
    pub branch: String,
    pub output: String,
    pub machine: String,
    pub receipt: String,
    pub remote_checkout: String,
    pub remote_machine: String,
    pub remote_state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub report_generator: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recovery_dir: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_erase_check: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disk: Option<String>,
}
impl Config {
    pub fn validate(&self) -> Result<()> {
        s::ensure(
            self.version == 1
                && s::hex(&self.revision, 40)
                && s::branch(&self.branch)
                && s::host(&self.output),
            "invalid private machine configuration",
        )?;
        for name in [&self.repo, &self.machine, &self.receipt] {
            s::ensure(
                name.starts_with('/') && !name.contains(".."),
                "unsafe local path",
            )?;
        }
        for name in [
            &self.remote_checkout,
            &self.remote_machine,
            &self.remote_state,
        ] {
            s::ensure(s::remote_path(name), "unsafe remote path")?;
        }
        s::ensure(
            self.disk.as_deref().is_none_or(s::disk_path),
            "unsafe disk path",
        )?;
        for optional in [
            &self.report_generator,
            &self.recovery_dir,
            &self.pre_erase_check,
        ] {
            s::ensure(
                optional.as_deref().is_none_or(|v| !v.is_empty()),
                "empty optional path",
            )?;
        }
        let repo = Path::new(&self.repo);
        s::ensure(s::dir(repo), "invalid checkout")?;
        s::unlinked(repo)?;
        let machine = Path::new(&self.machine);
        s::ensure(s::dir(machine), "invalid private machine directory")?;
        s::unlinked(machine)?;
        s::private(&machine.join("machine.nix"))?;
        s::operator_path(&machine.join("machine.nix"))?;
        s::operator_path(&machine.join("facter.json"))?;
        s::operator_path(Path::new(&self.receipt))?;
        if let Some(recovery) = &self.recovery_dir {
            s::ensure(s::dir(Path::new(recovery)), "missing recovery tree")?;
            s::unlinked(Path::new(recovery))?;
            s::operator_path(&Path::new(recovery).join("."))?;
        }
        Ok(())
    }
}
