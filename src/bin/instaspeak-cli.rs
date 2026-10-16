fn main() {
    if let Err(error) = instaspeak::diagnostics_main() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
