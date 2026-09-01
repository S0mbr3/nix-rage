{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = import inputs.systems;
      imports = [
        inputs.pre-commit-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      flake = let
        nixRageModule = {
          config,
          lib,
          pkgs,
          ...
        }: let
          nix-rage = inputs.self.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nixRageFor config.nix.package;
        in {
          nix.settings.plugin-files = [
            "${lib.getLib nix-rage}/lib/libnix_rage${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
          ];
        };
      in {
        darwinModules.default = nixRageModule;
        nixosModules.default = nixRageModule;
      };
      perSystem = {
        system,
        config,
        self',
        pkgs,
        lib,
        ...
      }: let
        normalizeNixVersion = version: lib.head (lib.splitString "+" version);
        evaluatorNixVersion = normalizeNixVersion builtins.nixVersion;
        toolchain = pkgs.fenix.stable.withComponents [
          "cargo"
          "clippy"
          "rust-src"
          "rustc"
          "rustfmt"
        ];
        craneLib = (inputs.crane.mkLib pkgs).overrideToolchain toolchain;
        nix_pkgs = lib.filterAttrs (nix_version: nix_pkg:
          (lib.elem nix_version ["git" "latest" "minimum" "stable" "unstable"]
            || lib.hasPrefix "nix_" nix_version)
          && (builtins.tryEval nix_pkg).success
          && builtins.compareVersions nix_pkg.version "2.24" >= 0)
        pkgs.nixVersions;
        selectEvaluatorNixPkg = version: candidates:
          let
            exactCandidates = builtins.filter (nix_pkg:
              normalizeNixVersion nix_pkg.version == version
            ) candidates;
          in if exactCandidates != []
          then builtins.head exactCandidates
          else throw ''
            nix-rage-current cannot select a plugin ABI safely.
            The running evaluator reports builtins.nixVersion = ${version}.
            Available candidate Nix versions: ${lib.concatStringsSep ", " (lib.unique (map (pkg: normalizeNixVersion pkg.version) candidates))}.
            A stable/latest/nearest fallback is unsafe because Nix plugin C++ ABIs
            and host DSO identities must match. Use the documented bootstrap path
            with an exact nixpkgs source that provides ${version}, then retry.
          '';
        evaluator_nix_pkg = selectEvaluatorNixPkg evaluatorNixVersion (builtins.attrValues nix_pkgs);
        sharedLibraryName = pkg: "${lib.getLib pkg}/lib/libnix_rage${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
        validateHostBootstrap = {
          version,
          developmentOutputs,
          boostDevelopmentOutput,
          hostStdenv,
        }:
          assert lib.assertMsg (version == evaluatorNixVersion) ''
            nixRageForHost refuses an ABI approximation: supplied version
            ${version} does not match the running evaluator ${evaluatorNixVersion}.
          '';
          assert lib.assertMsg (developmentOutputs != []) ''
            nixRageForHost requires development outputs derived from the active
            evaluator's loaded Nix DSOs; an empty provenance set is unsafe.
          '';
          assert lib.assertMsg (boostDevelopmentOutput != null) ''
            nixRageForHost requires the Boost development output referenced by
            the active evaluator's libnixexpr development output.
          '';
          assert lib.assertMsg (hostStdenv != null) ''
            nixRageForHost requires the stdenv recorded in the active
            evaluator's derivation; compiling with an unrelated C++ toolchain
            is not an ABI-safe bootstrap.
          '';
          true;
        commonArgs = {
          nix_pkg ? null,
          extraBuildInputs ? [],
        }: {
          src = lib.cleanSourceWith {
            src = lib.cleanSource ./.;
            filter = name: type: (craneLib.filterCargoSources name type) || (lib.hasSuffix ".cpp" name);
          };
          nativeBuildInputs = [pkgs.pkg-config];
          buildInputs = (lib.optional (nix_pkg != null) nix_pkg) ++ extraBuildInputs;
          strictDeps = true;
        };
        cargoArtifacts = nix_pkg: craneLib.buildDepsOnly (commonArgs {
          inherit nix_pkg;
          extraBuildInputs = [pkgs.boost];
        });
      in {
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            inputs.fenix.overlays.default
          ];
        };

        treefmt = {
          programs = {
            rustfmt = {
              enable = true;
            };
            clang-format.enable = true;
            alejandra.enable = true;
            taplo.enable = true;
            yamlfmt = {
              enable = true;
              settings = {
                formatter = {
                  include_document_start = true;
                  pad_line_comments = 2;
                };
              };
            };
          };
        };

        pre-commit.settings = {
          settings = {
            rust.check.cargoDeps = pkgs.rustPlatform.importCargoLock {lockFile = ./Cargo.lock;};
          };
          hooks = {
            yamllint.enable = true;
            treefmt = {
              enable = true;
              package = config.treefmt.build.wrapper;
            };
            clippy = {
              enable = true;
              packageOverrides.cargo = toolchain;
              packageOverrides.clippy = toolchain;
              extraPackages = self'.packages.default.buildInputs ++ self'.packages.default.nativeBuildInputs;
            };
            cargo-machete = {
              enable = true;
              name = "cargo-machete";
              description = "Remove unused Rust dependencies with this one weird trick!";
              language = "rust";
              pass_filenames = false;
              entry = lib.getExe pkgs.cargo-machete;
            };
            zizmor = {
              name = "zizmor";
              description = "Find security issues in GitHub Actions CI/CD setups";
              language = "python";
              types = ["yaml"];
              files = "(\.github/workflows/.*)|(action\.ya?ml)$";
              require_serial = true;
              entry = lib.getExe pkgs.zizmor;
            };
            deadnix = {
              enable = true;
              args = ["--edit"];
            };
            statix = {
              enable = true;
              settings = {
                format = "stderr";
              };
            };
            nil.enable = true;
            ripsecrets.enable = true;
          };
        };

        checks =
          {
            bootstrap-fails-closed = let
              fakeCandidates = [{version = "2.35.2";} {version = "2.34.8";}];
              attempted = builtins.tryEval (selectEvaluatorNixPkg "2.35.1" fakeCandidates);
            in
              assert !attempted.success;
              pkgs.runCommand "nix-rage-bootstrap-fails-closed" {} "touch $out";
            host-bootstrap-fails-closed = let
              mismatchedVersion = builtins.tryEval (validateHostBootstrap {
                version = "0.0.0";
                developmentOutputs = [pkgs.nix];
                boostDevelopmentOutput = pkgs.boost;
                hostStdenv = pkgs.stdenv;
              });
              missingProvenance = builtins.tryEval (validateHostBootstrap {
                version = evaluatorNixVersion;
                developmentOutputs = [];
                boostDevelopmentOutput = null;
                hostStdenv = null;
              });
            in
              assert !mismatchedVersion.success;
              assert !missingProvenance.success;
              pkgs.runCommand "nix-rage-host-bootstrap-fails-closed" {} "touch $out";
          }
          // lib.concatMapAttrs (
            nix_version: nix_pkg: let
              pkgs = import inputs.nixpkgs {
                inherit system;
                overlays = [(_final: _prev: {nix = nix_pkg;})];
              };
            in {
              "testPlugin-nix-${nix_version}" = pkgs.testers.runNixOSTest {
                name = "testPlugin-nix-${nix_version}";
                nodes.machine1 = {
                  nix.package = nix_pkg;
                  environment.systemPackages = [
                    pkgs.git
                    pkgs.jq
                  ];
                  nix.extraOptions = ''
                    plugin-files = ${sharedLibraryName self'.packages."nix-rage-nix-${nix_version}"}
                    experimental-features = nix-command
                  '';
                };
                testScript = ''
                  machine1.start()
                  print("Generate key...")
                  machine1.execute("${pkgs.age}/bin/age-keygen -o /tmp/key")

                  print("Test `importAge`...")
                  machine1.execute(
                    "echo '{ a = \"SECRET\";}' | ${pkgs.age}/bin/age -e -i /tmp/key > /tmp/data.age"
                  )
                  assert machine1.execute(
                    "nix eval --raw --expr '(builtins.importAge [ /tmp/key ] /tmp/data.age {cache=false;}).a'"
                  )[1] == "SECRET", "Import file error"

                  print("Test `readAgeFile`...")
                  machine1.execute(
                    "echo 'SECRET' | ${pkgs.age}/bin/age -e -i /tmp/key > /tmp/data.age"
                  )
                  assert machine1.execute(
                    "nix eval --raw --expr 'builtins.readAgeFile [ /tmp/key ] /tmp/data.age {cache=false;}'"
                  )[1].strip() == "SECRET", "Read file error"

                  print("Test `readAgeFile` with lazy Git flake paths...")
                  machine1.execute(
                    "mkdir /tmp/lazy-flake && cd /tmp/lazy-flake && "
                    "git init -q && "
                    "cp /tmp/key ./key && cp /tmp/data.age ./data.age && "
                    "cat > flake.nix <<'EOF'\n"
                    "{\n"
                    "  outputs = { self }: {\n"
                    "    result = builtins.readAgeFile [ ./key ] ./data.age { cache = false; };\n"
                    "  };\n"
                    "}\n"
                    "EOF\n"
                    "git add flake.nix key data.age"
                  )
                  machine1.execute(
                    "source_path=$(nix flake metadata --json /tmp/lazy-flake | jq -r .path) && "
                    "nix store delete \"$source_path\" && "
                    "test ! -e \"$source_path\""
                  )
                  assert machine1.execute(
                    "nix eval --raw /tmp/lazy-flake#result"
                  )[1].strip() == "SECRET", "Read from lazy Git paths failed"
                '';
              };
            }
          ) nix_pkgs;

        devShells.default = craneLib.devShell {
          packages =
            [
              pkgs.bacon
              pkgs.just
              pkgs.cargo-watch
              pkgs.nix-output-monitor
              config.treefmt.build.wrapper
              pkgs.git-cliff
            ]
            ++ self'.packages.default.buildInputs
            ++ self'.packages.default.nativeBuildInputs;
          shellHook = config.pre-commit.installationScript;
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath self'.packages.default.buildInputs;
        };

        legacyPackages.nixRageFor = nix_pkg:
          craneLib.buildPackage (
            (commonArgs {
              inherit nix_pkg;
              extraBuildInputs = [pkgs.boost];
            })
            // {
              cargoArtifacts = cargoArtifacts nix_pkg;
              doCheck = false;
            }
          );

        # This is intentionally separate from nixRageFor.  nixRageFor builds a
        # target-generation plugin against config.nix.package; this bootstrap
        # builder is for the evaluator that is already running this flake.
        # Callers must discover the development outputs from that evaluator's
        # loaded DSOs and pass its matching Boost output explicitly.
        legacyPackages.nixRageForHost = {
          version,
          developmentOutputs,
          boostDevelopmentOutput,
          hostStdenv,
        }:
          assert validateHostBootstrap {
            inherit version developmentOutputs boostDevelopmentOutput hostStdenv;
          };
          craneLib.buildPackage (
            (commonArgs {
              extraBuildInputs = developmentOutputs ++ [boostDevelopmentOutput];
            })
            // {
              NIX_RAGE_EXPECTED_NIX_VERSION = version;
              cargoArtifacts = craneLib.buildDepsOnly (commonArgs {
                extraBuildInputs = developmentOutputs ++ [boostDevelopmentOutput];
              });
              preBuild = ''
                # The current evaluator's own derivation selected this stdenv.
                # Re-source it before build.rs invokes C++ so its compiler and
                # SDK provenance, not this flake's ambient nixpkgs, control the
                # plugin ABI.
                source ${hostStdenv}/setup
              '';
              doCheck = false;
            }
          );

        packages =
          lib.concatMapAttrs (nix_version: nix_pkg: {
            "nix-rage-nix-${nix_version}" = self'.legacyPackages.nixRageFor nix_pkg;
          })
          nix_pkgs
          // {
            nix-rage-current = self'.legacyPackages.nixRageFor evaluator_nix_pkg;
            nix-rage = self'.packages.nix-rage-current;
            default = self'.packages.nix-rage;
          };
      };
    };
}
