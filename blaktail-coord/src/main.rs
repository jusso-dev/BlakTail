//! BlakTail coordination server — org control plane (stub).

const NAME: &str = "blaktail-coord";
const TAGLINE: &str = "Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.";

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("-h") | Some("--help") => print_help(),
        Some("-V") | Some("--version") => print_version(),
        Some(other) => {
            eprintln!("{NAME}: unrecognised argument '{other}'");
            eprintln!("Try '{NAME} --help' for more information.");
            std::process::exit(2);
        }
        None => {
            print_version();
            println!("{TAGLINE}");
        }
    }
}

fn print_version() {
    println!("{NAME} {}", env!("CARGO_PKG_VERSION"));
}

fn print_help() {
    println!("{NAME} {}", env!("CARGO_PKG_VERSION"));
    println!();
    println!("BlakTail coordination server for Indigenous organisations.");
    println!(
        "Prints the version and public tagline. The control-plane API is not yet implemented."
    );
    println!();
    println!("Usage:");
    println!("  {NAME} [OPTIONS]");
    println!();
    println!("Options:");
    println!("  -h, --help     Show this help");
    println!("  -V, --version  Show version only");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tagline_matches_public_contract() {
        assert_eq!(
            TAGLINE,
            "Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency."
        );
    }

    #[test]
    fn package_name_is_blaktail_coord() {
        assert_eq!(NAME, "blaktail-coord");
    }
}
