# Fixed-output derivation holding the bun-resolved dependency tree.
#
# Nix has no bun lockfile fetcher, so the whole `node_modules` tree is fetched
# in one network-enabled derivation and pinned by content hash. Only the
# manifests are part of its source, so editing application code does not
# re-fetch dependencies.
{
  lib,
  stdenvNoCC,
  bun,
  cacert,
}:
let
  root = ../.;
  fs = lib.fileset;
in
stdenvNoCC.mkDerivation {
  pname = "vibesdk-node-modules";
  version = (lib.importJSON ../package.json).version;

  src = fs.toSource {
    inherit root;
    fileset = fs.unions [
      (root + "/package.json")
      (root + "/bun.lock")
      (root + "/bunfig.toml")
      (root + "/.npmrc")
      (root + "/space/package.json")
    ];
  };

  nativeBuildInputs = [ bun ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$NIX_BUILD_TOP/home"
    export BUN_INSTALL_CACHE_DIR="$NIX_BUILD_TOP/bun-cache"
    bun install \
      --frozen-lockfile \
      --ignore-scripts \
      --no-progress \
      --no-summary
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    rm -rf node_modules/.cache
    mkdir -p "$out"
    cp -R node_modules "$out/node_modules"
    runHook postInstall
  '';

  dontFixup = true;

  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  # bun installs platform-specific optional dependencies (rolldown, esbuild,
  # workerd, @tailwindcss/oxide), so the tree differs per system.
  outputHash =
    {
      x86_64-linux = "sha256-vPnS+0oU/EgDDnFhHDctzjUakmxBGORHrpuAm8UK+Ys=";
    }
    .${stdenvNoCC.hostPlatform.system}
      or (throw "vibesdk: no bun dependency hash recorded for ${stdenvNoCC.hostPlatform.system}. Set outputHash in nix/node-modules.nix to lib.fakeHash, build once, and record the hash nix reports.");

  meta = {
    description = "bun-resolved node_modules tree for vibesdk";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
