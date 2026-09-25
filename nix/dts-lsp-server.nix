{ lib
, buildNpmPackage
, esbuild
, fetchFromGitHub
, nodejs_22
}:

# The language server that dts-linter drives. dts-linter already bundles a
# published copy in its node_modules; build this only to run against a newer
# dts-lsp, and pass it to ./dts-linter.nix as `dts-lsp-server`.
buildNpmPackage rec {
  pname = "devicetree-language-server";
  version = "0.10.2";

  src = fetchFromGitHub {
    owner = "kylebonnici";
    repo = "dts-lsp";
    rev = "7e8d7d34fbfa7fc599a3ed9feefdf99cb00f6104";
    hash = "sha256-jxVOdequqa4dPfYr7n9L37EIZ24ENCQrpryaGq+ZlBs=";
  };

  # Use server/ so npm ci installs server/package-lock.json deps
  # (vscode-languageserver etc.).
  sourceRoot = "${src.name}/server";

  nodejs = nodejs_22;

  # Keep in sync with server/package-lock.json.
  npmDepsHash = "sha256-zt/FdoevcA5XsF2Zew2isrLkUWgrACPkHkOWuL8k5D8=";

  nativeBuildInputs = [ esbuild ];

  # Skip the license-checker step, which requires network access.
  buildPhase = ''
    runHook preBuild
    mkdir -p dist
    esbuild src/server.ts \
      --bundle \
      --format=cjs \
      --minify \
      --platform=node \
      --outfile=dist/server.js
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/dist
    cp dist/server.js $out/dist/
    runHook postInstall
  '';

  meta = {
    description = "Devicetree language server";
    homepage = "https://github.com/kylebonnici/dts-lsp";
    license = lib.licenses.asl20;
  };
}
