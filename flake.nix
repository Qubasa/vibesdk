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
      };

      packages = forAllSystems (
        pkgs:
        let
          scope = withOverlay pkgs;
        in
        {
          inherit (scope) vibesdk vibesdk-wrangler vibesdk-node-modules;
          default = scope.vibesdk;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/shell.nix { };
      });

      nixosModules = rec {
        vibesdk =
          { pkgs, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.vibesdk.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.vibesdk;
          };
        default = vibesdk;
      };

      checks = forAllSystems (
        pkgs:
        let
          scope = withOverlay pkgs;
        in
        {
          inherit (scope) vibesdk vibesdk-wrangler;
        }
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          # Boots a machine running the packaged Worker on emulated bindings and
          # checks that it serves the SPA.
          nixos-module = pkgs.testers.runNixOSTest {
            name = "vibesdk";
            nodes.machine = {
              imports = [ self.nixosModules.vibesdk ];
              services.vibesdk = {
                enable = true;
                remoteBindings = false;
              };
              virtualisation.memorySize = 2048;
              virtualisation.diskSize = 4096;
              environment.systemPackages = [ pkgs.nodejs_22 ];
            };
            testScript = ''
              machine.wait_for_unit("vibesdk.service")
              machine.wait_for_open_port(5173, timeout = 180)
              machine.succeed("curl -sSf http://localhost:5173/ | grep -q '<div id=\"root\">'")
              machine.succeed("curl -sSf http://localhost:5173/favicon.ico -o /dev/null")
              machine.sleep(15)
              machine.succeed("systemctl is-active vibesdk")
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
