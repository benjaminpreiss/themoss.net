{ rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "moss";
  version = "0.1.0";
  src = ../.;
  cargoLock.lockFile = ../Cargo.lock;
  # Rust unit tests run during the Nix build; CI also runs command fixtures
  # against mocked external executables.
}
