{
  description = "Verona compiler development environment";

  inputs = {
    self.submodules = true;
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (import nixpkgs {
            inherit system;
          })
        );
    in
    {
      devShells = forAllSystems (
        pkgs:
        {
          default =
            let
              # Git's submodule pin keeps these bindings in step with LLVM 23.
              clLLVM = ./vendor/CL-LLVM;
              lisp = pkgs.sbcl.withPackages (ps: [
                ps.fiveam
                ps.cffi
                ps.cffi-grovel
                ps.trivial-features
                ps.cl-ppcre
                ps.split-sequence
                ps.trivial-shell
              ]);
            in
            pkgs.mkShell {
              packages = [
                pkgs.autoconf
                pkgs.automake
                pkgs.cmake
                lisp
                pkgs.llvmPackages_23.llvm
                pkgs.llvmPackages_23.clang
              ];

              shellHook = ''
                export VERONA_CL_LLVM="${clLLVM}"
                # The compiler driver supplies the platform startup objects
                # and defaults needed to turn a Verona object into a process.
                export VERONA_LINKER="${pkgs.llvmPackages_23.clang}/bin/clang"
                export VERONA_AR="${pkgs.llvmPackages_23.llvm}/bin/llvm-ar"
                export LD_LIBRARY_PATH="${pkgs.llvmPackages_23.llvm.lib}/lib:''${LD_LIBRARY_PATH:-}"
                export DYLD_LIBRARY_PATH="${pkgs.llvmPackages_23.llvm.lib}/lib:''${DYLD_LIBRARY_PATH:-}"
                echo "Verona development shell: SBCL $(sbcl --version)"
                echo "LLVM $(llvm-config --version), CL-LLVM from vendor/CL-LLVM"
              '';
            };
        }
      );
    };
}
