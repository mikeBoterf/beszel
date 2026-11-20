{
  description = "Beszel: build, run, test and develop with Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Any package version nixpkgs ever built (fzakaria/nixpkgs-multiverse). Every
  # tool below comes from it at an exact version, so `nix flake update` moves
  # nixpkgs without moving the toolchain.
  inputs.multiverse.url = "github:fzakaria/nixpkgs-multiverse";

  outputs =
    {
      self,
      nixpkgs,
      multiverse,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system} system);
      # Go follows go.mod's `go` line and biome follows package.json, so neither
      # can drift from what the tree asks for; the rest are bumped here by hand.
      tools =
        system:
        let
          v = multiverse.legacyPackages.${system}.versions;
          goVersion = builtins.head (builtins.match ".*\ngo ([0-9.]+)\n.*" (builtins.readFile ./go.mod));
          site = builtins.fromJSON (builtins.readFile ./internal/site/package.json);
        in
        {
          go = v.go.${goVersion};
          nodejs = v.nodejs_22."22.23.4";
          biome = v.biome.${site.devDependencies."@biomejs/biome"};
          gopls = v.gopls."0.24.0";
          delve = v.delve."1.27.2";
          golangci-lint = v.golangci-lint."2.15.0";
          govulncheck = v.govulncheck."1.9.0";
          gnumake = v.gnumake."4.4.1";
          entr = v.entr."5.9";
        };
      app = pkgs: program: description: {
        type = "app";
        meta = { inherit description; };
        program = pkgs.lib.getExe' self.packages.${pkgs.stdenv.hostPlatform.system}.beszel program;
      };
    in
    {
      packages = forAll (
        pkgs: system: rec {
          beszel = pkgs.callPackage ./nix/package.nix {
            buildGoModule = pkgs.buildGoModule.override { inherit (tools system) go; };
            nodejs_22 = (tools system).nodejs;
          };
          default = beszel;
        }
      );

      # nix run .#hub -- serve --http 127.0.0.1:8090   (data in ./beszel_data)
      # nix run .#agent                                 (KEY/HUB_URL/TOKEN from the environment)
      apps = forAll (
        pkgs: _: {
          hub = app pkgs "beszel-hub" "Beszel hub (web UI and API); try: serve --http 127.0.0.1:8090";
          agent = app pkgs "beszel-agent" "Beszel agent; set KEY, HUB_URL and TOKEN in the environment";
          default = app pkgs "beszel-hub" "Beszel hub (web UI and API)";
        }
      );

      devShells = forAll (
        pkgs: system: {
          default = pkgs.mkShell {
            # Go + Node for the tree, the Makefile's dev loop (make, entr), editor
            # and debugger support, and the linters CI-style checks use.
            packages = with tools system; [
              go
              gopls
              delve
              nodejs
              gnumake
              entr
              golangci-lint
              govulncheck
            ];
            env = {
              GOTOOLCHAIN = "local";
              CGO_ENABLED = "0";
            };
            shellHook = ''
              echo "beszel dev shell: go $(go env GOVERSION | cut -c3-), node $(node --version)"
              echo "  make dev-hub | make dev-agent | make dev-server    hot-reload loops (npm ci in internal/site first)"
              echo "  go test -tags testing ./...                        Go tests"
              echo "  nix flake check                                     Go tests + UI types and lint, in the sandbox"
              echo "  NIX_CONFIG='builders =' nix run nixpkgs#nix-update -- --flake --version=skip beszel   refresh vendorHash after go.mod changes"
            '';
          };
        }
      );

      checks = forAll (
        pkgs: system:
        import ./nix/checks.nix {
          inherit pkgs;
          beszel = self.packages.${system}.beszel;
          inherit (tools system) biome;
        }
      );

      formatter = forAll (pkgs: _: pkgs.nixfmt);
    };
}
