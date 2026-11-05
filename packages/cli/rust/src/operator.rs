//! Operator-facing reviewed plan and apply. The only path to an erase is
//! `install::install`, after the plan has been verified against fresh facts.
use crate::{
    install,
    machine::{self, Config, Record},
    safety::{self as s, Result},
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Write},
    os::unix::fs::symlink,
    path::{Path, PathBuf},
};

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase", deny_unknown_fields)]
pub enum Plan {
    Install {
        version: u8,
        config: String,
        #[serde(rename = "configSha256")]
        config_sha256: String,
        target: String,
        disk: String,
        observed: Record,
        #[serde(rename = "machineSha256")]
        machine_sha256: String,
        #[serde(rename = "facterSha256")]
        facter_sha256: String,
        origin: String,
    },
    Update {
        version: u8,
        config: String,
        #[serde(rename = "configSha256")]
        config_sha256: String,
        target: String,
        origin: String,
        expected: crate::target::Expected,
    },
}
impl Plan {
    fn target(&self) -> &str {
        match self {
            Self::Install { target, .. } | Self::Update { target, .. } => target,
        }
    }
    fn kind(&self) -> &str {
        match self {
            Self::Install { .. } => "install",
            Self::Update { .. } => "update",
        }
    }
}
fn ask(label: &str, default: &str) -> Result<String> {
    if default.is_empty() {
        eprint!("{label}: ");
    } else {
        eprint!("{label} [{default}]: ");
    }
    io::stderr().flush()?;
    let mut answer = String::new();
    s::ensure(
        io::stdin().read_line(&mut answer)? > 0,
        "configuration cancelled",
    )?;
    let answer = answer.trim_end_matches(['\r', '\n']);
    let result = if answer.is_empty() { default } else { answer };
    s::ensure(!result.is_empty(), &format!("{label} cannot be empty"))?;
    Ok(result.to_string())
}
fn optional(label: &str) -> Result<Option<String>> {
    eprint!("{label} (blank to omit): ");
    io::stderr().flush()?;
    let mut answer = String::new();
    s::ensure(
        io::stdin().read_line(&mut answer)? > 0,
        "configuration cancelled",
    )?;
    Ok(match answer.trim_end_matches(['\r', '\n']) {
        "" => None,
        s => Some(s.to_string()),
    })
}
fn configure(file: &Path, target: &str, requested_disk: Option<&str>) -> Result<Config> {
    s::ensure(
        unsafe { libc::isatty(0) } == 1 || std::env::var("MOSS_TEST_INPUT").as_deref() == Ok("1"),
        "without --config, plan requires an interactive terminal",
    )?;
    s::ensure(!s::exists(file), "configuration already exists")?;
    let base = file.parent().ok_or_else(|| s::err("invalid config path"))?;
    eprintln!(
        "Create {} (mode 600, off-host). No disk action occurs while answering.",
        file.display()
    );
    eprintln!("Do not enter secrets: machine.nix and facter.json may enter the Nix store.");
    let workspace = s::workspace()?;
    let default = if s::git(&workspace, &["rev-parse", "--show-toplevel"]).is_ok() {
        workspace.to_string_lossy().into_owned()
    } else {
        String::new()
    };
    let repo = ask("Consumer Git checkout (absolute path)", &default)?;
    s::ensure(s::dir(Path::new(&repo)), "invalid consumer checkout")?;
    if file.starts_with(workspace.join(".moss")) {
        s::ensure(
            repo == default,
            ".moss configuration must belong to this Git checkout",
        )?;
    }
    let rev_default = s::git(Path::new(&repo), &["rev-parse", "--verify", "HEAD"])?;
    let revision = ask("Full pushed commit", rev_default.trim())?;
    s::ensure(s::hex(&revision, 40), "expected a full commit SHA")?;
    let branch_default = s::git(Path::new(&repo), &["branch", "--show-current"])?;
    let branch = ask("Pushed branch", branch_default.trim())?;
    s::ensure(s::branch(&branch), "invalid branch")?;
    s::verify_tip(Path::new(&repo), &branch, &revision)?;
    let host_default = Path::new(&repo)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let output = ask("NixOS host output", host_default)?;
    s::ensure(s::host(&output), "invalid NixOS host output")?;
    let machine = ask(
        "Private machine directory with credential-free machine.nix",
        &base.join("machine").to_string_lossy(),
    )?;
    let receipt = ask(
        "Off-host install receipt",
        &base.join("install-receipt.json").to_string_lossy(),
    )?;
    let checkout = ask("Remote checkout", &format!("/root/{}", host_default))?;
    let remote_machine = ask("Remote private machine directory", "/root/private-machine")?;
    let remote_state = ask("Remote root-owned state directory", "/var/lib/themoss")?;
    let report_generator = optional("Consumer report generator executable")?;
    let recovery_dir = optional("Consumer recovery tree (never staged in Nix)")?;
    let pre_erase_check = optional("Consumer evaluated pre-erase check executable")?;
    let disk = if s::exists(Path::new(&receipt)) {
        s::ensure(
            requested_disk.is_none(),
            "installed receipt exists; never select a disk for an update",
        )?;
        None
    } else {
        let disks = machine::probe(target)?.disks;
        s::ensure(!disks.is_empty(), "target reported no whole disks")?;
        eprintln!("Whole disks detected on {target}:");
        for (i, d) in disks.iter().enumerate() {
            eprintln!(
                "  {}. {} size={} model={} serial={}",
                i + 1,
                d.path,
                d.size,
                d.model.as_deref().unwrap_or("unknown"),
                d.serial.as_deref().unwrap_or("unknown")
            );
        }
        let chosen = if let Some(requested) = requested_disk {
            s::ensure(
                disks.iter().filter(|d| d.path == requested).count() == 1,
                "--disk is not a unique whole disk on target",
            )?;
            requested.to_owned()
        } else if disks.len() == 1 {
            eprintln!(
                "Only one whole disk; proposing {} (NOT authorization to erase).",
                disks[0].path
            );
            disks[0].path.clone()
        } else {
            let selection = ask(
                &format!("Select whole disk [1-{}] (no default)", disks.len()),
                "",
            )?
            .parse::<usize>()?;
            s::ensure(
                (1..=disks.len()).contains(&selection),
                "disk selection out of range",
            )?;
            disks[selection - 1].path.clone()
        };
        s::ensure(s::disk_path(&chosen), "unsafe whole-disk path")?;
        Some(chosen)
    };
    let config = Config {
        version: 1,
        repo,
        revision,
        branch,
        output,
        machine,
        receipt,
        remote_checkout: checkout,
        remote_machine,
        remote_state,
        report_generator,
        recovery_dir,
        pre_erase_check,
        disk,
    };
    config.validate()?;
    eprintln!(
        "Review the private configuration below before saving:\n{}",
        serde_json::to_string_pretty(&config)?
    );
    eprint!("Save this configuration? [y/N] ");
    io::stderr().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    s::ensure(
        matches!(answer.trim(), "y" | "Y"),
        "configuration not saved",
    )?;
    s::operator_path(file)?;
    s::write_json(file, &config)?;
    eprintln!(
        "Created {} (mode 600); plan will now re-probe the selected target.",
        file.display()
    );
    Ok(config)
}
fn target_store(target: &str) -> Result<PathBuf> {
    s::ensure(s::root_target(target), "invalid SSH target")?;
    let root = s::workspace()?;
    s::check_store(&root)?;
    let store = root.join(".moss");
    s::private_dir(&store).map_err(|_| s::err("run 'moss init' before planning"))?;
    Ok(store.join(target))
}
fn publish_latest(store: &Path, plan: &Path) -> Result<()> {
    let latest = store.join("latest");
    s::ensure(
        !s::exists(&latest) || fs::symlink_metadata(&latest)?.file_type().is_symlink(),
        "latest must be a symlink",
    )?;
    let temp = tempfile::tempdir_in(store)?;
    let link = temp.path().join("latest");
    symlink(plan, &link)?;
    fs::rename(link, latest)?;
    Ok(())
}
fn planned_file(store: &Path) -> PathBuf {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    store
        .join("plans")
        .join(format!("{}-{}.json", epoch.as_secs(), epoch.subsec_nanos()))
}
fn load_config(path: &Path) -> Result<Config> {
    s::private(path)?;
    s::operator_path(path)?;
    let config: Config = s::json(path)?;
    config.validate()?;
    Ok(config)
}
fn facter_sha(config: &Config) -> Result<String> {
    let facter = Path::new(&config.machine).join("facter.json");
    if s::exists(&facter) {
        s::ensure(s::file(&facter), "linked facter report")?;
        s::hash(&facter)
    } else {
        Ok(String::new())
    }
}
pub fn plan(
    target: &str,
    config: Option<&Path>,
    disk: Option<&str>,
    output: Option<&Path>,
) -> Result<()> {
    s::ensure(s::root_target(target), "invalid SSH target")?;
    let store = if config.is_none() || output.is_none() {
        Some(target_store(target)?)
    } else {
        None
    };
    if let Some(store) = &store {
        s::create_private_dir(store)?;
        s::create_private_dir(&store.join("plans"))?;
    }
    let config_path = config
        .map(PathBuf::from)
        .unwrap_or_else(|| store.as_ref().unwrap().join("machine.json"));
    let output = output
        .map(PathBuf::from)
        .unwrap_or_else(|| planned_file(store.as_ref().unwrap()));
    s::ensure(
        !s::exists(&output),
        "choose a new absolute private plan path",
    )?;
    s::operator_path(&output)?;
    let configured = if !s::exists(&config_path) && config.is_none() {
        configure(&config_path, target, disk)?
    } else {
        load_config(&config_path)?
    };
    if store.is_some() {
        let workspace = s::workspace()?;
        if s::git(&workspace, &["rev-parse", "--show-toplevel"]).is_ok() {
            s::ensure(
                configured.repo == workspace.to_string_lossy(),
                "default .moss storage must belong to the consumer checkout",
            )?;
        }
    }
    let origin = s::git(
        Path::new(&configured.repo),
        &["remote", "get-url", "origin"],
    )?
    .trim()
    .to_owned();
    let proposal = if s::exists(Path::new(&configured.receipt)) {
        s::ensure(
            disk.is_none(),
            "installed receipt exists; never reformat to repair or update",
        )?;
        s::private(Path::new(&configured.receipt))?;
        let receipt: machine::Receipt = s::json(Path::new(&configured.receipt))?;
        s::ensure(
            receipt.target == target && receipt.origin == origin,
            "receipt target or origin changed",
        )?;
        let expected = crate::target::plan_update(&configured, &origin, target)?;
        s::ensure(
            expected.next == configured.revision
                && expected.selected == format!("branch:{}", configured.branch)
                && expected.machine_sha256
                    == s::hash(&Path::new(&configured.machine).join("machine.nix"))?,
            "update differs from reviewed inputs; transition requires separate review",
        )?;
        Plan::Update {
            version: 1,
            config: config_path.to_string_lossy().into(),
            config_sha256: s::hash(&config_path)?,
            target: target.into(),
            origin,
            expected,
        }
    } else {
        let chosen = disk
            .or(configured.disk.as_deref())
            .ok_or_else(|| s::err("fresh install requires a reviewed whole disk"))?;
        s::ensure(
            configured.disk.as_deref().is_none_or(|d| d == chosen),
            "selected disk differs from reviewed configuration",
        )?;
        let observed = machine::discover(target, chosen)?;
        install::plan_build(&observed, &configured)?;
        Plan::Install {
            version: 1,
            config: config_path.to_string_lossy().into(),
            config_sha256: s::hash(&config_path)?,
            target: target.into(),
            disk: chosen.into(),
            observed,
            machine_sha256: s::hash(&Path::new(&configured.machine).join("machine.nix"))?,
            facter_sha256: facter_sha(&configured)?,
            origin,
        }
    };
    let dir = output
        .parent()
        .ok_or_else(|| s::err("invalid plan parent"))?;
    let tmp = tempfile::tempdir_in(dir)?;
    let candidate = tmp.path().join("plan.json");
    s::write_json(&candidate, &proposal)?;
    fs::hard_link(&candidate, &output)?;
    if let Some(store) = &store {
        publish_latest(store, &output)?;
    }
    println!(
        "{} plan saved: {} (review before applying)",
        proposal.kind(),
        output.display()
    );
    Ok(())
}
fn latest(target: Option<&str>) -> Result<PathBuf> {
    let store = if let Some(target) = target {
        target_store(target)?
    } else {
        let root = s::workspace()?;
        s::check_store(&root)?;
        let store = root.join(".moss");
        s::private_dir(&store)?;
        let candidates: Vec<_> = fs::read_dir(store)?
            .filter_map(|entry| entry.ok())
            .filter(|entry| s::exists(&entry.path().join("latest")))
            .collect();
        s::ensure(
            candidates.len() == 1,
            "no unique latest plan; pass --target root@HOST or an explicit plan",
        )?;
        candidates[0].path()
    };
    s::private_dir(&store)?;
    let link = store.join("latest");
    s::ensure(
        fs::symlink_metadata(&link)?.file_type().is_symlink(),
        "latest must be a symlink to a plan",
    )?;
    let path = fs::read_link(link)?;
    s::private(&path)?;
    s::ensure(
        s::json::<Plan>(&path)?.target()
            == store.file_name().and_then(|s| s.to_str()).unwrap_or(""),
        "latest plan target differs from directory",
    )?;
    Ok(path)
}
pub fn apply(
    file: Option<&Path>,
    override_plan: Option<&Path>,
    target_hint: Option<&str>,
) -> Result<()> {
    s::ensure(
        file.is_none() || override_plan.is_none(),
        "pass either a positional plan or --plan, not both",
    )?;
    let path = match file.or(override_plan) {
        Some(p) => p.to_owned(),
        None => latest(target_hint)?,
    };
    s::private(&path)?;
    s::operator_path(&path)?;
    let plan: Plan = s::json(&path)?;
    s::ensure(
        target_hint.is_none_or(|t| plan.target() == t),
        "plan target differs from --target",
    )?;
    eprintln!(
        "Selected plan: {} ({} for {})",
        path.display(),
        plan.kind(),
        plan.target()
    );
    let (version, config_path, config_sha, origin) = match &plan {
        Plan::Install {
            version,
            config,
            config_sha256,
            origin,
            ..
        }
        | Plan::Update {
            version,
            config,
            config_sha256,
            origin,
            ..
        } => (version, config, config_sha256, origin),
    };
    s::ensure(*version == 1, "unknown plan version")?;
    let config_path = Path::new(config_path);
    let config = load_config(config_path)?;
    s::ensure(
        s::hash(config_path)? == *config_sha,
        "configuration changed; make a new plan",
    )?;
    s::ensure(
        s::git(Path::new(&config.repo), &["remote", "get-url", "origin"])?.trim() == origin,
        "Git origin changed; make a new plan",
    )?;
    match &plan {
        Plan::Install {
            target,
            disk,
            observed,
            machine_sha256,
            facter_sha256,
            ..
        } => {
            s::ensure(
                target == &observed.target && disk == &observed.disk.path,
                "plan target or disk differs from recorded facts",
            )?;
            s::ensure(
                s::hash(&Path::new(&config.machine).join("machine.nix"))? == *machine_sha256
                    && facter_sha(&config)? == *facter_sha256,
                "machine input or hardware report changed; make a new plan",
            )?;
            s::ensure(
                !s::exists(Path::new(&config.receipt)),
                "install receipt already exists; never reinstall",
            )?;
            s::ensure(
                config.disk.as_deref().is_none_or(|d| d == disk),
                "plan disk differs from configuration",
            )?;
            eprintln!(
                "Applying reviewed INSTALL plan to {target}: erase {disk} after typed confirmation"
            );
            install::install(&observed, &config)
        }
        Plan::Update {
            target, expected, ..
        } => crate::target::apply_reviewed(&config, origin, target, expected),
    }
}
