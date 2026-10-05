# Ship caddy + authelia journal logs to eclair's CrowdSec agent (UDP syslog
# over the tailnet, port 5514). eclair runs the single CrowdSec engine and
# enforces bans at the edge — its nftables sees all public traffic before
# anyone else — so sorbet only needs to get the logs there.
#
# rsyslog reads everything journald forwards to its syslog socket and
# forwards only the caddy/authelia identifiers. ForwardToSyslog is forced
# on because the shared journald module (services/journald.nix) sets it to
# "no" for both hosts; this override only applies where the shipping module
# is imported (sorbet).
#
# crowdsec's syslog input is UDP-only; losing a few lines during a tailnet
# blip is tolerable for leaky-bucket scenarios (attackers keep hammering,
# so the bucket refills).
{lib, ...}: {
  flake.nixosModules.crowdsecShipping = {
    services.journald.settings.Journal.ForwardToSyslog = lib.mkForce true;

    services.rsyslogd = {
      enable = true;
      # Drop the module's default file rules (/var/log/messages etc.) — this
      # instance only forwards to eclair; it must not duplicate the whole
      # journal to disk without rotation.
      defaultConfig = "";
      extraConfig = ''
        # eclair's CrowdSec agent listens on UDP 5514 (unprivileged port so
        # the agent's non-root user can bind it; tailnet-restricted by
        # eclair's firewall). Tags come from journald's SYSLOG_IDENTIFIER:
        # "caddy" and "authelia" — the CrowdSec parsers key off exactly
        # those program names.
        if ($syslogtag startswith "caddy") or ($syslogtag startswith "authelia") then {
            action(type="omfwd" target="100.99.168.34" port="5514" protocol="udp")
        }
      '';
    };
  };
}
