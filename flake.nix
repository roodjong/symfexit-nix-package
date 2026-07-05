{
  description = "Symfexit membersite";

  inputs = {
    dream2nix.url = "github:nix-community/dream2nix";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/*.tar.gz";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      dream2nix,
      ...
    }:

    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: (forSystem system f));

      forSystem =
        system: f:
        f rec {
          inherit system;
          linux-system = pkgs.lib.replaceStrings [ "darwin" ] [ "linux" ] system;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ ];
          };
          pkgs-linux = import nixpkgs {
            system = linux-system;
            overlays = [ ];
          };
          lib = pkgs.lib;
        };
    in
    {
      apps = forAllSystems (
        { system, pkgs, ... }:
        {
          symfexit-docker = {
            type = "app";
            program = "${self.packages.${system}.symfexit-docker}";
          };
          symfexit-nginx = {
            type = "app";
            program = "${self.packages.${system}.symfexit-nginx}";
          };
          default = {
            type = "app";
            program = "${self.packages.${system}.default}";
          };
        }
      );

      packages = forAllSystems (
        {
          system,
          linux-system,
          pkgs,
          pkgs-linux,
          ...
        }:
        let
          lib = pkgs.lib;
          src = pkgs.fetchFromGitHub {
            owner = "roodjong";
            repo = "symfexit";
            rev = "bc36c3cb21142c04a8dcc78e35e603c18a648b61";
            hash = "sha256-RvXHzRLwTSX3/gKQqmGutVr8kINc1l5p+MqgqAwS15U=";
          };
          symfexit-npm-deps = dream2nix.lib.evalModules {
            packageSets.nixpkgs = nixpkgs.legacyPackages.${system};
            modules = [
              ./theme.nix
              {
                mkDerivation.src = "${src}/symfexit/theme/static_src";
              }
            ];
          };
          theme-sources =
            pkgs.runCommand "theme-sources"
              {
                pythonSrc = src;
                node_modules = "${symfexit-npm-deps.config.package-func.result}/lib/node_modules/symfexit-base-theme/node_modules";
                node_bins = "${symfexit-npm-deps.config.package-func.result}/lib/node_modules/.bin";
              }
              ''
                mkdir -p $out
                cp -r $pythonSrc/* $out
                chmod -R u+w $out
                mkdir -p $out/symfexit/theme/static_src/node_modules
                cp -r $node_modules/* $out/symfexit/theme/static_src/node_modules/
                # The .bin directory contains symlinks to nodejs scripts. Copy the symlinks over to $out/symfexit/theme/static_src/node_modules/.bin and fix the symlinks to point to the correct location in $out/symfexit/theme/static_src/node_modules
                mkdir -p $out/symfexit/theme/static_src/node_modules/.bin
                for bin in $(find $node_bins -type l); do
                  target=$(readlink $bin)
                  basename=$(basename $bin)
                  ln -s ../''${target#../symfexit-base-theme/node_modules/} $out/symfexit/theme/static_src/node_modules/.bin/$basename
                done
                touch $out/symfexit/theme/static_src/src/theme-overrides.css
              '';
          symfexit-base-theme =
            pkgs.runCommand "symfexit-base-theme"
              {
                src = theme-sources;
              }
              ''
                mkdir -p $out/staticfiles/css/dist
                export PATH=${pkgs.nodejs}/bin:$PATH
                cd $src/symfexit/theme/static_src
                NODE_ENV=production ${pkgs.nodejs}/bin/node node_modules/@tailwindcss/cli/dist/index.mjs -i ./src/styles.css -o $out/staticfiles/css/dist/styles.css --minify
              '';
          symfexit-python = self.packages.${system}.symfexit-package.config.deps.python.withPackages (
            ps: with ps; [
              self.packages.${system}.symfexit-package.config.package-func.result
              uvicorn
            ]
          );
          linux-symfexit-python =
            self.packages.${linux-system}.symfexit-package.config.deps.python.withPackages
              (
                ps: with ps; [
                  self.packages.${linux-system}.symfexit-package.config.package-func.result
                  uvicorn
                ]
              );
          collectstatic = pkgs.runCommand "symfexit-staticfiles" { } ''
            # dummy secret key to be able to generate static files in production mode
            DJANGO_ENV=production SYMFEXIT_SECRET_KEY=dummy CONTENT_DIR=$(pwd) STATIC_ROOT=$out/staticfiles ${symfexit-python}/bin/django-admin collectstatic --noinput
          '';
        in
        rec {
          symfexit-package = dream2nix.lib.evalModules {
            packageSets.nixpkgs = nixpkgs.legacyPackages.${system};
            modules = [
              ./default.nix
              {
                paths.projectRoot = ./.;
                paths.projectRootFile = "flake.nix";
                paths.package = ./.;
                paths.lockFile = "lock.${system}.json";
                mkDerivation.src = src;
              }
            ];
          };
          inherit symfexit-npm-deps;
          symfexit-staticfiles = pkgs.symlinkJoin {
            name = "symfexit-staticfiles";
            paths = [
              symfexit-base-theme
              collectstatic
            ];
          };
          symfexit-docker = pkgs.dockerTools.streamLayeredImage {
            name = "symfexit";
            contents = pkgs.buildEnv {
              name = "symfexit-nginx";
              paths = with pkgs-linux.dockerTools; [
                symfexit-staticfiles
                (fakeNss.override {
                  extraGroupLines = [
                    "nogroup:x:65534:"
                  ];
                })
                binSh
                pkgs-linux.coreutils
              ];
              pathsToLink = [
                "/staticfiles"
                "/etc"
                "/bin"
                "/var"
              ];
            };

            config = {
              Entrypoint = [
                (pkgs-linux.writeShellScript "entrypoint.sh" ''
                  # Default DJANGO_ENV to production
                  export DJANGO_ENV="''${DJANGO_ENV:-production}"
                  # Required for npx/npm commands to work
                  export NODE_EXTRA_CA_CERTS="${pkgs-linux.cacert}/etc/ssl/certs/ca-bundle.crt"

                  if [ "$1" = "nginx" ]; then
                    mkdir -p {/tmp,/var/log/nginx}

                    ln -s /dev/stderr /var/log/nginx/error.log
                    ln -s /dev/stdout /var/log/nginx/access.log

                    shift
                    exec "${pkgs-linux.nginx}/bin/nginx" "-g" "daemon off;" "$@"
                  elif [ "$1" = "uvicorn" ]; then
                    shift
                    exec "${linux-symfexit-python}/bin/uvicorn" "$@"
                  elif [ "$1" = "django-admin" ]; then
                    shift
                    exec "${linux-symfexit-python}/bin/django-admin" "$@"
                  fi
                  exec "$@"
                '')
              ];
              Cmd = [
                "uvicorn"
                "symfexit.root.asgi:application"
              ];
              ExposedPorts = {
                "8000/tcp" = { };
              };
              Env = [
                "PATH=${pkgs-linux.nodejs}/bin:/bin"
                "DYNAMIC_THEME_WORKING_DIR=${theme-sources}/symfexit/theme/static_src"
                "DJANGO_ADMIN_COMMAND=${linux-symfexit-python}/bin/django-admin"
              ];
            };
          };
          symfexit-docker-tag = pkgs.writeShellScriptBin "symfexit-docker-tag" "echo ${symfexit-docker.imageTag}";
        }
      );

    };
}
