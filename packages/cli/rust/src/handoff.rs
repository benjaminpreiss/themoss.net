//! Private first-boot and transition handoffs. No install path is reachable
//! from this module. A failed upload is retryable without touching disk.
use crate::{
    machine::{self, Config, Receipt},
    safety::{self as s, Result},
    target,
};
use serde::Deserialize;
use std::{path::Path, process::Command};

fn verified_inputs(
    receipt: &Receipt,
    repo: &Path,
    machine: &Path,
    checkout: &str,
    remote_machine: &str,
    state: &str,
) -> Result<()> {
    s::ensure(
        s::root_target(&receipt.target)
            && s::hex(&receipt.revision, 40)
            && s::branch(&receipt.branch),
        "invalid install receipt",
    )?;
    for path in [checkout, remote_machine, state] {
        s::ensure(s::remote_path(path), "unsafe remote path")?;
    }
    s::ensure(
        s::git(repo, &["cat-file", "-t", &receipt.revision])?.trim() == "commit",
        "missing installed commit",
    )?;
    s::ensure(
        s::git(repo, &["remote", "get-url", "origin"])?.trim() == receipt.origin,
        "origin differs from install receipt",
    )?;
    s::private(&machine.join("machine.nix"))?;
    s::ensure(
        s::hash(&machine.join("machine.nix"))? == receipt.machine_sha256,
        "machine.nix differs from installed input",
    )?;
    let facter = machine.join("facter.json");
    if receipt.facter_sha256.is_empty() {
        s::ensure(!s::exists(&facter), "unexpected facter report")?;
    } else {
        s::private(&facter)?;
        s::ensure(
            s::hash(&facter)? == receipt.facter_sha256,
            "facter report differs from installed input",
        )?;
    }
    Ok(())
}
pub fn bootstrap(receipt_path: &Path, config_path: Option<&Path>) -> Result<()> {
    s::private(receipt_path)?;
    s::operator_path(receipt_path)?;
    let receipt: Receipt = s::json(receipt_path)?;
    let config_path = match config_path {
        Some(path) => path.to_owned(),
        None => s::workspace()?
            .join(".moss")
            .join(&receipt.target)
            .join("machine.json"),
    };
    s::private(&config_path)?;
    s::operator_path(&config_path)?;
    let config: Config = s::json(&config_path)?;
    config.validate()?;
    s::ensure(
        config.receipt == receipt_path.to_string_lossy(),
        "receipt differs from private configuration",
    )?;
    bootstrap_with_paths(
        &receipt,
        Path::new(&config.repo),
        Path::new(&config.machine),
        &config.remote_checkout,
        &config.remote_machine,
        &config.remote_state,
    )
}
pub fn bootstrap_with_paths(
    receipt: &Receipt,
    repo: &Path,
    machine: &Path,
    checkout: &str,
    remote_machine: &str,
    state: &str,
) -> Result<()> {
    verified_inputs(receipt, repo, machine, checkout, remote_machine, state)?;
    let args = [
        &receipt.origin[..],
        &receipt.revision,
        checkout,
        remote_machine,
        state,
        &receipt.branch,
    ];
    target::target_command(&receipt.target, "bootstrap-prepare", &args)?;
    let mut archive = Command::new("tar");
    archive
        .arg("-C")
        .arg(machine)
        .args(["-cf", "-", "machine.nix"]);
    if !receipt.facter_sha256.is_empty() {
        archive.arg("facter.json");
    }
    let content = archive.output()?;
    s::ensure(
        content.status.success(),
        "failed to archive private machine input",
    )?;
    s::ssh_input(
        &receipt.target,
        &format!(
            "tar -xf - -C {} --no-same-owner",
            s::quote(&format!("{state}/incoming"))
        ),
        &content.stdout,
    )?;
    target::target_command(&receipt.target, "bootstrap-finish", &args)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AdoptionEvidence {
    target: String,
    revision: String,
    origin: String,
    machine_sha256: String,
    facter_sha256: String,
    running_system: String,
    verified_by: String,
}
pub fn adopt(
    evidence_path: &Path,
    repo: &Path,
    machine: &Path,
    host: &str,
    checkout: &str,
    remote_machine: &str,
    state: &str,
) -> Result<()> {
    s::private(evidence_path)?;
    s::ensure(s::host(host), "invalid host")?;
    let evidence: AdoptionEvidence = s::json(evidence_path)?;
    s::ensure(
        !evidence.verified_by.is_empty()
            && s::root_target(&evidence.target)
            && s::hex(&evidence.revision, 40),
        "operator verification required",
    )?;
    let receipt = Receipt {
        target: evidence.target,
        revision: evidence.revision,
        branch: s::git(repo, &["branch", "--show-current"])?
            .trim()
            .to_string(),
        origin: evidence.origin,
        machine_sha256: evidence.machine_sha256,
        facter_sha256: evidence.facter_sha256,
    };
    verified_inputs(&receipt, repo, machine, checkout, remote_machine, state)?;
    let stage = tempfile::tempdir()?;
    machine::stage(repo, &receipt.revision, machine, stage.path())?;
    let expected = s::run(
        Command::new("nix")
            .args([
                "build",
                "--no-link",
                "--no-write-lock-file",
                "--print-out-paths",
            ])
            .arg(format!(
                "{}#nixosConfigurations.{host}.config.system.build.toplevel",
                stage.path().display()
            )),
    )?;
    let expected = expected.trim();
    s::ensure(
        expected.starts_with("/nix/store/") && expected == evidence.running_system,
        "evidence does not match evaluated system",
    )?;
    s::ensure(
        s::ssh(&receipt.target, "readlink -f /run/current-system")?.trim() == expected,
        "running system differs from verified baseline",
    )?;
    bootstrap_with_paths(&receipt, repo, machine, checkout, remote_machine, state)
}
pub fn transition(
    receipt_path: &Path,
    target: &str,
    repo: &str,
    branch: &str,
    new_machine: &Path,
    machine: &str,
    host: &str,
    state: &str,
) -> Result<()> {
    s::private(receipt_path)?;
    let receipt: Receipt = s::json(receipt_path)?;
    s::ensure(
        receipt.target == target && s::root_target(target) && s::branch(branch) && s::host(host),
        "invalid transition target/branch",
    )?;
    for path in [repo, machine, state] {
        s::ensure(s::remote_path(path), "unsafe remote path")?;
    }
    s::private(&new_machine.join("machine.nix"))?;
    s::ensure(
        s::hex(&receipt.revision, 40) && s::hex(&receipt.machine_sha256, 64),
        "invalid receipt",
    )?;
    target::target_command(
        target,
        "prepare-transition",
        &[
            repo,
            machine,
            state,
            &receipt.revision,
            &receipt.machine_sha256,
        ],
    )?;
    let tar = Command::new("tar")
        .arg("-C")
        .arg(new_machine)
        .args(["-cf", "-", "machine.nix"])
        .output()?;
    s::ensure(
        tar.status.success(),
        "cannot archive reviewed machine input",
    )?;
    s::ssh_input(
        target,
        &format!(
            "tar -xf - -C {} --no-same-owner",
            s::quote(&format!("{state}/transition-incoming"))
        ),
        &tar.stdout,
    )?;
    target::target_command(
        target,
        "apply-transition",
        &[
            repo,
            branch,
            machine,
            host,
            state,
            &format!("{state}/transition-incoming/machine.nix"),
            &receipt.revision,
            &receipt.machine_sha256,
        ],
    )?;
    Ok(())
}
