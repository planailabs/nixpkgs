{
  appimageTools,
  fetchurl,
  lib,
  nix-update-script,
}:

let
  pname = "buzz-desktop";
  version = "0.5.3";

  src = fetchurl {
    url = "https://github.com/block/buzz/releases/download/desktop-v${version}/Buzz_${version}_amd64.AppImage";
    hash = "sha256-XchCo9rjISX7Zisy4ePdumXi+xySd0Tfu3vKfqJMwuM=";
  };

  appimageContents = appimageTools.extractType2 {
    inherit pname version src;

    postExtract = ''
      substituteInPlace $out/usr/bin/buzz-desktop \
        --replace-fail \
          'exec -a "buzz-desktop" "$here/buzz-desktop.bin" "$@"' \
          'export GST_PLUGIN_SYSTEM_PATH_1_0=/usr/lib64/gstreamer-1.0; exec -a "buzz-desktop" "$here/buzz-desktop.bin" "$@"'
    '';
  };
in
appimageTools.wrapAppImage {
  inherit pname version;
  src = appimageContents;

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
    install -Dm444 ${appimageContents}/usr/share/applications/Buzz.desktop \
      $out/share/applications/buzz-desktop.desktop
    cp -r ${appimageContents}/usr/share/icons $out/share/
  '';

  passthru = {
    inherit src;
    updateScript = nix-update-script {
      extraArgs = [
        "--use-github-releases"
        "--version-regex"
        "^desktop-v(\\d+\\.\\d+\\.\\d+)$"
      ];
    };
  };

  meta = {
    description = "Workspace where humans and AI agents build together";
    homepage = "https://buzz.xyz";
    changelog = "https://github.com/block/buzz/releases/tag/desktop-v${version}";
    license = lib.licenses.asl20;
    mainProgram = "buzz-desktop";
    platforms = [ "x86_64-linux" ];
  };
}
