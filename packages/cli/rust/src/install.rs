//! Install preparation. Only `install()` can invoke nixos-anywhere.
use crate::{
    machine::{self, Config, Receipt, Record},
    safety::{self as s, Result},
};
use std::{
    fs,
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::Path,
    process::Command,
};

fn hook(path: Option<&str>) -> Result<Option<&Path>> {
    match path {
        None | Some("-") => Ok(None),
        Some(name) => {
            let path = Path::new(name);
            s::ensure(
                s::file(path) && fs::metadata(path)?.permissions().mode() & 0o111 != 0,
                "hook must be an executable regular file",
            )?;
            s::unlinked(path)?;
            Ok(Some(path))
        }
    }
}
fn verify_source(config: &Config) -> Result<()> {
    let repo = Path::new(&config.repo);
    s::ensure(
        s::git(repo, &["status", "--porcelain"])?.is_empty(),
        "commit/review local changes before planning",
    )?;
    s::ensure(
        s::git(repo, &["cat-file", "-t", &config.revision])?.trim() == "commit",
        "missing pinned commit",
    )?;
    s::verify_tip(repo, &config.branch, &config.revision)
}
fn generator(config: &Config, target: &str) -> Result<()> {
    let Some(generator) = hook(config.report_generator.as_deref())? else {
        return Ok(());
    };
    let machine = Path::new(&config.machine);
    let facter = machine.join("facter.json");
    s::ensure(!s::exists(&facter), "refusing to replace hardware report")?;
    let staged = tempfile::Builder::new()
        .prefix(".facter.")
        .tempfile_in(machine)?;
    let candidate = staged.into_temp_path();
    fs::remove_file(&candidate)?;
    s::status(Command::new(generator).arg(target).arg(&candidate))?;
    s::ensure(
        s::file(&candidate),
        "generator did not produce a regular report",
    )?;
    let _: serde_json::Value = s::json(&candidate)?;
    fs::set_permissions(&candidate, fs::Permissions::from_mode(0o600))?;
    s::ensure(
        !s::exists(&facter),
        "hardware report appeared during generation",
    )?;
    fs::hard_link(&candidate, &facter)?;
    // TempPath removes the source even if the hook fails after writing it.
    Ok(())
}
pub fn plan_build(record: &Record, config: &Config) -> Result<()> {
    verify_source(config)?;
    machine::preflight(record)?;
    hook(config.pre_erase_check.as_deref())?;
    generator(config, &record.target)?;
    let staged = tempfile::tempdir()?;
    machine::stage(
        Path::new(&config.repo),
        &config.revision,
        Path::new(&config.machine),
        staged.path(),
    )?;
    machine::build(staged.path(), &config.output)?;
    if let Some(check) = hook(config.pre_erase_check.as_deref())? {
        let facts = record_file(record)?;
        s::status(
            Command::new(check)
                .arg(staged.path())
                .arg(&config.output)
                .arg(facts.path()),
        )?;
    }
    s::verify_tip(Path::new(&config.repo), &config.branch, &config.revision)?;
    println!("Evaluated build and consumer pre-erase check passed; review the reported target and disk before install.");
    Ok(())
}
fn record_file(record: &Record) -> Result<tempfile::NamedTempFile> {
    let file = tempfile::NamedTempFile::new()?;
    fs::set_permissions(file.path(), fs::Permissions::from_mode(0o600))?;
    fs::write(file.path(), serde_json::to_vec(record)?)?;
    Ok(file)
}
pub fn install(record: &Record, config: &Config) -> Result<()> {
    let receipt = Path::new(&config.receipt);
    s::ensure(
        !s::exists(receipt),
        "install receipt already exists; never reinstall to repair bootstrap",
    )?;
    s::operator_path(receipt)?;
    verify_source(config)?;
    machine::preflight(record)?;
    let staged = tempfile::tempdir()?;
    machine::stage(
        Path::new(&config.repo),
        &config.revision,
        Path::new(&config.machine),
        staged.path(),
    )?;
    machine::build(staged.path(), &config.output)?;
    if let Some(check) = hook(config.pre_erase_check.as_deref())? {
        let facts = record_file(record)?;
        s::status(
            Command::new(check)
                .arg(staged.path())
                .arg(&config.output)
                .arg(facts.path()),
        )?;
    }
    let disk = &record.disk.path;
    eprint!("Type ERASE {disk} to install on {}: ", record.target);
    io::stderr().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    s::ensure(
        answer.trim_end_matches(['\r', '\n']) == format!("ERASE {disk}"),
        "confirmation denied",
    )?;
    machine::preflight(record)?;
    s::verify_tip(Path::new(&config.repo), &config.branch, &config.revision)?;
    let mut command = Command::new("nixos-anywhere");
    command.args([
        "--flake",
        &format!("{}#{}", staged.path().display(), config.output),
        "--target-host",
        &record.target,
    ]);
    if let Some(recovery) = &config.recovery_dir {
        s::ensure(s::dir(Path::new(recovery)), "missing recovery directory")?;
        s::ensure(
            s::run(
                Command::new("find")
                    .arg(recovery)
                    .args(["-type", "l", "-print", "-quit"]),
            )?
            .is_empty(),
            "linked recovery file",
        )?;
        command.args(["--extra-files", recovery]);
    }
    // Nothing above this line has permission to erase. After this call a
    // missing receipt is an uncertain install; never automatically retry.
    s::status(&mut command)?;
    let machine_dir = Path::new(&config.machine);
    let facter = machine_dir.join("facter.json");
    let written = Receipt {
        target: record.target.clone(),
        revision: config.revision.clone(),
        branch: config.branch.clone(),
        origin: s::git(Path::new(&config.repo), &["remote", "get-url", "origin"])?
            .trim()
            .into(),
        machine_sha256: s::hash(&machine_dir.join("machine.nix"))?,
        facter_sha256: if s::exists(&facter) {
            s::hash(&facter)?
        } else {
            String::new()
        },
    };
    s::write_json(receipt, &written)?;
    println!(
        "Install receipt: {} (back up off-host; do not reinstall to repair bootstrap)",
        receipt.display()
    );
    Ok(())
}
