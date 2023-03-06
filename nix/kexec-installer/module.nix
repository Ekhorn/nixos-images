{ config, lib, modulesPath, pkgs, ... }:
let
  restore-network = pkgs.writers.writePython3 "restore-network" {
    flakeIgnore = ["E501"];
  } ./restore_routes.py;

  # does not link with iptables enabled
  iprouteStatic = pkgs.pkgsStatic.iproute2.override { iptables = null; };
in {
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
  ];

  # We are stateless, so just default to latest.
  system.stateVersion = config.system.nixos.version;

  # This is a variant of the upstream kexecScript that also allows embedding
  # a ssh key.
  system.build.kexecRun = pkgs.writeScript "kexec-run" ''
    #!/usr/bin/env bash
    set -ex
    shopt -s nullglob
    SCRIPT_DIR=$( cd -- "$( dirname -- "''${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    INITRD_TMP=$(TMPDIR=$SCRIPT_DIR mktemp -d)
    cd "$INITRD_TMP"
    pwd
    mkdir -p initrd/ssh
    pushd initrd
    homes=(/root)

    if [[ -n "''${SUDO_USER-}" ]]; then
      sudo_home=$(bash -c "cd ~$(printf %q "$SUDO_USER") && pwd")
      homes+=("$sudo_home")
    fi
    for home in "''${homes[@]}"; do
      for file in .ssh/authorized_keys .ssh/authorized_keys2; do
        key="$home/$file"
        if [[ -e "$key" ]]; then
          # workaround for debian shenanigans
          grep -o '\(ssh-[^ ]* .*\)' "$key" >> ssh/authorized_keys || true
        fi
      done
    done
    # Typically for NixOS
    if [[ -e /etc/ssh/authorized_keys.d/root ]]; then
      cat /etc/ssh/authorized_keys.d/root >> ssh/authorized_keys
    fi
    if [[ -n "''${SUDO_USER-}" ]] && [[ -e "/etc/ssh/authorized_keys.d/$SUDO_USER" ]]; then
      cat "/etc/ssh/authorized_keys.d/$SUDO_USER" >> ssh/authorized_keys
    fi
    for p in /etc/ssh/ssh_host_*; do
      cp -a "$p" ssh
    done

    # save the networking config for later use
    if type -p ip &>/dev/null; then
      "$SCRIPT_DIR/ip" --json addr > addrs.json

      "$SCRIPT_DIR/ip" -4 --json route > routes-v4.json
      "$SCRIPT_DIR/ip" -6 --json route > routes-v6.json
    else
      echo "Skip saving static network addresses because no iproute2 binary is available." 2>&1
      echo "The image can depends only on DHCP to get network after reboot!" 2>&1
    fi

    find . | cpio -o -H newc | gzip -9 > ../extra.gz
    popd
    cat extra.gz >> "''${SCRIPT_DIR}/initrd"
    rm -r "$INITRD_TMP"

    # Dropped --kexec-syscall-auto because it broke on GCP...
    "$SCRIPT_DIR/kexec" --load "''${SCRIPT_DIR}/bzImage" \
      --initrd="''${SCRIPT_DIR}/initrd" \
      --command-line "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}"

    # Disconnect our background kexec from the terminal
    echo "machine will boot into nixos in in 6s..."
    if [[ -e /dev/kmsg ]]; then
      # this makes logging visible in `dmesg`, or the system consol or tools like journald
      exec > /dev/kmsg 2>&1
    else
      exec > /dev/null 2>&1
    fi
    # We will kexec in background so we can cleanly finish the script before the hosts go down.
    # This makes integration with tools like terraform easier.
    nohup bash -c "sleep 6 && '$SCRIPT_DIR/kexec' -e" &
  '';

  system.build.kexecTarball = pkgs.runCommand "kexec-tarball" {} ''
    mkdir kexec $out
    cp "${config.system.build.netbootRamdisk}/initrd" kexec/initrd
    cp "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}" kexec/bzImage
    cp "${config.system.build.kexecRun}" kexec/run
    cp "${pkgs.pkgsStatic.kexec-tools}/bin/kexec" kexec/kexec
    cp "${iprouteStatic}/bin/ip" kexec/ip
    tar -czvf $out/nixos-kexec-installer-${pkgs.stdenv.hostPlatform.system}.tar.gz kexec
  '';

  # IPMI SOL console redirection stuff
  boot.kernelParams =
    [ "console=tty0" ] ++
    (lib.optional (pkgs.stdenv.hostPlatform.isAarch32 || pkgs.stdenv.hostPlatform.isAarch64) "console=ttyAMA0,115200") ++
    (lib.optional (pkgs.stdenv.hostPlatform.isRiscV) "console=ttySIF0,115200") ++
    [ "console=ttyS0,115200" ];

  documentation.enable = false;
  # Not really needed. Saves a few bytes and the only service we are running is sshd, which we want to be reachable.
  networking.firewall.enable = false;

  systemd.network.enable = true;
  networking.dhcpcd.enable = false;

  # for detection if we are on kexec
  environment.etc.is_kexec.text = "true";

  # for zapping of disko
  environment.systemPackages = [
    pkgs.jq
  ];

  systemd.services.restore-network = {
    before = [ "network-pre.target" ];
    wants = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${restore-network} /root/network/addrs.json /root/network/routes-v4.json /root/network/routes-v6.json /etc/systemd/network"
      ];
    };

    unitConfig.ConditionPathExists = [
      "/root/network/addrs.json"
      "/root/network/routes-v4.json"
      "/root/network/routes-v6.json"
    ];
  };

  systemd.services.log-network-status = {
    wantedBy = [ "multi-user.target" ];
    # No point in restarting this. We just need this after boot
    restartIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal+console";
      ExecStart = [
        # Allow failures, so it still prints what interfaces we have even if we
        # not get online
        "-${pkgs.systemd}/lib/systemd/systemd-networkd-wait-online"
        "${pkgs.iproute2}/bin/ip -c addr"
        "${pkgs.iproute2}/bin/ip -c -6 route"
        "${pkgs.iproute2}/bin/ip -c -4 route"
      ];
    };
  };

  # Restore ssh host and user keys if they are available.
  # This avoids warnings of unknown ssh keys.
  boot.initrd.postMountCommands = ''
    mkdir -m 700 -p /mnt-root/root/.ssh
    mkdir -m 755 -p /mnt-root/etc/ssh
    mkdir -m 755 -p /mnt-root/root/network
    if [[ -f ssh/authorized_keys ]]; then
      install -m 400 ssh/authorized_keys /mnt-root/root/.ssh
    fi
    install -m 400 ssh/ssh_host_* /mnt-root/etc/ssh
    cp *.json /mnt-root/root/network/
  '';
}