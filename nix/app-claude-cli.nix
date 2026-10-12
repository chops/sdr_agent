{ lib, stdenv, fetchurl }:

# The app's own pinned Claude CLI (ADR-0004 R0 amendment, story R0-02).
# The application launches this exact store path through llm-proxy-shim
# (LLM_PROXY_SHIM_CLAUDE_BIN), never `claude` from PATH, so updates to the
# agents' own CLI cannot change what the app runs. Changing `version` or a
# hash is a reviewed pin bump with attestation and witness evidence.
# Packaging adapted from the owner's nix-darwin packages/claude-code.nix.

# Claude Code ships as a native binary via platform-specific npm packages.
# No Node.js runtime needed — the binary is self-contained.
#
# Linux note: the binary is a bun --compile standalone executable. Bun reads
# its embedded JS bundle by:
#  1. opening /proc/self/exe and seeking to a trailer at the END of the file.
#  2. if the trailer can't be parsed, falling back to bare bun runtime
#     (observable as `claude-code --version` printing "1.3.14").
#
# Two NixOS gotchas this implies:
#  - autoPatchelfHook pads the binary (~680B), shifting the trailer offset —
#    fallback fires. So we leave the binary BYTE-IDENTICAL to upstream.
#  - Invoking the binary through `${glibc}/lib/ld-linux-*.so.* /path/to/bin`
#    sets /proc/self/exe to the loader (NOT the bun binary), so the trailer
#    read targets the wrong file — fallback fires. So no loader-wrapper.
#
# The working approach is to run the binary with its DEFAULT PT_INTERP
# (`/lib/ld-linux-<arch>.so.1`) and ensure that path resolves to a real
# glibc loader at runtime. On NixOS this means enabling `programs.nix-ld`
# on the system (see modules/darwin/mac-vm-guest.nix). Other Linux distros
# already have the path; this package itself stays system-agnostic.

let
  version = "2.1.294";

  platform = {
    "aarch64-darwin" = {
      name = "darwin-arm64";
      hash = "sha256-hG+hjsGSTgwPwJSNxdTDHGZ5hvf1yEsw7sofEFbJCuI=";
    };
    "x86_64-darwin" = {
      name = "darwin-x64";
      hash = "sha256-3Sx00KNKUfurq6c/2Q/TN8wZ8ODWvtGbXI7o3kA+3aA=";
    };
    "x86_64-linux" = {
      name = "linux-x64";
      hash = "sha256-CVWlb8gKWH3ScJq3yqJbEKm0U971/abPknVN4MbZBG0=";
    };
    "aarch64-linux" = {
      name = "linux-arm64";
      hash = "sha256-XvSnXuGOor1toBEXfhqEr7n9zZ5GCELvcn3sYIST/9s=";
    };
  }.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");

in stdenv.mkDerivation {
  pname = "app-claude-cli";
  inherit version;

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code-${platform.name}/-/claude-code-${platform.name}-${version}.tgz";
    hash = platform.hash;
  };

  dontBuild = true;
  # bun --compile trailers are byte-position-dependent. Default stdenv
  # post-install phases (strip, patchelf-rpath, fixup) silently mutate the
  # binary and shift the trailer offset — observable as `claude-code
  # --version` printing "1.3.14" (bun's bare-runtime fallback). Removing
  # autoPatchelfHook from nativeBuildInputs is necessary but NOT sufficient;
  # all three of these must be off so the binary stays byte-identical to
  # upstream's npm tgz.
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  unpackPhase = ''
    mkdir -p source
    tar xzf $src -C source
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp source/package/claude $out/bin/claude-code
    chmod +x $out/bin/claude-code

    runHook postInstall
  '';

  meta = with lib; {
    description = "Claude Code CLI pinned for the SDR agent app runtime";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.unfree;
    maintainers = [ ];
    platforms = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
  };
}
