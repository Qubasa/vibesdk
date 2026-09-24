{
  lib,
  stdenv,
  stdenvNoCC,
  autoPatchelfHook,
  bun,
  jq,
  makeWrapper,
  nodejs_22,
  vibesdk-node-modules,
}:
let
  root = ../.;
  fs = lib.fileset;

  # The dependency tree ships prebuilt binaries (workerd above all) whose
  # interpreter path does not exist on NixOS. They are irrelevant while
  # building, but the server cannot start workerd without this.
  runtimeModules = stdenv.mkDerivation {
    pname = "vibesdk-node-modules-runtime";
    version = (lib.importJSON ../package.json).version;

    dontUnpack = true;
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    # Optional dependencies for other platforms, and prebuilt browsers that
    # were never downloaded, cannot be resolved and are not needed.
    autoPatchelfIgnoreMissingDeps = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R "${vibesdk-node-modules}/node_modules" "$out/node_modules"
      chmod -R u+w "$out/node_modules"
      # Workspace link into the source tree; the install tree provides the
      # built package instead.
      rm -f "$out/node_modules/@space-do/space"
      runHook postInstall
    '';

    # Guard: the patched runtime must actually be executable here, otherwise
    # the failure only shows up as a silent workerd exit at request time.
    doInstallCheck = true;
    installCheckPhase = ''
      found=0
      while IFS= read -r binary; do
        "$binary" --version
        found=1
      done < <(find "$out/node_modules" -type f -path '*workerd-linux-*/bin/workerd')
      if [ "$found" = 0 ]; then
        echo "vibesdk: no workerd binary found to verify in the runtime tree" >&2
        exit 1
      fi
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "vibesdk";
  version = (lib.importJSON ../package.json).version;

  src = fs.toSource {
    inherit root;
    fileset = fs.unions [
      (root + "/.npmrc")
      (root + "/SandboxDockerfile")
      (root + "/container")
      (root + "/bun.lock")
      (root + "/bunfig.toml")
      (root + "/index.html")
      (root + "/migrations")
      (root + "/package.json")
      (root + "/packages")
      (root + "/public")
      (root + "/scripts/dev-browser-sidecar.ts")
      (root + "/shared")
      (root + "/space/build.mjs")
      (root + "/space/package.json")
      (root + "/space/src")
      (root + "/space/tsconfig.json")
      (root + "/space/types")
      (root + "/src")
      (root + "/tsconfig.app.json")
      (root + "/tsconfig.json")
      (root + "/tsconfig.node.json")
      (root + "/tsconfig.worker.json")
      (root + "/vite.config.ts")
      (root + "/worker")
      (root + "/worker-configuration.d.ts")
      (root + "/wrangler.jsonc")
    ];
  };

  nativeBuildInputs = [
    bun
    jq
    makeWrapper
    nodejs_22
  ];

  configurePhase = ''
    runHook preConfigure
    cp -R "${vibesdk-node-modules}/node_modules" node_modules
    chmod -R u+w node_modules
    export HOME="$NIX_BUILD_TOP/home"
    export PATH="$PWD/node_modules/.bin:$PATH"
    runHook postConfigure
  '';

  # Entrypoints are run through node rather than the `.bin` wrappers: their
  # `#!/usr/bin/env node` shebangs do not resolve inside the build sandbox.
  # The browser sidecar is bundled with puppeteer left external, so it
  # resolves from the installed node_modules next to it.
  buildPhase = ''
    runHook preBuild
    export NODE_ENV=production
    node space/build.mjs
    node node_modules/vite/bin/vite.js build
    node node_modules/esbuild/bin/esbuild scripts/dev-browser-sidecar.ts \
      --bundle --platform=node --format=esm --external:puppeteer \
      --outfile=browser-sidecar.mjs
    runHook postBuild
  '';

  # The install tree doubles as the project root `vite preview` runs from, so
  # it keeps vite.config.ts, wrangler.jsonc and a node_modules link next to the
  # build output.
  #
  # Two fixups on the generated wrangler.json:
  #   * the Cloudflare vite plugin bakes build-time absolute paths (container
  #     Dockerfile, image build context) into it;
  #   * it still emits `legacy_env: true`, which wrangler >= 4.100 rejects even
  #     though that value was the default and removing it changes nothing
  #     (wrangler says so in the error it raises). The guard fires if a future
  #     build emits `false`, where dropping the field would change Worker names.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/vibesdk"
    cp -R dist "$out/share/vibesdk/dist"
    cp -R migrations "$out/share/vibesdk/migrations"
    # package.json comes along for its `"type": "module"`: without it vite
    # loads vite.config.ts as CommonJS and the ESM-only Cloudflare plugin fails.
    cp index.html package.json wrangler.jsonc SandboxDockerfile "$out/share/vibesdk/"
    # No debugger attaches to a server, and the plugin's inspector port would
    # hand the Worker and its secrets to any local process that connects.
    substitute vite.config.ts "$out/share/vibesdk/vite.config.ts" \
      --replace-fail "cloudflare({" "cloudflare({ inspectorPort: false,"
    # The vite plugin builds the sandbox image with the app directory as its
    # context, so everything the Dockerfile copies has to be installed.
    cp -R container "$out/share/vibesdk/container"
    for src in $(sed -n 's/^COPY \([^ ]*\) .*/\1/p' SandboxDockerfile); do
      if [ ! -e "$out/share/vibesdk/$src" ]; then
        echo "vibesdk: SandboxDockerfile copies $src, which is not installed" >&2
        exit 1
      fi
    done

    # Variant used when the deployment has no Cloudflare credentials: the
    # plugin opens a remote binding session unless told not to, regardless of
    # the per-binding `remote` flags.
    substitute "$out/share/vibesdk/vite.config.ts" "$out/share/vibesdk/vite.config.local.ts" \
      --replace-fail "cloudflare({" "cloudflare({ remoteBindings: false,"
    # A farm of links rather than one node_modules symlink: vite writes
    # `node_modules/.vite-temp` into the project root while loading the
    # TypeScript config, so that directory has to be writable when copied.
    mkdir -p "$out/share/vibesdk/node_modules"
    for entry in "${runtimeModules}"/node_modules/*; do
      name=$(basename "$entry")
      case "$name" in
        @*)
          mkdir -p "$out/share/vibesdk/node_modules/$name"
          ln -s "$entry"/* "$out/share/vibesdk/node_modules/$name/"
          ;;
        *)
          ln -s "$entry" "$out/share/vibesdk/node_modules/$name"
          ;;
      esac
    done

    # `@space-do/space` is a workspace link into the source tree, which the
    # farm cannot follow, so the built package is installed alongside.
    mkdir -p "$out/share/vibesdk/space"
    cp space/package.json "$out/share/vibesdk/space/"
    cp -R space/dist space/types "$out/share/vibesdk/space/"
    rm -f "$out/share/vibesdk/node_modules/@space-do/space"
    ln -s "$out/share/vibesdk/space" "$out/share/vibesdk/node_modules/@space-do/space"

    # `vite build` records where the Worker config landed; the plugin reads
    # this back in preview mode.
    mkdir -p "$out/share/vibesdk/.wrangler/deploy"
    cp .wrangler/deploy/config.json "$out/share/vibesdk/.wrangler/deploy/config.json"
    cat "$out/share/vibesdk/.wrangler/deploy/config.json"

    substituteInPlace "$out/share/vibesdk/dist"/*/wrangler.json \
      --replace-fail "$NIX_BUILD_TOP/source" "$out/share/vibesdk"

    for config in "$out/share/vibesdk/dist"/*/wrangler.json; do
      jq 'if .legacy_env == false then
             error("vibesdk: generated wrangler.json sets legacy_env = false; drop the del() in nix/package.nix and check Worker naming instead")
           else del(.legacy_env) end' "$config" > "$config.new"
      mv "$config.new" "$config"
    done

    # Minimal config for the wrangler state commands (D1 migrations, R2
    # seeding). The full config has container entries wrangler rejects
    # outside a build, and a migrations path relative to the build output.
    jq --arg migrations "$out/share/vibesdk/migrations" \
      '{name, compatibility_date, r2_buckets,
        d1_databases: [.d1_databases[] | .migrations_dir = $migrations]}' \
      "$out/share/vibesdk/dist"/*/wrangler.json > "$out/share/vibesdk/wrangler.state.json"

    # The wrangler that applies migrations and seeds the bucket must run the
    # same miniflare and workerd as `vite preview`: a newer workerd writes
    # SQLite metadata the serving one cannot read. That is the Cloudflare
    # plugin's own wrangler, which shares the top-level miniflare.
    modules="$out/share/vibesdk/node_modules"
    plugin_wrangler="$modules/@cloudflare/vite-plugin/node_modules/wrangler"
    state_workerd=$(jq -r .version "$plugin_wrangler/node_modules/workerd/package.json")
    serve_workerd=$(jq -r .version "$modules/miniflare/node_modules/workerd/package.json")
    if [ "$state_workerd" != "$serve_workerd" ]; then
      echo "vibesdk: the vite plugin's wrangler bundles workerd $state_workerd but miniflare serves with $serve_workerd; point vibesdk-state-wrangler in nix/package.nix at a wrangler that matches" >&2
      exit 1
    fi
    makeWrapper ${nodejs_22}/bin/node "$out/bin/vibesdk-state-wrangler" \
      --add-flags "$plugin_wrangler/bin/wrangler.js"

    cp browser-sidecar.mjs "$out/share/vibesdk/"
    runHook postInstall
  '';

  passthru = {
    nodeModules = runtimeModules;
    # Project root for `vite preview` and for `wrangler deploy`.
    appDir = "share/vibesdk";
  };

  meta = {
    description = "Cloudflare VibeSDK: AI webapp generator platform for Cloudflare Workers";
    homepage = "https://github.com/cloudflare/vibesdk";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
