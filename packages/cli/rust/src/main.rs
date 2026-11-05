//! Rust implementation of the public moss interface, migrated operation by operation.
//! The active executable stays in bin/moss until every operation and the
//! target-side protocol pass the existing lifecycle fixtures.
mod handoff;
mod init;
mod install;
mod machine;
mod operator;
mod safety;
mod target;
use clap::{CommandFactory, Parser, Subcommand};
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
    /// Generate the committed CLI reference directly from clap help.
    #[command(hide = true)]
    Reference,
    #[command(hide = true)]
    Internal {
        operation: String,
        #[arg(num_args = 0.., allow_hyphen_values = true)]
        args: Vec<String>,
    },
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
    // No secrets in operator-generated files may become group-readable.
    unsafe {
        libc::umask(0o077);
    }
    let result = match Cli::parse().action {
        Action::Init => init::run().map_err(Into::into),
        Action::Reference => {
            reference();
            Ok(())
        }
        Action::Machine { action } => match action {
            MachineAction::Plan {
                target,
                config,
                disk,
                output,
            } => operator::plan(
                &target,
                config.as_deref(),
                disk.as_deref(),
                output.as_deref(),
            ),
            MachineAction::Apply { file, plan, target } => {
                operator::apply(file.as_deref(), plan.as_deref(), target.as_deref())
            }
            MachineAction::Bootstrap { receipt, config } => {
                handoff::bootstrap(&receipt, config.as_deref())
            }
        },
        Action::Internal { operation, args } => internal(&operation, &args),
    };
    if let Err(error) = result {
        eprintln!("moss: {error}");
        std::process::exit(1);
    }
}

fn reference() {
    println!("# moss CLI reference\n");
    println!("> Generated from clap help. For destructive-operation safeguards and recovery, follow the [machine guide](../packages/cli/src/machine/README.md#install-a-machine), not this command list.\n");
    let mut root = Cli::command();
    for (index, path) in [
        &[][..],
        &["init"][..],
        &["machine"][..],
        &["machine", "plan"][..],
        &["machine", "apply"][..],
        &["machine", "bootstrap"][..],
    ]
    .into_iter()
    .enumerate()
    {
        if index > 0 {
            println!();
        }
        let name = format!(
            "moss{}",
            path.iter()
                .map(|part| format!(" {part}"))
                .collect::<String>()
        );
        let mut cmd = &mut root;
        for part in path {
            cmd = cmd.find_subcommand_mut(part).expect("documented command");
        }
        println!(
            "## `{name}`\n\n```text\n{}\n```",
            cmd.clone().bin_name(name.clone()).render_long_help()
        );
    }
}

fn internal(operation: &str, args: &[String]) -> safety::Result<()> {
    use std::path::Path;
    match operation {
        "plan-update" => target::plan_update_local(args),
        "apply-reviewed" => target::apply_reviewed_local(args),
        "poll" | "deploy" | "apply-transition" => target::deploy_local(args, operation),
        "prepare-transition" => target::prepare_transition_local(args),
        "bootstrap-prepare" => target::bootstrap_local(args, "prepare"),
        "bootstrap-finish" => target::bootstrap_local(args, "finish"),
        "adopt" if args.len() == 7 => handoff::adopt(
            Path::new(&args[0]),
            Path::new(&args[1]),
            Path::new(&args[2]),
            &args[3],
            &args[4],
            &args[5],
            &args[6],
        ),
        "transition" if args.len() == 8 => handoff::transition(
            Path::new(&args[0]),
            &args[1],
            &args[2],
            &args[3],
            Path::new(&args[4]),
            &args[5],
            &args[6],
            &args[7],
        ),
        _ => Err(safety::err(
            "unknown internal operation or invalid arguments",
        )),
    }
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
