# fail2ban intrusion prevention for eclair
# Monitors SSH logs and bans IPs with repeated failed authentication attempts.
# The sshd jail is automatically enabled since services.openssh.enable = true.
_: {
  flake.eclairNixosModules.fail2ban = _: {
    services.fail2ban = {
      enable = true;

      maxretry = 5;
      bantime = "1h";
      bantime-increment = {
        enable = true;
        maxtime = "168h"; # 1 week
        factor = "2";
        multipliers = "1 2 4 8 16 32 64";
      };
    };
  };
}
