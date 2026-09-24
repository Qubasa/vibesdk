{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.vibesdk;

  stateDir = "/var/lib/${cfg.stateDir}";

  # `vite preview` runs the built Worker on workerd through miniflare and needs
  # a writable project root (miniflare keeps `.wrangler` there), so the store
  # tree is mirrored: small files copied, the heavy parts linked.
  appDir = "${stateDir}/app";

  # miniflare's local persistence (D1, KV, R2, Durable Objects). It lives
  # outside the app tree, which every start replaces, and is linked in as the
  # plugin's default `.wrangler/state`.
  persistDir = "${stateDir}/state";

  share = "${cfg.package}/share/vibesdk";

  # The `.local` variant disables the plugin's remote binding session; the
  # per-binding `remote` flags do not control it.
  viteConfig = if cfg.remoteBindings then "vite.config.ts" else "vite.config.local.ts";
  # `KEY=value` lines to a JSON object, tolerating blank lines, comments and
  # double-quoted values.
  varsToJson = pkgs.writeText "vibesdk-vars.jq" ''
    [
      inputs
      | select(test("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*="))
      | capture("^[[:space:]]*(?<k>[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(?<v>.*)$")
      | { (.k): (.v | sub("^\"(?<inner>.*)\"$"; "\(.inner)")) }
    ]
    | add // {}
  '';

  # Non-secret Worker vars. They sit below the environment file, so the
  # operator's file overrides anything set here.
  baseVars = pkgs.writeText "vibesdk-vars.json" (
    builtins.toJSON (
      {
        CUSTOM_DOMAIN = cfg.domain;
        ENVIRONMENT = cfg.environment;
      }
      // lib.optionalAttrs cfg.browserSidecar.enable {
        DEV_BROWSER_SIDECAR_URL = "http://127.0.0.1:${toString cfg.browserSidecar.port}";
      }
      // cfg.vars
    )
  );

  # Brings the local D1 schema up to date and seeds the templates bucket. The
  # upload only runs when the pinned catalog changes; its marker sits in the
  # state it describes, so a restored backup carries both.
  prepareState = pkgs.writeShellScript "vibesdk-prepare-state" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
      ]
    }"
    config=${appDir}/wrangler.state.json
    wrangler() {
      ${lib.getExe' cfg.package "vibesdk-state-wrangler"} "$@" --local --persist-to ${persistDir} --config "$config"
    }

    database=$(jq -r '.d1_databases[] | select(.binding == "DB") | .database_name' "$config")
    wrangler d1 migrations apply "$database"

    bucket=$(jq -r '.r2_buckets[] | select(.binding == "TEMPLATES_BUCKET") | .bucket_name' "$config")
    marker=${persistDir}/templates-source
    if [ "$(cat "$marker" 2>/dev/null)" != ${cfg.templates} ]; then
      for file in ${cfg.templates}/*; do
        wrangler r2 object put "$bucket/$(basename "$file")" --file="$file"
      done
      echo ${cfg.templates} > "$marker"
    fi
  '';

  syncApp = pkgs.writeShellScript "vibesdk-sync-app" ''
    set -eu
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.findutils
        pkgs.jq
      ]
    }"
    share=${share}

    # systemd creates the directory (StateDirectory) and chdirs into it before
    # this runs, so only its contents are replaced.
    find ${appDir} -mindepth 1 -delete
    cp "$share"/index.html "$share"/package.json "$share"/${viteConfig} \
      "$share"/wrangler.jsonc "$share"/wrangler.state.json "$share"/SandboxDockerfile ${appDir}/
    # `cp -R`, not `cp -a`: preserving ownership needs chown, which the
    # service's syscall filter denies.
    cp -R "$share/node_modules" ${appDir}/node_modules
    chmod u+w ${appDir}/node_modules ${appDir}/node_modules/@*
    cp -R "$share/dist" ${appDir}/dist
    chmod -R u+w ${appDir}/dist
    # A real copy: docker build does not follow a symlinked context directory.
    cp -R "$share/container" ${appDir}/container
    chmod -R u+w ${appDir}/container
    ln -s "$share/migrations" ${appDir}/migrations
    cp -R "$share/.wrangler" ${appDir}/.wrangler
    chmod -R u+w ${appDir}/.wrangler
    ln -s ${persistDir} ${appDir}/.wrangler/state

    ${lib.optionalString (!cfg.enableContainers) ''
      # Without a container runtime the plugin aborts while building the
      # sandbox image, so the whole containers block is removed.
      for config in ${appDir}/dist/*/wrangler.json; do
        jq 'del(.containers)' "$config" > "$config.new"
        mv "$config.new" "$config"
      done
    ''}

    ${lib.optionalString (!cfg.remoteBindings) ''
      # Bindings that have no local implementation: the runtime keeps a remote
      # proxy for them even in local mode and dies when it cannot reach one.
      for config in ${appDir}/dist/*/wrangler.json; do
        jq 'del(.artifacts, .ai, .browser, .dispatch_namespaces)' "$config" > "$config.new"
        mv "$config.new" "$config"
      done
    ''}

    # Worker vars and secrets. In preview mode the plugin takes the Worker's
    # environment from the built config only, so the values are merged into
    # its `vars`, with the operator's file winning over the module options.
    umask 077
    ${
      if cfg.environmentFile != null then
        ''jq -Rn -f ${varsToJson} < "$CREDENTIALS_DIRECTORY/environment" > ${appDir}/.secrets.json''
      else
        "echo '{}' > ${appDir}/.secrets.json"
    }
    for config in ${appDir}/dist/*/wrangler.json; do
      jq --slurpfile base ${baseVars} --slurpfile secrets ${appDir}/.secrets.json \
        '.vars = ((.vars // {}) + $base[0] + $secrets[0])' "$config" > "$config.new"
      mv "$config.new" "$config"
    done
    rm -f ${appDir}/.secrets.json
  '';
in
{
  options.services.vibesdk = {
    enable = lib.mkEnableOption "the VibeSDK platform, served locally on workerd";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Built VibeSDK Worker, client assets and project root.";
    };

    templates = lib.mkOption {
      type = lib.types.package;
      description = ''
        Template catalog (`template_catalog.json` plus one archive per
        template) uploaded to the Worker's local `TEMPLATES_BUCKET`. Generation
        fails with "Template catalog not found" without it.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the server listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5173;
      description = "Port the server listens on.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "localhost:${toString cfg.port}";
      defaultText = lib.literalExpression ''"localhost:''${toString config.services.vibesdk.port}"'';
      example = "build.example.com";
      description = ''
        Host the platform is reached at, passed to the Worker as
        `CUSTOM_DOMAIN`. The Worker answers every request with HTTP 500 while
        this is empty, and derives CORS origins, preview URLs, git clone URLs
        and image URLs from it. Hosts starting with `localhost`, `127.0.0.1`,
        `0.0.0.0` or `::1` are addressed over http, everything else over https.

        The Worker only treats a request as a platform request when its `Host`
        matches this value or is exactly `localhost`; anything else is handled
        as a generated-app preview subdomain.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.enum [
        "dev"
        "staging"
        "prod"
      ];
      default = "prod";
      description = ''
        Value of the Worker's `ENVIRONMENT` var. `dev` relaxes CORS to any
        origin and switches generated links to http.
      '';
    };

    remoteBindings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Connect the bindings the build marks as `remote` (Workers AI, Browser
        Rendering, the dispatch namespace and Artifacts) to the real Cloudflare
        account. The server refuses to start without a Cloudflare login, so
        {option}`services.vibesdk.environmentFile` must carry
        `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.

        With it disabled the server runs the Cloudflare plugin in local mode:
        D1, KV, R2 and Durable Objects persist under the state directory, the
        browser sidecar stands in for Browser Rendering, and model calls need
        `CLOUDFLARE_AI_GATEWAY_URL` pointing at an OpenAI-compatible gateway
        that serves `/compat/chat/completions`.
      '';
    };

    enableContainers = lib.mkOption {
      type = lib.types.bool;
      default = config.virtualisation.docker.enable;
      defaultText = lib.literalExpression "config.virtualisation.docker.enable";
      description = ''
        Build and run the user-app sandbox container (`SandboxDockerfile`)
        declared by the Worker. It needs a Docker-compatible runtime: startup
        aborts when the Docker CLI is missing, so with no runtime present the
        containers block is dropped from the Worker config and generated apps
        cannot be built or previewed.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open {option}`services.vibesdk.port` in the firewall.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/vibesdk.env";
      description = ''
        `KEY=value` file merged into the Worker's vars last, so it overrides
        {option}`services.vibesdk.vars`. It carries secrets such as
        `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `JWT_SECRET` and the
        model-provider keys documented in `.dev.vars.example`.

        Keep it outside the Nix store: store files are world-readable.
      '';
    };

    vars = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        CLOUDFLARE_AI_GATEWAY_URL = "http://127.0.0.1:4000";
        MAX_SANDBOX_INSTANCES = "2";
      };
      description = ''
        Non-secret Worker vars, merged over `CUSTOM_DOMAIN` and `ENVIRONMENT`
        and under {option}`services.vibesdk.environmentFile`. They end up in the
        world-readable Nix store, so secrets belong in the environment file.
      '';
    };

    browserSidecar = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = !cfg.remoteBindings;
        defaultText = lib.literalExpression "!config.services.vibesdk.remoteBindings";
        description = ''
          Run the headless Chromium sidecar the Worker uses for preview console
          capture when the Browser Rendering binding is absent.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 9223;
        description = "Loopback port the browser sidecar listens on.";
      };

      chromium = lib.mkPackageOption pkgs "chromium" { };
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "vibesdk";
      description = ''
        Directory below `/var/lib` holding the project root and, in its
        `state` subdirectory, miniflare's local persistence (D1, KV, R2 and
        Durable Object state). Only `state` needs backing up.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--logLevel=info" ];
      description = "Extra arguments appended to the `vite preview` invocation.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.remoteBindings -> cfg.environmentFile != null;
        message = ''
          services.vibesdk.remoteBindings needs services.vibesdk.environmentFile
          to provide CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID: the server
          refuses to start when it cannot open a remote binding session. Set
          remoteBindings = false to run on emulated resources instead.
        '';
      }
    ];

    warnings = lib.optional (!cfg.enableContainers) ''
      services.vibesdk: containers are disabled, so the Worker config is served
      without its user-app sandbox. The site works, but generated apps cannot
      be built or previewed. Enable virtualisation.docker (or set
      services.vibesdk.enableContainers) to get that back.
    '';

    networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;

    systemd.services.vibesdk = {
      description = "VibeSDK platform";
      documentation = [ "https://github.com/cloudflare/vibesdk" ];
      after = [ "network-online.target" ] ++ lib.optional cfg.enableContainers "docker.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      path = lib.optional cfg.enableContainers config.virtualisation.docker.package;

      environment = {
        HOME = stateDir;
        XDG_CONFIG_HOME = "${stateDir}/config";
        XDG_CACHE_HOME = "${stateDir}/cache";
        WRANGLER_SEND_METRICS = "false";
        # Without an account the runtime cannot fetch the `Request.cf` sample
        # from Cloudflare; make it use the built-in placeholder instead.
        CLOUDFLARE_CF_FETCH_ENABLED = if cfg.remoteBindings then "true" else "false";
        CI = "true"; # keeps wrangler's prompts and TUI out of the journal
        NODE_ENV = "production";
        # workerd's bundled BoringSSL looks for /etc/ssl/cert.pem, which NixOS
        # does not have, and then fails every outgoing HTTPS fetch.
        SSL_CERT_FILE = config.security.pki.caBundle;
      };

      serviceConfig = {
        ExecStartPre = [
          syncApp
          prepareState
        ];
        ExecStart = lib.escapeShellArgs (
          [
            "${pkgs.nodejs_22}/bin/node"
            "${share}/node_modules/vite/bin/vite.js"
            "preview"
            "--config=${appDir}/${viteConfig}"
            "--host=${cfg.host}"
            "--port=${toString cfg.port}"
            "--strictPort"
          ]
          ++ cfg.extraFlags
        );
        WorkingDirectory = appDir;
        LoadCredential = lib.optional (cfg.environmentFile != null) "environment:${cfg.environmentFile}";
        StateDirectory = [
          cfg.stateDir
          "${cfg.stateDir}/app"
          "${cfg.stateDir}/state"
        ];
        StateDirectoryMode = "0700";
        DynamicUser = true;
        # The plugin shells out to the Docker CLI to build the sandbox image.
        SupplementaryGroups = lib.optional cfg.enableContainers "docker";
        Restart = "on-failure";
        RestartSec = 5;
        # The first start seeds every template archive before serving.
        TimeoutStartSec = "5min";

        AmbientCapabilities = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        # getifaddrs() opens an AF_NETLINK socket; without it the runtime dies
        # with EAFNOSUPPORT before binding the port.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        # V8 allocates memory protection keys, which no systemd syscall group
        # covers; without them workerd is killed with SIGSYS.
        SystemCallFilter = [
          "@system-service"
          "pkey_alloc"
          "pkey_free"
          "pkey_mprotect"
          "~@privileged"
          "~@resources"
        ];
        UMask = "0077";
      };
    };

    systemd.services.vibesdk-browser = lib.mkIf cfg.browserSidecar.enable {
      description = "VibeSDK headless browser sidecar";
      wantedBy = [ "multi-user.target" ];
      before = [ "vibesdk.service" ];

      environment = {
        HOME = "/run/vibesdk-browser";
        XDG_CONFIG_HOME = "/run/vibesdk-browser/config";
        XDG_CACHE_HOME = "/run/vibesdk-browser/cache";
        PORT = toString cfg.browserSidecar.port;
        PUPPETEER_EXECUTABLE_PATH = lib.getExe cfg.browserSidecar.chromium;
        PUPPETEER_SKIP_DOWNLOAD = "true";
        NODE_ENV = "production";
      };

      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.nodejs_22}/bin/node"
          "${share}/browser-sidecar.mjs"
        ];
        RuntimeDirectory = "vibesdk-browser";
        RuntimeDirectoryMode = "0700";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 5;

        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
    };
  };
}
