//! Inactive clap command-tree preview for the current public CLI.
//!
//! No operation is dispatched yet: this must not replace bin/moss until the
//! plan/apply/bootstrap implementations and lifecycle fixtures have migrated.
use clap::{Parser, Subcommand};
use std::path::PathBuf;

/// Initialize local storage and plan reviewed changes to a themoss machine.
#[derive(Debug, Parser)]
#[command(name = "moss", version, about)]
struct Cli {
    #[command(subcommand)]
    action: Action,
}

#[derive(Debug, Subcommand)]
enum Action {
    /// Create operator-local .moss in the current directory or Git ancestor.
    Init,
    /// Operate on a machine.
    Machine {
        #[command(subcommand)]
        action: MachineAction,
    },
}

#[derive(Debug, Subcommand)]
enum MachineAction {
    /// Inspect the target and build a non-destructive reviewed installation plan.
    Plan {
        /// Known rescue SSH target (verify host key independently).
        target: String,
        /// Override the default per-target configuration file.
        #[arg(long, value_name = "FILE")]
        config: Option<PathBuf>,
        /// Choose a whole disk explicitly; otherwise detect during guided install.
        #[arg(long, value_name = "DISK")]
        disk: Option<String>,
        /// New plan file; defaults to this target's .moss/plans directory.
        #[arg(long, value_name = "FILE")]
        output: Option<PathBuf>,
    },
    /// Revalidate and apply a reviewed plan; installation erases the selected disk.
    Apply {
        /// Explicit plan path (also accepted for existing scripts).
        file: Option<PathBuf>,
        /// Explicit plan path instead of the latest managed plan.
        #[arg(long, value_name = "FILE")]
        plan: Option<PathBuf>,
        /// Choose a target when the checkout has multiple plans.
        #[arg(long, value_name = "ROOT@HOST")]
        target: Option<String>,
    },
    /// Resume first-boot handoff after independently verifying the new SSH host key.
    Bootstrap {
        /// Off-host installation receipt.
        receipt: PathBuf,
        /// Original private machine configuration; defaults to .moss for the receipt target.
        #[arg(long, value_name = "FILE")]
        config: Option<PathBuf>,
    },
}

fn main() {
    let _ = Cli::parse();
    eprintln!("moss Rust preview: no operations are implemented; use the existing bin/moss");
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_public_command_shapes_parse() {
        for args in [
            vec!["moss", "init"],
            vec!["moss", "machine", "plan", "root@host"],
            vec![
                "moss",
                "machine",
                "plan",
                "root@host",
                "--disk",
                "/dev/vda",
                "--config",
                "/tmp/machine.json",
                "--output",
                "/tmp/plan.json",
            ],
            vec!["moss", "machine", "apply"],
            vec!["moss", "machine", "apply", "/tmp/plan.json"],
            vec![
                "moss",
                "machine",
                "apply",
                "--target",
                "root@host",
                "--plan",
                "/tmp/plan.json",
            ],
            vec![
                "moss",
                "machine",
                "bootstrap",
                "/tmp/receipt.json",
                "--config",
                "/tmp/machine.json",
            ],
        ] {
            Cli::try_parse_from(args.clone()).unwrap_or_else(|e| panic!("{args:?}: {e}"));
        }
    }

    #[test]
    fn operations_requiring_arguments_reject_missing_values() {
        for args in [
            vec!["moss", "machine", "plan"],
            vec!["moss", "machine", "bootstrap"],
            vec!["moss", "machine", "apply", "--plan"],
        ] {
            assert!(Cli::try_parse_from(args).is_err());
        }
    }
}
