{ config
, lib
, dream2nix
, system
, ...
}:
{
  imports = [
    dream2nix.modules.dream2nix.nodejs-package-lock-v3
    dream2nix.modules.dream2nix.nodejs-granular-v3
  ];

  deps = { nixpkgs, ... }: {
    python = nixpkgs.python312;
    inherit (nixpkgs) postgresql;
  };

  nodejs-package-lock-v3 = {
    packageLockFile = "${config.mkDerivation.src}/package-lock.json";
  };

  name = "symfexit-base-theme";
  version = "0.0.1";
}
