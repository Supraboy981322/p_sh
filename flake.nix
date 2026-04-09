{
  description = "shell_thing";

  inputs = {
    # nixpkgs unstable for latest versions
    pkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # import Zig overlay
    zig_overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig_overlay, flake-utils, ... } @ inputs: 
    (flake-utils.lib.eachDefaultSystem (system:
      let
        repo_root = builtins.toString ./.;

        # the server only compiles on one Zig version 
        zigVersion = "0.15.2";

        # selected Zig package
        zig = zig_overlay.packages.${system}.${zigVersion};

        # add the Zig overlay pkgs
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig_overlay.overlays.default ];
        };

        server = import ./server.nix;

      in {
        packages.default = server {
          inherit pkgs;
          zig = zig;
        };

        # Nix shell
        devShells.default = pkgs.mkShell {
          # environment variables
          #REPO_ROOT = repo_root;
          
          # install packages
          packages = [ zig ]; # this language too
        };
      })
    );
}
