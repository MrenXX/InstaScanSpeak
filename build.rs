fn main() {
    embed_manifest::embed_manifest_file("resources/app.manifest")
        .expect("Could not embed the native Windows visual-style manifest");
    println!("cargo:rerun-if-changed=resources/app.manifest");
}
