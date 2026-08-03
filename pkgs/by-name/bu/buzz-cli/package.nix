{
  cacert,
  fetchFromGitHub,
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "buzz-cli";
  version = "0.1.0-unstable-2026-08-02";
  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "7ff5fc31895efe6265a379d01637c8ee301872e5";
    hash = "sha256-ZvoM4TSD7khIcamYXWVZiUjHYonF0nREJ5wWGfKlcz8=";
  };

  cargoHash = "sha256-tolEndhaUSJkBzShuLHMAeucCf2QDnlKRBaHPhOHrnw=";
  cargoBuildFlags = [ "--package=buzz-cli" ];
  cargoTestFlags = [ "--package=buzz-cli" ];

  nativeCheckInputs = [ cacert ];

  meta = {
    description = "Agent-first CLI for Buzz relay";
    homepage = "https://github.com/block/buzz";
    license = lib.licenses.asl20;
    mainProgram = "buzz";
    maintainers = [ lib.maintainers.sebfried ];
    platforms = lib.platforms.linux;
  };
}
