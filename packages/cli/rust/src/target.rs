//! Root-only target protocol for reviewed updates and pinned bootstrap. Only
//! a successful switch updates known-good revision and selector. Once a
//! switch begins, any failure leaves `needs-inspection` blocking automation.
use crate::{
    machine::{self, Config},
    safety::{self as s, Result},
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
    process::Command,
};

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Expected {
    pub current: String,
    pub selected: String,
    pub next: String,
    pub machine_sha256: String,
}
pub fn target_command(target: &str, action: &str, args: &[&str]) -> Result<String> {
    // The candidate system installs this binary through update.nix. A host
    // without the new binary refuses the operation rather than downgrading.
    let executable = "/run/current-system/sw/bin/moss";
    let command = std::iter::once(executable)
        .chain(["internal", action])
        .chain(args.iter().copied())
        .map(s::quote)
        .collect::<Vec<_>>()
        .join(" ");
    s::ssh(target, &command)
}
pub fn plan_update(config: &Config, origin: &str, target: &str) -> Result<Expected> {
    let raw = target_command(
        target,
        "plan-update",
        &[
            &config.remote_checkout,
            &config.remote_machine,
            &config.output,
            &config.remote_state,
            &config.branch,
            &config.revision,
            origin,
        ],
    )?;
    Ok(serde_json::from_str(&raw)?)
}
pub fn apply_reviewed(
    config: &Config,
    origin: &str,
    target: &str,
    expected: &Expected,
) -> Result<()> {
    s::ensure(
        expected.next == config.revision
            && expected.selected == format!("branch:{}", config.branch),
        "update plan differs from selected branch or revision",
    )?;
    s::ensure(
        s::hash(&Path::new(&config.machine).join("machine.nix"))? == expected.machine_sha256,
        "machine input changed; use a reviewed transition",
    )?;
    eprintln!(
        "Applying reviewed UPDATE {target}: {} -> {} (never erases disks)",
        expected.current, expected.next
    );
    let raw = target_command(
        target,
        "apply-reviewed",
        &[
            &config.remote_checkout,
            &config.remote_machine,
            &config.output,
            &config.remote_state,
            &expected.selected,
            &expected.current,
            &expected.next,
            &expected.machine_sha256,
            origin,
        ],
    )?;
    print!("{raw}");
    Ok(())
}
fn checked_target(
    repo: &Path,
    machine: &Path,
    host: &str,
    state: &Path,
) -> Result<(std::fs::File, String, String)> {
    s::ensure(
        s::dir(&repo.join(".git")) && s::dir(machine) && s::host(host),
        "invalid target inputs",
    )?;
    s::state_lock(state)
}
fn branch_tip(repo: &Path, branch: &str) -> Result<String> {
    s::ensure(s::branch(branch), "invalid branch")?;
    s::git(
        repo,
        &[
            "fetch",
            "--no-tags",
            "origin",
            &format!("refs/heads/{branch}"),
        ],
    )?;
    let next = s::git(repo, &["rev-parse", "FETCH_HEAD"])?
        .trim()
        .to_owned();
    s::ensure(
        s::hex(&next, 40) && s::git(repo, &["cat-file", "-t", &next])?.trim() == "commit",
        "invalid fetched tip",
    )?;
    Ok(next)
}
pub fn plan_update_local(args: &[String]) -> Result<()> {
    s::ensure(
        args.len() == 7,
        "plan-update requires repo machine host state branch revision origin",
    )?;
    let repo = Path::new(&args[0]);
    let machine = Path::new(&args[1]);
    let host = &args[2];
    let state = Path::new(&args[3]);
    let branch = &args[4];
    let rev = &args[5];
    let origin = &args[6];
    s::ensure(
        s::hex(rev, 40) && s::branch(branch),
        "invalid update inputs",
    )?;
    s::ensure(
        !origin.is_empty() && s::git(repo, &["remote", "get-url", "origin"])?.trim() == origin,
        "target Git origin changed",
    )?;
    let (_guard, current, selected) = checked_target(repo, machine, host, state)?;
    s::ensure(
        selected == format!("branch:{branch}"),
        "selected branch differs; transition requires separate operator review",
    )?;
    let next = branch_tip(repo, branch)?;
    s::ensure(&next == rev, "candidate differs from pushed branch tip")?;
    s::ensure(
        s::git_ok(repo, &["merge-base", "--is-ancestor", &current, &next])?,
        "diverged history; use reviewed transition",
    )?;
    s::private(&machine.join("machine.nix"))?;
    let machine_sha256 = s::hash(&machine.join("machine.nix"))?;
    let staged = tempfile::tempdir()?;
    machine::stage(repo, &next, machine, staged.path())?;
    machine::build(staged.path(), host)?;
    s::verify_tip(repo, branch, &next)?;
    println!(
        "{}",
        serde_json::to_string(&Expected {
            current,
            selected,
            next,
            machine_sha256
        })?
    );
    Ok(())
}
fn switch(
    repo: &Path,
    machine: &Path,
    host: &str,
    state: &Path,
    current: &str,
    selected: &str,
    next: &str,
    reviewed: Option<&Path>,
) -> Result<()> {
    let temp = tempfile::tempdir()?;
    let source = temp.path().join("source");
    fs::create_dir(&source)?;
    let stage_machine = if let Some(reviewed) = reviewed {
        let private = temp.path().join("private");
        fs::create_dir(&private)?;
        fs::copy(reviewed, private.join("machine.nix"))?;
        if s::file(&machine.join("facter.json")) {
            fs::copy(machine.join("facter.json"), private.join("facter.json"))?;
        }
        private
    } else {
        machine.to_owned()
    };
    machine::stage(repo, next, &stage_machine, &source)?;
    machine::build(&source, host)?;
    if let Some(branch) = selected.strip_prefix("branch:") {
        s::verify_tip(repo, branch, next)?;
    }
    s::write_new(
        &state.join("needs-inspection"),
        b"inspect generation and state before recovery\n",
    )?;
    s::status(Command::new("nixos-rebuild").args([
        "switch",
        "--flake",
        &format!("{}#{host}", source.display()),
        "--no-write-lock-file",
    ]))?;
    if let Some(reviewed) = reviewed {
        s::atomic(&machine.join("machine.nix"), &fs::read(reviewed)?)?;
    }
    s::atomic(&state.join("revision"), format!("{next}\n").as_bytes())?;
    s::atomic(&state.join("selector"), format!("{selected}\n").as_bytes())?;
    fs::remove_file(state.join("needs-inspection"))?;
    if reviewed.is_some() {
        fs::remove_dir_all(state.join("transition-incoming"))?;
    }
    println!("SWITCH OK {current} -> {next} ({selected})");
    Ok(())
}
pub fn apply_reviewed_local(args: &[String]) -> Result<()> {
    s::ensure(
        args.len() == 9,
        "apply-reviewed requires repo machine host state selector baseline candidate hash origin",
    )?;
    let repo = Path::new(&args[0]);
    let machine = Path::new(&args[1]);
    let host = &args[2];
    let state = Path::new(&args[3]);
    let requested = &args[4];
    let baseline = &args[5];
    let candidate = &args[6];
    let sha = &args[7];
    let origin = &args[8];
    s::ensure(
        requested.starts_with("branch:")
            && s::reference(requested)
            && s::hex(baseline, 40)
            && s::hex(candidate, 40)
            && s::hex(sha, 64),
        "invalid reviewed update",
    )?;
    s::ensure(
        s::git(repo, &["remote", "get-url", "origin"])?.trim() == origin,
        "target Git origin changed",
    )?;
    let (_guard, current, selected) = checked_target(repo, machine, host, state)?;
    s::ensure(
        &current == baseline && &selected == requested,
        "installed baseline or selector changed; make a new plan",
    )?;
    s::ensure(
        s::file(&machine.join("machine.nix")) && s::hash(&machine.join("machine.nix"))? == *sha,
        "private machine input changed",
    )?;
    let branch = requested.trim_start_matches("branch:");
    let next = branch_tip(repo, branch)?;
    s::ensure(&next == candidate, "pushed tip changed; make a new plan")?;
    s::ensure(
        s::git_ok(repo, &["merge-base", "--is-ancestor", &current, &next])?,
        "diverged history; use reviewed transition",
    )?;
    if next == current {
        println!("Already at {current}");
        return Ok(());
    }
    switch(repo, machine, host, state, &current, requested, &next, None)
}
pub fn deploy_local(args: &[String], task: &str) -> Result<()> {
    let expected = match task {
        "poll" => 4,
        "deploy" => 5,
        "apply-transition" => 8,
        _ => return Err(s::err("unknown deployment")),
    };
    s::ensure(args.len() == expected, "invalid deployment arguments")?;
    let repo = Path::new(&args[0]);
    let (requested_offset, branch_name) = if task == "deploy" {
        (1, None)
    } else if task == "apply-transition" {
        (1, Some(args[1].as_str()))
    } else {
        (0, None)
    };
    let machine = Path::new(&args[1 + requested_offset]);
    let host = &args[2 + requested_offset];
    let state = Path::new(&args[3 + requested_offset]);
    let (_guard, current, selected) = checked_target(repo, machine, host, state)?;
    if task == "poll" && !selected.starts_with("branch:") {
        return Ok(());
    }
    let requested = if let Some(branch) = branch_name {
        format!("branch:{branch}")
    } else if task == "deploy" {
        args[1].clone()
    } else {
        selected.clone()
    };
    s::ensure(s::reference(&requested), "invalid selected reference")?;
    let reviewed = if task == "apply-transition" {
        let reviewed = Path::new(&args[5]);
        s::ensure(
            reviewed == state.join("transition-incoming/machine.nix")
                && args[6] == current
                && s::hex(&args[7], 64),
            "invalid transition baseline",
        )?;
        s::ensure(
            s::file(reviewed)
                && s::file(&machine.join("machine.nix"))
                && s::hash(&machine.join("machine.nix"))? == args[7],
            "machine facts changed since install",
        )?;
        s::private_dir(&state.join("transition-incoming"))?;
        Some(reviewed)
    } else {
        None
    };
    let next = if let Some(branch) = requested.strip_prefix("branch:") {
        let next = branch_tip(repo, branch)?;
        if reviewed.is_none() {
            s::ensure(
                s::git_ok(repo, &["merge-base", "--is-ancestor", &current, &next])?,
                "diverged history; use reviewed transition",
            )?;
        }
        next
    } else {
        let rev = requested.trim_start_matches("commit:");
        s::ensure(
            s::git(repo, &["cat-file", "-t", rev])?.trim() == "commit",
            "commit missing locally",
        )?;
        s::ensure(
            rev == current || selected == format!("commit:{current}"),
            "new baseline requires reviewed transition",
        )?;
        rev.to_owned()
    };
    if next == current && requested == selected && reviewed.is_none() {
        println!("Already at {next}");
        return Ok(());
    }
    switch(
        repo, machine, host, state, &current, &requested, &next, reviewed,
    )
}
pub fn prepare_transition_local(args: &[String]) -> Result<()> {
    s::ensure(args.len() == 5, "invalid transition arguments")?;
    let repo = Path::new(&args[0]);
    let machine = Path::new(&args[1]);
    let state = Path::new(&args[2]);
    let rev = &args[3];
    let sha = &args[4];
    s::ensure(
        s::dir(&repo.join(".git")) && s::dir(machine) && s::hex(rev, 40) && s::hex(sha, 64),
        "invalid transition inputs",
    )?;
    let (_guard, current, _selected) = s::state_lock(state)?;
    s::ensure(
        current == *rev
            && s::file(&machine.join("machine.nix"))
            && s::hash(&machine.join("machine.nix"))? == *sha,
        "baseline or machine facts differ from installed input",
    )?;
    let upload = state.join("transition-incoming");
    s::create_private_dir(&upload)?;
    let proposal = upload.join("machine.nix");
    if s::exists(&proposal) {
        s::ensure(s::file(&proposal), "linked proposal")?;
        fs::remove_file(proposal)?;
    }
    Ok(())
}
/// Bootstrap is two phases so an interrupted upload remains retryable and
/// does not mutate live private inputs or the pinned selector.
pub fn bootstrap_local(args: &[String], phase: &str) -> Result<()> {
    s::ensure(
        args.len() == 6 && matches!(phase, "prepare" | "finish"),
        "invalid bootstrap arguments",
    )?;
    let url = &args[0];
    let rev = &args[1];
    let repo = Path::new(&args[2]);
    let machine = Path::new(&args[3]);
    let state = Path::new(&args[4]);
    let branch = &args[5];
    s::ensure(
        s::hex(rev, 40) && s::branch(branch) && !url.starts_with('-') && !url.contains('\n'),
        "invalid receipt origin or revision",
    )?;
    for p in [repo, machine, state] {
        s::ensure(
            s::remote_path(&p.to_string_lossy()) && !p.is_symlink(),
            "unsafe target path",
        )?;
    }
    s::ensure(
        !repo.starts_with(state)
            && !machine.starts_with(state)
            && !repo.starts_with(machine)
            && !machine.starts_with(repo),
        "overlapping paths",
    )?;
    if !s::exists(state) {
        fs::create_dir_all(state)?;
        fs::set_permissions(state, fs::Permissions::from_mode(0o700))?;
    }
    s::private_dir(state)?;
    let test = std::env::var("THEMOSS_TEST_ROOT").as_deref() == Ok("1");
    s::ensure(unsafe { libc::geteuid() } == 0 || test, "root required")?;
    s::ensure(
        fs::metadata(state)?.uid() == 0 || test,
        "state must be root-owned",
    )?;
    let lock = state.join("lock");
    s::ensure(!s::exists(&lock) || s::file(&lock), "linked lock")?;
    use fs2::FileExt;
    use std::os::unix::fs::OpenOptionsExt;
    let locked = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .mode(0o600)
        .open(lock)?;
    locked.try_lock_exclusive()?;
    s::ensure(
        !s::exists(&state.join("needs-inspection")),
        "switch requires inspection",
    )?;
    for name in ["selector", "revision", "incoming"] {
        s::ensure(!state.join(name).is_symlink(), "linked state")?;
    }
    if s::exists(&state.join("selector")) {
        s::private(&state.join("selector"))?;
        s::ensure(
            fs::read_to_string(state.join("selector"))?.trim() == format!("commit:{rev}"),
            "selector differs from installed commit",
        )?;
    }
    if s::exists(&state.join("revision")) {
        s::ensure(
            s::file(&state.join("revision"))
                && fs::read_to_string(state.join("revision"))?.trim() == rev,
            "different known-good revision",
        )?;
    }
    if s::exists(repo) {
        s::ensure(
            s::dir(&repo.join(".git"))
                && s::git(repo, &["remote", "get-url", "origin"])?.trim() == url
                && s::git(repo, &["rev-parse", "HEAD"])?.trim() == rev,
            "checkout does not match installed commit/origin",
        )?;
    }
    let incoming = state.join("incoming");
    if phase == "prepare" {
        if !s::exists(&incoming) {
            fs::create_dir(&incoming)?;
            fs::set_permissions(&incoming, fs::Permissions::from_mode(0o700))?;
        }
        s::private_dir(&incoming)?;
        for name in ["machine.nix", "facter.json"] {
            if s::exists(&incoming.join(name)) {
                s::ensure(s::file(&incoming.join(name)), "linked upload")?;
                fs::remove_file(incoming.join(name))?;
            }
        }
        return Ok(());
    }
    s::ensure(
        s::file(&incoming.join("machine.nix")),
        "missing machine.nix upload",
    )?;
    for name in ["machine.nix", "facter.json"] {
        let source = incoming.join(name);
        let dest = machine.join(name);
        if !s::exists(&source) {
            s::ensure(!s::exists(&dest), "unexpected existing private file")?;
            continue;
        }
        s::ensure(s::file(&source), "invalid uploaded file")?;
        if s::exists(&dest) {
            s::ensure(
                s::file(&dest) && fs::read(&source)? == fs::read(&dest)?,
                "different existing machine file",
            )?;
        }
    }
    if !s::exists(repo) {
        let temp = state.join("checkout.tmp");
        if s::exists(&temp) {
            s::ensure(s::dir(&temp), "linked checkout temporary directory")?;
            fs::remove_dir_all(&temp)?;
        }
        s::status(
            Command::new("git")
                .args([
                    "clone",
                    "--no-checkout",
                    "--single-branch",
                    "--branch",
                    branch,
                    "--",
                    url,
                ])
                .arg(&temp),
        )?;
        s::ensure(
            s::git_ok(
                &temp,
                &[
                    "merge-base",
                    "--is-ancestor",
                    rev,
                    &format!("origin/{branch}"),
                ],
            )?,
            "installed commit not on fetched branch",
        )?;
        s::git(&temp, &["checkout", "--detach", rev])?;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o700))?;
        fs::create_dir_all(
            repo.parent()
                .ok_or_else(|| s::err("invalid checkout parent"))?,
        )?;
        s::ensure(!s::exists(repo), "checkout appeared during bootstrap")?;
        fs::rename(temp, repo)?;
    }
    if !s::exists(machine) {
        fs::create_dir_all(machine)?;
        fs::set_permissions(machine, fs::Permissions::from_mode(0o700))?;
    }
    s::private_dir(machine)?;
    for name in ["machine.nix", "facter.json"] {
        let source = incoming.join(name);
        let dest = machine.join(name);
        if s::file(&source) && !s::exists(&dest) {
            s::atomic(&dest, &fs::read(source)?)?;
        }
    }
    s::atomic(
        &state.join("selector"),
        format!("commit:{rev}\n").as_bytes(),
    )?;
    s::atomic(&state.join("revision"), format!("{rev}\n").as_bytes())?;
    fs::remove_dir_all(incoming)?;
    println!("Bootstrapped installed revision {rev}; timer policy unchanged");
    Ok(())
}
