{
  lib,
  mkShell,
  writeShellApplication,
  bun,
  nodejs_22,
  python3,
  git,
  jq,
  patchelf,
  findutils,
  stdenv,
}:
let
  # `bun install` unpacks prebuilt binaries (workerd, esbuild, native addons)
  # that expect /lib64/ld-linux; `bun run dev` cannot start the Workers runtime
  # until their interpreter is rewritten.
  patchNodeModules = writeShellApplication {
    name = "vibesdk-patch-node-modules";
    runtimeInputs = [
      patchelf
      findutils
    ];
    text = ''
      root="''${1:-node_modules}"
      if [ ! -d "$root" ]; then
        echo "vibesdk-patch-node-modules: $root does not exist; run bun install first" >&2
        exit 1
      fi
      count=0
      while IFS= read -r binary; do
        chmod u+w "$binary"
        patchelf \
          --set-interpreter "$(cat "${stdenv.cc}/nix-support/dynamic-linker")" \
          --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" \
          "$binary"
        count=$((count + 1))
      done < <(find "$root" -type f -path '*workerd-*/bin/workerd')
      echo "patched $count workerd binaries under $root"
    '';
  };
in
mkShell {
  name = "vibesdk-dev";

  packages = [
    bun
    nodejs_22 # tsx-based scripts (setup, deploy) and native addons expect node
    python3 # debug-tools/*.py
    git
    jq
    patchNodeModules
  ];

  shellHook = ''
    echo "vibesdk: bun $(bun --version), node $(node --version)"
    echo "  bun install && vibesdk-patch-node-modules && bun run dev"
  '';
}
