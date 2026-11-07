{
  description = "Verona self-hosted compiler development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          llvm = pkgs.llvmPackages_23.llvm;
          clang = pkgs.llvmPackages_23.clang;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.autoconf
              pkgs.automake
              pkgs.python3
              llvm
              clang
            ];

            shellHook = ''
              # Keep every native compiler tool on the pinned LLVM major.
              export PATH="${llvm}/bin:${clang}/bin:$PATH"
              export LLVM_CONFIG="${llvm}/bin/llvm-config"
              export CC="${clang}/bin/clang"
              export AR="${llvm}/bin/llvm-ar"

              # Verona's driver recognizes both the public toolchain variables
              # and the self-hosted compiler-specific overrides.
              export VERONA_LINKER="$CC"
              export VERONA_AR="$AR"
              export VERONA_CORE_CLANG="$CC"
              export VERONA_CORE_AR="$AR"

              # The compiler links against LLVM's shared C API library.
              export LIBRARY_PATH="${llvm.lib}/lib:''${LIBRARY_PATH:-}"
              export LD_LIBRARY_PATH="${llvm.lib}/lib:''${LD_LIBRARY_PATH:-}"
              export DYLD_LIBRARY_PATH="${llvm.lib}/lib:''${DYLD_LIBRARY_PATH:-}" 

              echo "Verona compiler development shell"
              echo "LLVM $(llvm-config --version), Clang $(clang --version | head -n 1)"
            '';
          };
        }
      );
    };
}
