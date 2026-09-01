# nix-rage

nix-rage is an [age](https://github.com/FiloSottile/age)/[rage](https://github.com/str4d/rage)-based tool designed to import encrypted configuration data during Nix evaluation.

Unlike [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix), nix-rage is not intended to be a general secret-management system for passwords, tokens, or production credentials. Its main use case is hiding personal configuration data in otherwise public Nix repositories—for example a private email address or home address.

Strongly inspired by [oddlama's](https://github.com/oddlama) article ["Evaluation time secrets in Nix: Importing encrypted nix files"](https://oddlama.org/blog/evaluation-time-secrets-in-nix/).

> [!WARNING]
> The `nix-rage` package is currently in an unstable development phase and is not recommended for sensitive configurations.

## Features

- **Evaluation-time decryption**: use encrypted Nix expressions and files directly while evaluating a configuration.
- **Flake integration**: NixOS and nix-darwin modules configure the plugin automatically.
- **ABI-safe system integration**: system modules build nix-rage against the target generation's `config.nix.package`.
- **Fail-closed evaluator selection**: nix-rage never silently substitutes `stable`, `latest`, or a nearby Nix version for a missing evaluator ABI.
- **Simple repository workflow**: encrypted files can live beside the public configuration without a separate repository pre-processing step such as git-crypt.

## Installation

### NixOS and nix-darwin: use the module

Nix plugins are C++ plugins and must be built for the Nix ABI that loads them. For NixOS and nix-darwin, **do not manually construct `nix.settings.plugin-files` from `packages.<system>.default`**.

Instead, import the provided module. It builds nix-rage against the target generation's `config.nix.package` and configures `nix.settings.plugin-files` automatically.

NixOS example:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix-rage.url = "github:renesat/nix-rage";
    nix-rage.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix-rage, ... }: {
    nixosConfigurations.myhostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-rage.nixosModules.default
        # ...
      ];
    };
  };
}
```

nix-darwin example:

```nix
darwinConfigurations.myhostname = nix-darwin.lib.darwinSystem {
  modules = [
    nix-rage.darwinModules.default
    # ...
  ];
};
```

Replace a manual configuration such as:

```nix
modules = [
  {
    nix.settings.plugin-files = [
      "${nix-rage.packages.${system}.default}/lib/libnix_rage.dylib"
    ];
  }
];
```

with:

```nix
modules = [
  nix-rage.darwinModules.default
];
```

The distinction matters during Nix upgrades:

- `nix-rage.darwinModules.default` / `nix-rage.nixosModules.default` build the plugin for the **target generation's** `config.nix.package`.
- `packages.<system>.default` builds for the **currently running evaluator** selected from nix-rage's nixpkgs input.

A future system generation must not be configured with a plugin built for the old evaluator.

Once a generation containing the module is active, normal upgrades require no bootstrap helper and no explicit `--option plugin-files`:

```sh
sudo darwin-rebuild switch --flake .#myhostname
```

The active generation supplies the plugin needed to evaluate the next configuration, while the module builds the next generation's plugin against that generation's `config.nix.package`.

### Direct/current-evaluator use

For standalone use outside the NixOS/nix-darwin module path, `packages.<system>.default` follows `builtins.nixVersion`.

It deliberately fails closed if the nixpkgs input does not contain an exact package for the running evaluator. It will not fall back to `stable`, `latest`, or the nearest version because version approximation is unsafe for a Nix C++ plugin.

Manual `plugin-files` examples are therefore appropriate only when the plugin is intentionally being loaded into that same evaluator:

```text
# with nix-env
plugin-files = /home/YOURUSERNAMEHERE/.nix-profile/lib/libnix_rage.<so|dylib>

# with cargo build
plugin-files = /path/to/repo/target/debug/libnix_rage.<so|dylib>

# with a package explicitly built for the evaluator that loads it
plugin-files = ${pkgs.nix-rage}/lib/libnix_rage${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}
```

## macOS break-glass recovery for an already mismatched generation

This section is **not part of the normal nix-darwin workflow**. It is only for recovering a machine whose currently active generation already contains a missing, broken, or ABI-incompatible nix-rage plugin and therefore cannot evaluate the configuration needed to install the corrected generation.

A matching `builtins.nixVersion` is necessary but is not always sufficient on Darwin. Independently built Nix C++ libraries at the same version can have incompatible build provenance or data layout. The recovery plugin must therefore be built from the development outputs and toolchain provenance corresponding to the Nix DSOs actually loaded by the active evaluator.

The helper below is run **from the system flake directory**. It:

1. identifies the active `nix` executable and its loaded `libnix*` DSOs;
2. derives their matching development outputs;
3. derives the matching Boost development output and stdenv;
4. obtains the `nix-rage` input from the system flake;
5. calls that input's `legacyPackages.<system>.nixRageForHost` recovery builder;
6. leaves an out-link under `~/.cache/nix-rage/` so garbage collection cannot remove the temporary recovery artifact before activation.

Save it as `bootstrap-host-evaluator.sh`:

```sh
#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf 'nix-rage host bootstrap: %s\n' "$*" >&2
  exit 1
}

host_nix="$(command -v nix)"
[[ -x "$host_nix" ]] || fail 'could not locate the running nix executable'

host_version="$("$host_nix" eval --raw --expr builtins.nixVersion)"
dsos="$(otool -L "$host_nix" | awk 'NR > 1 { print $1 }' |
  awk '/\/libnix(main|expr|fetchers|store|util)(\.[^/]*)?\.dylib$/')"
[[ -n "$dsos" ]] || fail 'the host executable exposes no libnix DSOs to derive provenance from'

dev_json='['
expr_dev=''
while IFS= read -r dso; do
  drv="$(nix-store -q --deriver "$dso")" || fail "cannot query the derivation of $dso"
  [[ "$drv" != unknown-deriver ]] || fail "no derivation records provenance for $dso"

  dev="$(nix-store -q --outputs "$drv" | awk '/-dev$/ { print; exit }')"
  [[ -n "$dev" ]] || fail "the derivation for $dso has no dev output"
  nix-store --realise "$dev" >/dev/null

  [[ "$dso" == *'/libnixexpr'* ]] && expr_dev="$dev"

  # nix-rage includes expr/store/util/fetchers headers. It does not include
  # nix-main headers, and some Nix revisions expose a duplicate expr pkg-config
  # file from nix-main's dev output, so do not let it shadow libnixexpr's own.
  [[ "$dso" == *'/libnixmain'* ]] || dev_json+="\"$dev\","
done <<<"$dsos"

[[ -n "$expr_dev" ]] || fail 'could not identify the active libnixexpr development output'
dev_json="${dev_json%,}]"

expr_dso="$(printf '%s\n' "$dsos" | awk '/\/libnixexpr/ { print; exit }')"
expr_drv="$(nix-store -q --deriver "$expr_dso")" || fail 'cannot query the active libnixexpr derivation'

stdenv_drv="$(nix-store -q --references "$expr_drv" |
  awk '/-stdenv-(darwin|linux)\.drv$/ { print; exit }')"
[[ -n "$stdenv_drv" ]] || fail 'the active libnixexpr derivation does not record its stdenv'

host_stdenv="$(nix-store -q --outputs "$stdenv_drv" | head -n1)"
[[ -n "$host_stdenv" ]] || fail 'the active evaluator stdenv has no output'
nix-store --realise "$host_stdenv" >/dev/null

boost_dev="$(nix-store -q --references "$expr_dev" |
  awk '/-boost-[^-]+-dev$/ { print; exit }')"
[[ -n "$boost_dev" ]] || fail 'the active libnixexpr dev output does not reference Boost development headers'
nix-store --realise "$boost_dev" >/dev/null

flake_metadata="$(nix flake metadata --json .)"
bootstrap_root="$HOME/.cache/nix-rage/bootstrap-current"
mkdir -p "$(dirname "$bootstrap_root")"

NIX_RAGE_FLAKE_METADATA="$flake_metadata" \
NIX_RAGE_HOST_VERSION="$host_version" \
NIX_RAGE_HOST_DEV_OUTPUTS="$dev_json" \
NIX_RAGE_HOST_BOOST_DEV="$boost_dev" \
NIX_RAGE_HOST_STDENV="$host_stdenv" \
  nix build \
    --out-link "$bootstrap_root" \
    --print-out-paths \
    --impure \
    --expr '
      let
        metadata = builtins.fromJSON (
          builtins.getEnv "NIX_RAGE_FLAKE_METADATA"
        );
        source = metadata.path + (
          if metadata.resolved ? dir then "/" + metadata.resolved.dir else ""
        );
        systemFlake = builtins.getFlake ("path:" + source);
        nixRageFlake = systemFlake.inputs.nix-rage;
      in
      nixRageFlake.legacyPackages.${builtins.currentSystem}.nixRageForHost {
        version = builtins.getEnv "NIX_RAGE_HOST_VERSION";
        developmentOutputs = map builtins.storePath (
          builtins.fromJSON (builtins.getEnv "NIX_RAGE_HOST_DEV_OUTPUTS")
        );
        boostDevelopmentOutput = builtins.storePath (
          builtins.getEnv "NIX_RAGE_HOST_BOOST_DEV"
        );
        hostStdenv = builtins.storePath (
          builtins.getEnv "NIX_RAGE_HOST_STDENV"
        );
      }
    '
```

The recovery builder fails closed if the supplied version differs from the evaluator running the build or if required provenance is missing. Repair the active Nix installation/provenance rather than selecting another Nix package by version.

Capture the recovery artifact and use it for **one transition only**:

```sh
plugin="$(./bootstrap-host-evaluator.sh)"
test -n "$plugin"

sudo darwin-rebuild switch --flake .#myhostname \
  --option plugin-files "$plugin/lib/libnix_rage.dylib"
```

After the corrected generation is active, immediately verify the normal steady-state path:

```sh
sudo darwin-rebuild switch --flake .#myhostname
```

That second command must work without the helper and without an explicit `plugin-files` override. Once confirmed, the temporary GC root can be removed:

```sh
rm -f ~/.cache/nix-rage/bootstrap-current
```

Do not integrate the recovery helper into a normal rebuild alias or routine automation. If it is needed repeatedly, the generation/module chain is still broken and should be diagnosed instead of hidden behind the bootstrap.

## Build From Source

Clone the repository and build nix-rage locally:

```sh
git clone https://github.com/renesat/nix-rage.git
cd nix-rage

# Using Nix
nix build

# Using Cargo
cargo build
```

## Usage

Create a Nix configuration containing the values you want to hide:

`secret.nix`:

```nix
{
  mySecretEmail = "nagibator96@gmail.com";
}
```

Encrypt it with `age`:

```sh
age --encrypt -r <AGE-KEY> secret.nix -o secret.nix.age
```

Import the encrypted Nix expression during evaluation:

```nix
{ ... }:
let
  secrets = builtins.importAge [ ./secret-key ] ./secret.nix.age { };
in {
  some.config.parameters.email = secrets.mySecretEmail;
}
```

Other encrypted files can be read as strings:

```nix
{ ... }:
let
  secretConfig = builtins.readAgeFile [ ./secret-key ] ./secret.toml.age { };
in {
  # ...
}
```

## Contributing

Contributions are welcome. Feel free to open issues or submit pull requests on [GitHub](https://github.com/renesat/nix-rage).

## Related software

- [git-crypt](https://github.com/AGWA/git-crypt)
- [git-agecrypt](https://github.com/vlaci/git-agecrypt)
- [agenix](https://github.com/ryantm/agenix)
- [sops-nix](https://github.com/Mic92/sops-nix)
- [agenix-rekey](https://github.com/oddlama/agenix-rekey)

## License

nix-rage is licensed under the MIT License. See the [LICENSE](LICENSE) file for more information.
