fn main() {
    if let Err(error) = instascanspeak::diagnostics_main() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
