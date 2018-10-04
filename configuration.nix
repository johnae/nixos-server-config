# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  meta = import ./meta.nix;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Use the systemd-boot EFI boot loader.
  boot = {
    ## check with lspci -v -s <module>
    ## ip=192.168.1.100:::255.255.255.0:somehostname:eth0:on
    kernelParams = ["ip=${meta.ipv4}:::255.255.255.0:${meta.hostName}:eth0:none"];
    initrd.availableKernelModules = meta.initrdAvailableKernelModules;
    initrd.network = {
      enable = true;
      ssh = {
         enable = true;
         ## use different port to avoid ssh freaking out because of host key
         port = 2222;
         ## nix-shell -p dropbear --command "dropbearkey -t ecdsa -f /tmp/initrd-ssh-key"
         hostECDSAKey = [ "/etc/nixos/initrd-ssh-key" ];
         authorizedKeys = meta.authorizedKeys;
      };
      postCommands = ''
        echo "zfs load-key -a; killall zfs" >> /root/.profile
      '';
    };
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.zfs.enableUnstable = true;
  boot.supportedFilesystems = [ "zfs" ];
  boot.kernelPackages = pkgs.linuxPackages_latest;

  hardware.cpu.intel.updateMicrocode = true;

  networking.hostName = meta.hostName;
  networking.hostId = meta.hostId;
  networking.extraHosts = "127.0.1.1 ${meta.hostName}";
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
  networking.usePredictableInterfaceNames = false; ## works when there's only one ethernet port
  networking.interfaces."${meta.enIf}".ipv4.addresses = [ { address = meta.ipv4; prefixLength = 24; } ];
  networking.defaultGateway = meta.defaultGateway;
  networking.useDHCP = false;

  networking.firewall.enable = false;

  virtualisation.docker.enable = true;
  virtualisation.docker.storageDriver = "zfs";

  i18n = {
    consoleFont = meta.consoleFont;
    consoleKeyMap = meta.consoleKeyMap;
    defaultLocale = meta.defaultLocale;
  };

  time.timeZone = meta.timeZone;

  nixpkgs.config.allowUnfree = true;

  # services.kubernetes = {
  #   path = [ pkgs.zfs ];
  #   roles = [ "master" "node" ];
  #   flannel = { enable = true; };
  # };

  environment.systemPackages = with pkgs; [
    wget vim curl zfsUnstable
  ];

  programs.fish.enable = true;
  services.openssh.enable = true;

  users.defaultUserShell = pkgs.fish;
  users.mutableUsers = false;
  users.groups."${meta.userName}".gid = 1337;
  users.users."${meta.userName}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.fish;
    uid = 1337;
    description = meta.userDescription;
    hashedPassword = meta.userPassword;
    openssh = {
      authorizedKeys = {
        keys = meta.authorizedKeys;
      };
    };
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "19.03"; # Did you read the comment?

}
