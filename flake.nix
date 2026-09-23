{
  description = "Cloudflare VibeSDK: AI webapp generator platform for Cloudflare Workers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      withOverlay = pkgs: pkgs.extend self.overlays.default;
    in
    {
      overlays.default = final: _prev: {
        vibesdk-node-modules = final.callPackage ./nix/node-modules.nix { };
        vibesdk = final.callPackage ./nix/package.nix { };
        vibesdk-wrangler = final.callPackage ./nix/wrangler.nix { };
        vibesdk-templates = final.callPackage ./nix/templates.nix { };
      };

      packages = forAllSystems (
        pkgs:
        let
          scope = withOverlay pkgs;
        in
        {
          inherit (scope)
            vibesdk
            vibesdk-wrangler
            vibesdk-node-modules
            vibesdk-templates
            ;
          default = scope.vibesdk;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/shell.nix { };
      });

      nixosModules = rec {
        vibesdk =
          { pkgs, ... }:
          let
            packages = self.packages.${pkgs.stdenv.hostPlatform.system};
          in
          {
            imports = [ ./nix/module.nix ];
            services.vibesdk = {
              package = lib.mkDefault packages.vibesdk;
              templates = lib.mkDefault packages.vibesdk-templates;
            };
          };
        default = vibesdk;
      };

      checks = forAllSystems (
        pkgs:
        let
          scope = withOverlay pkgs;
        in
        {
          inherit (scope) vibesdk vibesdk-wrangler vibesdk-templates;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Boots a machine running the packaged Worker on emulated bindings and
          # checks that it serves the SPA, keeps its state across restarts, and
          # that the browser sidecar captures a page.
          nixos-module = pkgs.testers.runNixOSTest {
            name = "vibesdk";
            nodes.machine = {
              imports = [ self.nixosModules.vibesdk ];
              services.vibesdk = {
                enable = true;
                remoteBindings = false;
                vars.VIBESDK_TEST_VAR = "from-module";
              };
              virtualisation.memorySize = 3072;
              virtualisation.diskSize = 6144;
              environment.systemPackages = [
                scope.vibesdk
                pkgs.jq
              ];
            };
            testScript = ''
              import json

              flags = "--local --persist-to /var/lib/vibesdk/state --config /var/lib/vibesdk/app/wrangler.state.json"
              wrangler = "cd /root && CI=true vibesdk-state-wrangler"

              def d1(sql):
                  return machine.succeed(f"{wrangler} d1 execute vibesdk-db --json --command \"{sql}\" {flags}")

              def serve():
                  machine.systemctl("start vibesdk")
                  machine.wait_for_unit("vibesdk.service")
                  machine.wait_for_open_port(5173, timeout = 180)

              machine.wait_for_unit("vibesdk.service")
              machine.wait_for_open_port(5173, timeout = 180)
              machine.succeed("curl -sSf http://localhost:5173/ | grep -q '<div id=\"root\">'")
              machine.succeed("curl -sSf http://localhost:5173/favicon.ico -o /dev/null")

              with subtest("module vars reach the Worker config"):
                  machine.succeed(
                      "jq -e '.vars.VIBESDK_TEST_VAR == \"from-module\" and .vars.CUSTOM_DOMAIN == \"localhost:5173\"' "
                      + "/var/lib/vibesdk/app/dist/vibesdk_production/wrangler.json"
                  )

              machine.systemctl("stop vibesdk")

              with subtest("migrations and templates are in the local state"):
                  assert "users" in d1("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'")
                  machine.succeed(
                      f"{wrangler} r2 object get vibesdk-templates/template_catalog.json --pipe {flags} | jq -e 'length > 0'"
                  )

              with subtest("state survives a restart and the second start changes nothing"):
                  d1("CREATE TABLE probe (v TEXT); INSERT INTO probe VALUES ('kept')")
                  serve()
                  machine.systemctl("stop vibesdk")
                  assert "kept" in d1("SELECT v FROM probe")
                  machine.succeed("journalctl -u vibesdk | grep -q 'No migrations to apply'")
                  uploads = int(machine.succeed("journalctl -u vibesdk | grep -c 'Upload complete'"))
                  archives = int(machine.succeed("ls ${scope.vibesdk-templates} | wc -l"))
                  assert uploads == archives, f"{uploads} uploads for {archives} template files"
                  serve()

              with subtest("browser sidecar captures console output"):
                  machine.wait_for_unit("vibesdk-browser.service")
                  machine.wait_for_open_port(9223)
                  payload = {
                      "url": "data:text/html,<script>console.log(\"sidecar-ok\")</script>",
                      "viewport": {"width": 800, "height": 600},
                      "waitSeconds": 0,
                  }
                  machine.succeed(f"echo '{json.dumps(payload)}' > /root/capture.json")
                  result = json.loads(machine.succeed(
                      "curl -sSf -H 'content-type: application/json' --data @/root/capture.json "
                      + "http://127.0.0.1:9223/capture-console-logs"
                  ))
                  assert any(log["text"] == "sidecar-ok" for log in result["logs"]), result

              machine.succeed("systemctl is-active vibesdk")
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
