# Checks that prove the lab builds and routes, not just that it lints.
#
# Before this, `nix flake check` ran deadnix, statix and treefmt -- all of
# which pass happily on a tree where neither host actually builds.
{
  self,
  lib,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: {
    checks =
      {
        # Every *.ext.kuipr.de vhost must have a matching SNI route on eclair.
        #
        # services/haproxy.nix derives its ACLs from flake.caddyVirtualHosts, so
        # declaring a vhost is supposed to be all it takes to publish a service.
        # If that derivation ever stops covering a host, the symptom is a
        # service that works on the LAN and is silently unreachable from
        # outside -- which nothing else here would catch.
        sni-routing = let
          haproxyConfig = self.nixosConfigurations.eclair.config.services.haproxy.config;

          extHosts =
            lib.filter
            (lib.hasSuffix ".ext.kuipr.de")
            (lib.attrNames self.caddyVirtualHosts);

          routed = host: let
            aclName = "sni_" + lib.replaceStrings ["."] ["_"] host;
          in
            lib.hasInfix "req.ssl_sni -i ${host}" haproxyConfig
            && lib.hasInfix "use_backend be_sorbet if ${aclName}" haproxyConfig;

          missing = lib.filter (host: !routed host) extHosts;
        in
          pkgs.runCommand "check-sni-routing" {} ''
            ${lib.optionalString (extHosts == []) ''
              echo "No *.ext.kuipr.de vhosts found -- this check would pass without testing anything." >&2
              exit 1
            ''}
            ${lib.concatMapStrings (host: ''
                echo "no SNI route on eclair for: ${host}" >&2
              '')
              missing}
            ${lib.optionalString (missing != []) "exit 1"}
            echo "${toString (builtins.length extHosts)} ext vhost(s) routed."
            touch $out
          '';
      }
      # Both hosts are x86_64-linux, so these exist only there. `nix flake
      # check` on a Mac reports them omitted rather than building a Linux
      # closure; CI on ubuntu builds them for real.
      // lib.optionalAttrs (system == "x86_64-linux") {
        host-sorbet = self.nixosConfigurations.sorbet.config.system.build.toplevel;
        host-eclair = self.nixosConfigurations.eclair.config.system.build.toplevel;
      };
  };
}
