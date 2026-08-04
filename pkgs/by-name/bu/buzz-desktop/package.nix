{
  apple-sdk_14,
  appimageTools,
  cargo-tauri,
  cmake,
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchurl,
  gitMinimal,
  lib,
  libiconv,
  nodejs_24,
  pnpm_11,
  pnpmConfigHook,
  rcodesign,
  rustPlatform,
  stdenv,
  writeText,
}:

let
  pname = "buzz-desktop";
  version = "0.5.4";

  linuxSrc = fetchurl {
    url = "https://github.com/block/buzz/releases/download/desktop-v${version}/Buzz_${version}_amd64.AppImage";
    hash = "sha256-Aho/xwEzJk9eDFtE2SYmt1Egsdm2REOstXa6jYwAnME=";
  };

  darwinSrc = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    tag = "desktop-v${version}";
    hash = "sha256-nTEq0edrcTIFw0Wn4J/BuhgYM/9xAZe0HBWiYMsu50Q=";
  };

  # The desktop crate and the sidecars use separate Cargo workspaces. Reuse
  # the fixed-output release sidecars instead of vendoring and building both.
  darwinSidecars = fetchurl {
    url = "https://github.com/block/buzz/releases/download/desktop-v${version}/Buzz_${version}_aarch64.app.tar.gz";
    hash = "sha256-srsx/kFKBsDstY4XNy+iKJwoxkswJkUwutUBVtg5tcA=";
  };

  sidecars = [
    "buzz"
    "buzz-acp"
    "buzz-agent"
    "buzz-backend-kubernetes"
    "buzz-dev-mcp"
    "git-credential-nostr"
  ];

  sidecarEntitlementFlags = lib.concatMapStringsSep " " (
    sidecar: "--entitlements-xml-file Contents/MacOS/${sidecar}:${emptyEntitlements}"
  ) sidecars;

  emptyEntitlements = writeText "buzz-empty-entitlements.plist" (
    lib.generators.toPlist { escape = true; } { }
  );

  mainEntitlements = writeText "buzz-main-entitlements.plist" (
    lib.generators.toPlist { escape = true; } {
      "com.apple.security.device.audio-input" = true;
      "com.apple.security.device.camera" = true;
    }
  );

  commonMeta = {
    description = "Workspace where humans and AI agents build together";
    homepage = "https://buzz.xyz";
    changelog = "https://github.com/block/buzz/releases/tag/desktop-v${version}";
    license = lib.licenses.asl20;
    mainProgram = "buzz-desktop";
    maintainers = [ lib.maintainers.sebfried ];
    platforms = [
      "aarch64-darwin"
      "x86_64-linux"
    ];
  };

  linuxContents = appimageTools.extract {
    inherit pname version;
    src = linuxSrc;

    postExtract = ''
      substituteInPlace $out/usr/bin/buzz-desktop \
        --replace-fail \
          'exec -a "buzz-desktop" "$here/buzz-desktop.bin" "$@"' \
          'unset APPIMAGE; export GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib64/gstreamer-1.0; exec -a "buzz-desktop" "$here/buzz-desktop.bin" "$@"'
    '';
  };

  linuxPackage = appimageTools.wrapAppImage {
    inherit pname version;
    src = linuxContents;

    extraPkgs =
      pkgs: with pkgs; [
        elfutils.out
        ffmpeg
        git
        gst_all_1.gst-plugins-good
        gst_all_1.gst-plugins-bad
        gst_all_1.gst-libav
        zstd.out
      ];

    extraInstallCommands = ''
      install -Dm444 ${linuxContents}/usr/share/applications/Buzz.desktop \
        $out/share/applications/buzz-desktop.desktop
      substituteInPlace $out/share/applications/buzz-desktop.desktop \
        --replace-fail "Exec=buzz-desktop" "Exec=buzz-desktop %u" \
        --replace-fail "Categories=" "Categories=Network;Chat;"
      cp -r ${linuxContents}/usr/share/icons $out/share/
    '';

    passthru.src = linuxSrc;

    meta = commonMeta // {
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  darwinPackage = rustPlatform.buildRustPackage (finalAttrs: {
    inherit pname version;
    src = darwinSrc;
    __structuredAttrs = true;
    strictDeps = true;
    # Preserve the imported sidecars; strip only the source-built main binary.
    dontStrip = true;

    cargoRoot = "desktop/src-tauri";
    buildAndTestSubdir = finalAttrs.cargoRoot;
    cargoHash = "sha256-OzEMJskMpo8J6HjYwF12dhALpfDHvZ05hI6mAINbDT4=";

    pnpmDeps = fetchPnpmDeps {
      inherit pname version;
      src = darwinSrc;
      pnpm = pnpm_11;
      fetcherVersion = 4;
      hash = "sha256-Tboy+MG/VvdxUpJw7Xv0oubK58MIpvChvbU30uO4M4A=";
    };

    nativeBuildInputs = [
      cargo-tauri.hook
      cmake
      nodejs_24
      pnpm_11
      pnpmConfigHook
      rcodesign
    ];

    buildInputs = [
      apple-sdk_14
      libiconv
    ];

    nativeCheckInputs = [ gitMinimal ];

    postPatch = ''
      # Cargo includes external path dependency locations in crate metadata.
      # Point them at the fixed-output source instead of the random build root.
      substituteInPlace desktop/src-tauri/Cargo.toml \
        --replace-fail 'path = "../../crates/' 'path = "${darwinSrc}/crates/'
      test "$(grep -cF 'path = "${darwinSrc}/crates/' desktop/src-tauri/Cargo.toml)" -eq 6

      sidecarSource=$(mktemp -d)
      tar -xzf ${darwinSidecars} -C "$sidecarSource"
      for sidecar in ${lib.escapeShellArgs sidecars}; do
        install -Dm755 \
          "$sidecarSource/Buzz.app/Contents/MacOS/$sidecar" \
          "desktop/src-tauri/binaries/$sidecar-${stdenv.hostPlatform.rust.rustcTarget}"
      done

      # Nix owns updates. Do not expose updater commands or report this
      # immutable installation as self-update capable.
      substituteInPlace desktop/src-tauri/src/commands/updater.rs \
        --replace-fail '        true' '        false'
      for permission in \
        updater:allow-check \
        updater:allow-download \
        updater:allow-install
      do
        substituteInPlace desktop/src-tauri/capabilities/default.json \
          --replace-fail "    \"$permission\"," ""
      done

      # The Nix build intentionally omits the optional mesh-llm feature.
      # Hide controls that would otherwise lead only to upstream's stubs.
      substituteInPlace desktop/src/features/settings/ui/SettingsPanels.tsx \
        --replace-fail '  Cpu,' "" \
        --replace-fail '  | "compute"' "" \
        --replace-fail '  "compute",' "" \
        --replace-fail 'import { MeshComputeSettingsCard } from "@/features/mesh-compute/ui/MeshComputeSettingsCard";' "" \
        --replace-fail $'  {\n    value: "compute",\n    label: "Compute",\n    icon: Cpu,\n  },' "" \
        --replace-fail $'    case "compute":\n      return <MeshComputeSettingsCard />;' ""
      substituteInPlace desktop/src/features/agents/ui/agentConfigOptions.tsx \
        --replace-fail '  { id: "relay-mesh", label: "Buzz shared compute" },' ""
      substituteInPlace desktop/src/features/settings/ui/SettingsView.tsx \
        --replace-fail '    sections: ["agents", "compute", "experimental", "mobile", "updates"],' \
          '    sections: ["agents", "experimental", "mobile", "updates"],'

      # Match the bundle metadata to Nixpkgs' toolchain compatibility floor.
      substituteInPlace desktop/src-tauri/tauri.conf.json \
        --replace-fail '    "macOS": {' \
          $'    "macOS": {\n      "minimumSystemVersion": "${stdenv.hostPlatform.darwinMinVersion}",'

      # The workspace path is only useful for locally built development
      # sidecars. Packaged releases discover sidecars beside the executable.
      substituteInPlace desktop/src-tauri/src/managed_agents/discovery.rs \
        --replace-fail 'fn workspace_root_dir()' \
          $'#[cfg(debug_assertions)]\nfn workspace_root_dir()' \
        --replace-fail \
          '    let mut dirs = profile_target_dirs(&workspace_root_dir()).to_vec();' \
          $'    let mut dirs = Vec::new();\n    #[cfg(debug_assertions)]\n    dirs.extend(profile_target_dirs(&workspace_root_dir()));'

      # Upstream gates these test helpers on debug_assertions, but Nix runs
      # tests with the release profile. Keep production behavior unchanged.
      substituteInPlace desktop/src-tauri/src/managed_agents/storage.rs \
        --replace-fail $'#[cfg(debug_assertions)]\nconst DEV_MIGRATION_MARKER' \
          $'#[cfg(any(debug_assertions, test))]\nconst DEV_MIGRATION_MARKER' \
        --replace-fail $'#[cfg(debug_assertions)]\nfn copy_agent_keys_between_stores' \
          $'#[cfg(any(debug_assertions, test))]\nfn copy_agent_keys_between_stores'
    '';

    preBuild = ''
      export NIX_RUSTFLAGS="--remap-path-prefix=${darwinSrc}=/build/upstream --remap-path-prefix=$NIX_BUILD_TOP=/build ''${NIX_RUSTFLAGS:-}"
      export NIX_CFLAGS_COMPILE="-ffile-prefix-map=${darwinSrc}=/build/upstream -fdebug-prefix-map=${darwinSrc}=/build/upstream -fmacro-prefix-map=${darwinSrc}=/build/upstream -ffile-prefix-map=$NIX_BUILD_TOP=/build -fdebug-prefix-map=$NIX_BUILD_TOP=/build -fmacro-prefix-map=$NIX_BUILD_TOP=/build ''${NIX_CFLAGS_COMPILE:-}"
      unset \
        BUZZ_UPDATER_ENDPOINT \
        BUZZ_UPDATER_PUBLIC_KEY \
        TAURI_SIGNING_PRIVATE_KEY \
        TAURI_SIGNING_PRIVATE_KEY_PASSWORD
    '';

    tauriBuildFlags = [ "--no-sign" ];

    postInstall = ''
      mkdir -p "$out/bin"
      ln -s ../Applications/Buzz.app/Contents/MacOS/buzz-desktop \
        "$out/bin/buzz-desktop"
    '';

    # Sign after every fixup so the complete bundle and its resources are
    # sealed. Sidecars need no camera, microphone, or library entitlements.
    postFixup = ''
      main="$out/Applications/Buzz.app/Contents/MacOS/buzz-desktop"
      strip -S "$main"
      install_name_tool -change \
        ${libiconv}/lib/libiconv.2.dylib \
        /usr/lib/libiconv.2.dylib \
        "$main"

      rcodesign sign \
        --code-signature-flags main:runtime \
        --code-signature-flags Contents/MacOS/buzz-desktop:runtime \
        --entitlements-xml-file Contents/MacOS/buzz-desktop:${mainEntitlements} \
        ${sidecarEntitlementFlags} \
        "$out/Applications/Buzz.app"
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      for binary in buzz-desktop ${lib.escapeShellArgs sidecars}; do
        test -x "$out/Applications/Buzz.app/Contents/MacOS/$binary"
      done
      test "$(find "$out/Applications/Buzz.app/Contents/MacOS" -type f | wc -l | tr -d ' ')" -eq 7
      if grep -q 'updater:allow-' desktop/src-tauri/capabilities/default.json; then
        echo "Updater capabilities remain enabled" >&2
        exit 1
      fi
      main="$out/Applications/Buzz.app/Contents/MacOS/buzz-desktop"
      strings "$main" > buzz-desktop.strings
      if grep -Fq 'buzz-desktop-latest/latest.json' buzz-desktop.strings; then
        echo "Updater endpoint remains embedded" >&2
        exit 1
      fi
      if grep -Eq '/nix/var/nix/builds/|/private/tmp/nix-build-|/tmp/nix-build-' buzz-desktop.strings; then
        echo "Build directory remains embedded" >&2
        exit 1
      fi
      if grep -Fq '${darwinSrc}' buzz-desktop.strings; then
        echo "Source store path remains embedded" >&2
        exit 1
      fi

      otool -L "$main" > buzz-desktop-libraries
      grep -Fq '/usr/lib/libiconv.2.dylib' buzz-desktop-libraries
      sed '1d' buzz-desktop-libraries > buzz-desktop-dependencies
      if grep -Fq '/nix/store/' buzz-desktop-dependencies; then
        echo "Nix store library remains linked" >&2
        exit 1
      fi

      otool -l "$main" > buzz-desktop-build-version
      grep -Fq 'minos ${stdenv.hostPlatform.darwinMinVersion}' buzz-desktop-build-version
      grep -A1 LSMinimumSystemVersion \
        "$out/Applications/Buzz.app/Contents/Info.plist" \
        | grep -Fq '<string>${stdenv.hostPlatform.darwinMinVersion}</string>'

      rcodesign print-signature-info "$main" > buzz-desktop-signature
      grep -Fq 'flags: CodeSignatureFlags(ADHOC | RUNTIME)' buzz-desktop-signature
      grep -Fq '<key>com.apple.security.device.audio-input</key>' buzz-desktop-signature
      grep -Fq '<key>com.apple.security.device.camera</key>' buzz-desktop-signature
      if grep -Fq 'com.apple.security.cs.disable-library-validation' buzz-desktop-signature; then
        echo "Library validation remains disabled" >&2
        exit 1
      fi

      for sidecar in ${lib.escapeShellArgs sidecars}; do
        rcodesign print-signature-info \
          "$out/Applications/Buzz.app/Contents/MacOS/$sidecar" \
          > "$sidecar-signature"
        grep -Fq 'flags: CodeSignatureFlags(ADHOC | RUNTIME)' "$sidecar-signature"
        grep -Fq 'entitlements_plist:' "$sidecar-signature"
        if grep -Fq '<key>' "$sidecar-signature"; then
          echo "$sidecar has unexpected entitlements" >&2
          exit 1
        fi
      done

      "$out/Applications/Buzz.app/Contents/MacOS/buzz" --help >/dev/null

      runHook postInstallCheck
    '';

    passthru = {
      inherit darwinSidecars;
    };

    meta = commonMeta // {
      sourceProvenance = with lib.sourceTypes; [
        binaryNativeCode
        fromSource
      ];
    };
  });
in
if stdenv.hostPlatform.system == "aarch64-darwin" then
  darwinPackage
else if stdenv.hostPlatform.system == "x86_64-linux" then
  linuxPackage
else
  throw "${pname}: unsupported system ${stdenv.hostPlatform.system}"
