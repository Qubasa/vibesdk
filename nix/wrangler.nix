# The wrangler CLI used to serve the built Worker.
#
# Two constraints decide the version:
#   * nixpkgs' `wrangler` is far older and rejects config keys the build emits
#     (`artifacts`, `worker_loaders`, `containers.wrangler_ssh`).
#   * the workerd binary bundled with the repo's own pin (4.90.0, workerd
#     2026-05-07) only supports compatibility dates up to 2026-05-14, while
#     wrangler.jsonc asks for 2026-05-23 — the Workers runtime refuses to start.
#     Serving therefore needs a wrangler whose workerd is new enough.
#
# It is installed on its own: the repo's full dependency tree would drag ~650 MB
# of build-time packages into the runtime closure.
{
  lib,
  stdenv,
  stdenvNoCC,
  bun,
  cacert,
  nodejs_22,
  makeWrapper,
  patchelf,
  version ? "4.136.0",
}:
let
  pin = (lib.importJSON ../package.json).devDependencies.wrangler;
  checkedVersion =
    if !lib.versionAtLeast version pin then
      throw "vibesdk: nix/wrangler.nix packages wrangler ${version}, older than the ${pin} the repo builds against. Raise it (and its outputHash)."
    else
      version;

  deps = stdenvNoCC.mkDerivation {
    pname = "vibesdk-wrangler-deps";
    version = checkedVersion;

    dontUnpack = true;
    nativeBuildInputs = [ bun ];

    buildPhase = ''
      runHook preBuild
      export HOME="$NIX_BUILD_TOP/home"
      export BUN_INSTALL_CACHE_DIR="$NIX_BUILD_TOP/bun-cache"
      cat > package.json <<EOF
      {
        "name": "vibesdk-wrangler",
        "version": "0.0.0",
        "private": true,
        "dependencies": { "wrangler": "${checkedVersion}" }
      }
      EOF
      bun install --ignore-scripts --no-progress --no-summary --linker hoisted
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
    # The tree carries the platform's prebuilt workerd, so it differs per system.
    outputHash =
      {
        x86_64-linux = "sha256-P0D+pctnXv6yamWoZKVMmy7Z1Rlrsy+zk8Puw7Ec+4I=";
      }
      .${stdenvNoCC.hostPlatform.system}
        or (throw "vibesdk: no wrangler dependency hash recorded for ${stdenvNoCC.hostPlatform.system}. Set outputHash in nix/wrangler.nix to lib.fakeHash, build once, and record the hash nix reports.");
  };
in
stdenv.mkDerivation {
  pname = "vibesdk-wrangler";
  version = checkedVersion;

  dontUnpack = true;

  nativeBuildInputs = [
    makeWrapper
    patchelf
  ];

  # miniflare resolves the workerd binary through `require.resolve`, so the
  # prebuilt executable has to be patched in place inside the tree.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib"
    cp -R "${deps}/node_modules" "$out/lib/node_modules"
    chmod -R u+w "$out/lib/node_modules"

    workerd=$(echo "$out"/lib/node_modules/@cloudflare/workerd-*/bin/workerd)
    if [ ! -f "$workerd" ]; then
      echo "vibesdk-wrangler: no prebuilt workerd found in the wrangler tree" >&2
      exit 1
    fi
    patchelf \
      --set-interpreter "$(cat "${stdenv.cc}/nix-support/dynamic-linker")" \
      --set-rpath "${lib.makeLibraryPath [ stdenv.cc.cc.lib ]}" \
      "$workerd"
    "$workerd" --version

    makeWrapper "${nodejs_22}/bin/node" "$out/bin/vibesdk-wrangler" \
      --add-flags "$out/lib/node_modules/wrangler/bin/wrangler.js"
    runHook postInstall
  '';

  meta = {
    description = "wrangler CLI pinned to the version vibesdk is built against";
    homepage = "https://developers.cloudflare.com/workers/wrangler/";
    license = lib.licenses.mit;
    mainProgram = "vibesdk-wrangler";
    platforms = lib.platforms.linux;
  };
}
