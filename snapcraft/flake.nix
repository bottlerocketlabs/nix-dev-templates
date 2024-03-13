{
  description = "A Nix-flake-based snap development environment";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    crafts.url = "github:jnsgruk/crafts-flake";
    nix-snapd.url = "github:io12/nix-snapd";
  };

  outputs = { self, nixpkgs, crafts, nix-snapd, ... }:
    let
      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      rootpw = "password";
      sshport = "2222";
      sshoptions =
        "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -p ${sshport}";
      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems (system:
          f {
            pkgs = import nixpkgs {
              inherit system;
              overlays = [ crafts.overlay ];
            };

          });
    in
    {
      nixosConfigurations = {
        snapVM = nixpkgs.lib.nixosSystem {
          specialArgs = {
            flake = self;
            inherit crafts;
            inherit nix-snapd;
            inherit rootpw;
            inherit sshport;
            inherit sshoptions;
          };
          modules = [
            ({ modulesPath, flake, lib, pkgs, ... }: {
              imports = [
                "${modulesPath}/virtualisation/qemu-vm.nix"
                nix-snapd.nixosModules.default
              ];
              system.stateVersion = "23.11";
              nixpkgs.hostPlatform = "x86_64-linux";
              nixpkgs.overlays = [ crafts.overlay ];

              virtualisation = {
                forwardPorts = [{
                  from = "host";
                  host.port = lib.strings.toInt sshport;
                  guest.port = 22;
                }];
                cores = 2;
                memorySize = 5120;
                diskSize = 20240;
                graphics = true;
                lxd.enable = true;
              };

              networking.firewall.enable = false;
              services.openssh.enable = true;
              services.openssh.settings.PermitRootLogin = "yes";
              services.snap.enable = true;
              users.extraUsers.root.password = "${rootpw}";

              environment.systemPackages = with pkgs; [
                unixtools.xxd
                git
                snapcraft
                patchelf
                gcc
                (writeShellScriptBin "snapcraft-log" ''
                  set -euo pipefail
                  LOG_DIR="/root/.local/state/snapcraft/log"
                  LATEST_LOG="$(ls -t $LOG_DIR/*.log | head -1)"
                  echo "Snapcraft log $LATEST_LOG:"
                  cat "$LATEST_LOG"
                '')
              ];
            })
          ];
        };
      };
      snapVM = self.nixosConfigurations.snapVM.config.system.build.vm;
      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            sshpass
            rsync
            (writeShellScriptBin "snapcraft" ''
              set -euo pipefail
              # Function to help run arbitrary commands in the test VM over SSH.
              run_cmd() {
                  sshpass -p${rootpw} ssh -A -t root@localhost -o UserKnownHostsFile=/dev/null ${sshoptions} -- "$@"
              }
              copy_files() {
                  sshpass -p${rootpw} rsync -avz --exclude ".direnv" --exclude "*.qcow2" -e 'ssh ${sshoptions}' "$@"
              }
              # Simple connection test / waiter to ensure SSH is available before running
              # the command we actually care about.
              while ! run_cmd cat /etc/hostname >/dev/null; do
                  echo "Waiting for SSH server to be available..."
                  sleep 1;
              done
              copy_files --exclude "*.snap" "$(pwd)/" root@localhost:/root
              run_cmd "mkdir -p /root/.ssh && ssh-keyscan -H gitlab.ocado.tech &> /root/.ssh/known_hosts"
              run_cmd "lxd init --auto && snapcraft --destructive $@ || snapcraft-log"
              copy_files root@localhost:/root/*.snap .
            '')
          ];
        };
      });
    };
}
