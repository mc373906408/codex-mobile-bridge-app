fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // Cargokit sets CARGO_ENCODED_RUSTFLAGS, which overrides .cargo/config.toml.
        println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");
    }
}
