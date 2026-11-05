{ rustPlatform, git }:
rustPlatform.buildRustPackage {
  pname = "moss";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  # Cargo tests exercise parsing and off-host file gates; the mocked deployment
  # lifecycle is also run separately by tests/rust-lifecycle.sh.
  doCheck = true;
  nativeCheckInputs = [ git ];
}
