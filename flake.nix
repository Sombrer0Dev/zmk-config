{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # This pins requirements.txt provided by zephyr-nix.pythonEnv.
    # Matches the zephyr revision pulled in by zmkfirmware/zmk's app/west.yml
    # at the `zmk` revision pinned in config/west.yml (currently v0.3.0).
    zephyr.url = "github:zmkfirmware/zephyr/v3.5.0+zmk-fixes";
    zephyr.flake = false;

    # Zephyr sdk and toolchain.
    zephyr-nix.url = "github:nix-community/zephyr-nix";
    zephyr-nix.inputs.zephyr.follows = "zephyr";
    zephyr-nix.inputs.nixpkgs.follows = "nixpkgs";

    # West manifest locking; skipping the flake to build its package.nix with
    # our own nixpkgs and python package set.
    pin-west.url = "github:urob/pin-west";
    pin-west.flake = false;
  };

  outputs = inputs @ { nixpkgs, ... }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    devShells = forAllSystems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            # zcbor 0.9.1 (pulled in by the Zephyr toolchain's python env)
            # imports cbor2.CBORDecodeValueError, which cbor2 >=6.0 removed.
            # Pin cbor2 back to the last compatible release until zcbor
            # catches up. https://github.com/zephyrproject-rtos/zcbor
            (final: prev: {
              python3 = prev.python3.override (old: {
                packageOverrides = prev.lib.composeExtensions
                  (old.packageOverrides or (_: _: {}))
                  (pyfinal: pyprev: {
                    # Built from scratch rather than overriding pyprev.cbor2:
                    # 6.x's derivation self-references its Rust `cargoDeps`
                    # vendor step via `finalAttrs`, which gets recomputed
                    # against any overridden src/version and breaks, since
                    # 5.9.0 predates the Rust rewrite and is pure Python.
                    cbor2 = pyfinal.buildPythonPackage {
                      pname = "cbor2";
                      version = "5.9.0";
                      pyproject = true;
                      src = prev.fetchPypi {
                        pname = "cbor2";
                        version = "5.9.0";
                        hash = "sha256-hcekYnmsjyJuEFknUiHms9DjcNK7a9BQD5eAeBYVvOo=";
                      };
                      build-system = [pyfinal.setuptools pyfinal.setuptools-scm];
                      doCheck = false;
                      pythonImportsCheck = ["cbor2"];
                      meta = pyprev.cbor2.meta or {};
                    };
                  });
              });
              python3Packages = final.python3.pkgs;
            })
          ];
        };
        # Built against our own (overlaid) pkgs, not zephyr-nix's internal
        # nixpkgs, so the cbor2 pin above actually reaches pythonEnv.
        zephyr = inputs.zephyr-nix.lib.mkZephyr {
          inherit pkgs;
          zephyr-src = inputs.zephyr;
        };
        keymap-drawer = pkgs.python3Packages.callPackage ./nix/keymap-drawer.nix {};
        pin-west = pkgs.python3Packages.callPackage "${inputs.pin-west}/package.nix" {};
        dts-format = pkgs.callPackage ./nix/dts-format.nix {
          dts-linter = pkgs.callPackage ./nix/dts-linter.nix {
            # Uncomment to build against the pinned dts-lsp instead of the
            # server bundled with dts-linter.
            # dts-lsp-server = pkgs.callPackage ./nix/dts-lsp-server.nix {};
          };
        };
      in {
        default = pkgs.mkShellNoCC {
          packages =
            [
              zephyr.pythonEnv
              (zephyr.sdks."0_16".sdk.override {targets = ["arm-zephyr-eabi"];})

              pkgs.cmake
              pkgs.dtc
              pkgs.gcc
              pkgs.ninja

              pkgs.just
              pkgs.yq # Make sure yq resolves to python-yq.

              dts-format
              keymap-drawer
              pin-west

              # -- Used by just_recipes and west_commands. Most systems already have them. --
              # pkgs.gawk
              # pkgs.unixtools.column
              # pkgs.coreutils # cp, cut, echo, mkdir, sort, tail, tee, uniq, wc
              # pkgs.diffutils
              # pkgs.findutils # find, xargs
              # pkgs.gnugrep
              # pkgs.gnused
            ];

          env = {
            PYTHONPATH = "${zephyr.pythonEnv}/${zephyr.pythonEnv.sitePackages}";
          };

          shellHook = ''
            export ZMK_BUILD_DIR=$(pwd)/.build;
            export ZMK_SRC_DIR=$(pwd)/zmk/app;

            # Zephyr v3.5's FindZephyr-sdk.cmake uses an unquoted
            # ''${ZEPHYR_TOOLCHAIN_VARIANT} inside an if(... STREQUAL ...),
            # which breaks CMake's argument parsing when the var is unset.
            # Later Zephyr releases quote it; until we bump past v3.5, set
            # it explicitly to work around the bug.
            export ZEPHYR_TOOLCHAIN_VARIANT=zephyr;
          ''
          # Expose libatomic to non-Nix binaries, required by the dts-linter
          # pre-commit hook. This is linux-only, in Darwin atomics live in
          # the compiler runtime and LD_LIBRARY_PATH is linux-only anyhow.
          + (if pkgs.stdenv.isLinux then
            let libatomic = pkgs.runCommand "libatomic" {} ''
              mkdir -p $out/lib
              cp -d ${pkgs.stdenv.cc.cc.lib}/lib/libatomic.so* $out/lib/
            ''; in ''
            export LD_LIBRARY_PATH="${libatomic}/lib";
          '' else "");
        };
      }
    );
  };
}
