{
  config,
  lib,
  dream2nix,
  system,
  ...
}:
let
  pyproject = lib.importTOML (config.mkDerivation.src + /pyproject.toml);
in
{
  imports = [
    dream2nix.modules.dream2nix.pip
  ];

  deps =
    { nixpkgs, ... }:
    {
      python = nixpkgs.python314;
      file = nixpkgs.file;
      inherit (nixpkgs) postgresql;
    };

  mkDerivation = {
    # During the lockfile generation, we need tools from postgresql for the psycopg-c dependency of psycopg
    nativeBuildInputs = [
      config.deps.postgresql
      config.deps.python.pkgs.setuptools
      config.deps.python.pkgs.setuptools-scm
    ];
  };

  buildPythonPackage = {
    format = lib.mkForce "pyproject";
    pythonImportsCheck = [
      "symfexit"
    ];
  };

  name = "symfexit";
  version = "0.0.1";

  pip = {nixpkgs, ... }: {
    requirementsFiles = [ "./requirements.txt" ];
    flattenDependencies = true;
    overrides.django.buildPythonPackage.makeWrapperArgs = [
      "--set-default"
      "DJANGO_SETTINGS_MODULE"
      "symfexit.root.settings"
    ];

    overrides.psycopg-c = {
      imports = [ dream2nix.modules.dream2nix.nixpkgs-overrides ];
      nixpkgs-overrides.enable = true;
      mkDerivation.nativeBuildInputs = [ config.deps.postgresql ];
    };
    overrides.python-magic = {
      mkDerivation.buildInputs = [ config.deps.file ];
      mkDerivation.postInstall = ''
        substituteInPlace $out/lib/python*/site-packages/magic/loader.py --replace-fail "find_library('magic')" "'${config.deps.file}/lib/libmagic.so'"
      '';
    };
  };
}
