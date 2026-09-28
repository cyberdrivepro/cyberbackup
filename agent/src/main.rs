mod capabilities;
mod config;
mod database;
mod identity;
mod pairing;
mod platform;
mod process;
mod secrets;

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};
use std::{io::Read, path::PathBuf};

#[derive(Parser)]
#[command(version, about = "CyberVPS native local agent foundation (protocol 1)")]
struct Cli {
    /// Override current-user state directory.
    #[arg(long, global = true)]
    state_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Action,
}

#[derive(Subcommand)]
enum Action {
    Status,
    Doctor,
    /// Generate a local Ed25519 identity or show its public key.
    Identity,
    /// Issue or redeem a local, one-use controller pairing invitation.
    Pair {
        #[command(subcommand)]
        command: PairAction,
    },
    /// Execute an explicit program and argv without a shell.
    Exec {
        #[arg(long, default_value_t = 300)]
        timeout: u64,
        #[arg(long)]
        cwd: Option<PathBuf>,
        /// Explicit inherited environment variable names; other variables are cleared.
        #[arg(long = "env")]
        env_allowlist: Vec<String>,
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        argv: Vec<String>,
    },
    Nodes {
        #[command(subcommand)]
        command: NodeAction,
    },
    Secret {
        #[command(subcommand)]
        command: SecretAction,
    },
}

#[derive(Subcommand)]
enum PairAction {
    Create {
        #[arg(long, default_value_t = 300)]
        expires: u64,
    },
    Redeem {
        /// Read the invitation from stdin; never pass it in the process argv.
        #[arg(long)]
        controller: String,
        #[arg(long)]
        public_key: String,
    },
    Controllers,
    Revoke {
        controller: String,
    },
}

#[derive(Subcommand)]
enum NodeAction {
    List,
    Add { name: String, address: String },
    Remove { name: String },
}

#[derive(Subcommand)]
enum SecretAction {
    /// Read a secret value from stdin; refuses replacing an existing secret.
    Set {
        name: String,
    },
    Get {
        name: String,
        #[arg(long)]
        show: bool,
    },
    List,
    Delete {
        name: String,
    },
}

fn stdin_value(limit: u64) -> Result<Vec<u8>> {
    let mut value = Vec::new();
    std::io::stdin().take(limit + 1).read_to_end(&mut value)?;
    if value.is_empty() || value.len() as u64 > limit {
        bail!("stdin must contain between 1 and {limit} bytes");
    }
    Ok(value)
}

fn run() -> Result<i32> {
    let cli = Cli::parse();
    // Read-only status does not initialize identity, state, or a database.
    if matches!(cli.command, Action::Status | Action::Doctor) {
        println!("{}", serde_json::to_string_pretty(&capabilities::detect())?);
        return Ok(0);
    }
    let config = config::Config::new(cli.state_dir)?;
    let mut db = database::open(&config)?;
    match cli.command {
        Action::Identity => println!("{}", identity::public_key(&config)?),
        Action::Pair { command } => match command {
            PairAction::Create { expires } => {
                let public_key = identity::public_key(&config)?;
                let invitation = pairing::create(&mut db, expires)?;
                println!(
                    "{}",
                    serde_json::json!({"code": invitation, "expires_in_seconds": expires, "node_public_key": public_key, "scope": "local controller registration; no network listener"})
                );
            }
            PairAction::Redeem {
                controller,
                public_key,
            } => {
                let code = String::from_utf8(stdin_value(512)?)?;
                pairing::redeem(&mut db, code.trim(), &controller, &public_key)?;
                println!("Controller registered.");
            }
            PairAction::Controllers => println!("{}", database::controllers(&db)?),
            PairAction::Revoke { controller } => {
                db.execute(
                    "DELETE FROM trusted_controllers WHERE name=?1",
                    [&controller],
                )?;
                println!("Controller revoked.");
            }
        },
        Action::Exec {
            timeout,
            cwd,
            env_allowlist,
            argv,
        } => {
            let job_id = database::start_job(&db, &argv[0])?;
            let result = process::execute(&argv, cwd.as_deref(), timeout, &env_allowlist);
            match result {
                Ok(outcome) => {
                    database::finish_job(&db, job_id, outcome.code, outcome.timed_out)?;
                    return Ok(outcome.code);
                }
                Err(error) => {
                    database::fail_job(&db, job_id)?;
                    return Err(error);
                }
            }
        }
        Action::Nodes { command } => match command {
            NodeAction::List => println!("{}", database::nodes(&db)?),
            NodeAction::Add { name, address } => {
                config::validate_name(&name)?;
                if address.is_empty()
                    || address.len() > 2048
                    || address.chars().any(char::is_control)
                {
                    bail!("Invalid node address");
                }
                db.execute(
                    "INSERT INTO nodes(name,address,created_at) VALUES(?1,?2,?3)",
                    rusqlite::params![name, address, database::now()],
                )?;
                println!("Node registered (connectivity unverified).");
            }
            NodeAction::Remove { name } => {
                db.execute("DELETE FROM nodes WHERE name=?1", [&name])?;
                println!("Node removed.");
            }
        },
        Action::Secret { command } => match command {
            SecretAction::Set { name } => {
                secrets::put(&config, &name, &stdin_value(1024 * 1024)?)?;
                println!("Secret stored.");
            }
            SecretAction::Get { name, show } => {
                if !show {
                    bail!("Secret access requires explicit --show");
                }
                use std::io::Write;
                std::io::stdout().write_all(&secrets::get(&config, &name)?)?;
            }
            SecretAction::List => println!("{}", serde_json::to_string(&secrets::list(&config)?)?),
            SecretAction::Delete { name } => secrets::delete(&config, &name)?,
        },
        Action::Status | Action::Doctor => unreachable!(),
    }
    Ok(0)
}

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("cyberagent: {error:#}");
            std::process::exit(8);
        }
    }
}
