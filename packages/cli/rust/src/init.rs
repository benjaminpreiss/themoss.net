use std::{
    fs, io,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Command,
};

/// Initialize the same operator-local store as the existing moss init command.
/// No consumer configuration is read and no target is contacted.
pub fn run() -> io::Result<()> {
    let current = std::env::current_dir()?;
    let workspace = git_root(&current)?.unwrap_or(current);
    let store = workspace.join(".moss");
    if !store.exists()
        && fs::symlink_metadata(&store).is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
    {
        fs::create_dir(&store)?;
        fs::set_permissions(&store, fs::Permissions::from_mode(0o700))?;
    }
    validate_store(&store)?;
    println!(
        "Initialized {} (operator-local; no configuration, plan or installer run).",
        store.display()
    );
    if git_root(&workspace)?.is_some() {
        let tracked = git(&workspace, &["ls-files", "--", ".moss"])?;
        if !tracked.is_empty() {
            return Err(invalid(
                "remove tracked .moss files from Git before using moss",
            ));
        }
        if !git_success(
            &workspace,
            &["check-ignore", "-q", "--no-index", "--", ".moss/"],
        )? {
            eprintln!(
                "Before planning, add .moss/ to {}/.gitignore and commit the ignore rule.",
                workspace.display()
            );
        }
    } else {
        eprintln!(
            "Not in a Git checkout. If this directory later enters Git, ignore .moss/ before using moss."
        );
    }
    Ok(())
}

fn validate_store(store: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(store)?;
    if meta.file_type().is_symlink() {
        return Err(invalid("refusing linked .moss directory"));
    }
    if !meta.is_dir() || meta.permissions().mode() & 0o7777 != 0o700 {
        return Err(invalid(".moss must be a mode-700 directory"));
    }
    Ok(())
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
fn git_root(path: &Path) -> io::Result<Option<PathBuf>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--show-toplevel"])
        .output()?;
    if output.status.success() {
        let root = String::from_utf8(output.stdout).map_err(|e| invalid(&e.to_string()))?;
        let path = PathBuf::from(root.trim_end());
        let meta = fs::symlink_metadata(&path)?;
        if !meta.is_dir() || meta.file_type().is_symlink() {
            return Err(invalid("unsafe operator directory"));
        }
        Ok(Some(path))
    } else {
        Ok(None)
    }
}
fn git(path: &Path, args: &[&str]) -> io::Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .output()?;
    if !output.status.success() {
        return Err(invalid("Git check failed"));
    }
    String::from_utf8(output.stdout).map_err(|e| invalid(&e.to_string()))
}
fn git_success(path: &Path, args: &[&str]) -> io::Result<bool> {
    Ok(Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .status()?
        .success())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn existing_store_must_not_be_a_link() {
        let root = std::env::temp_dir().join(format!("moss-init-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        symlink(&root, root.join(".moss")).unwrap();
        assert!(validate_store(&root.join(".moss")).is_err());
        fs::remove_file(root.join(".moss")).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
