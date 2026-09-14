# haproxy TCP SNI reverse proxy for eclair VPS
# Auto-routes any *.ext.kuipr.de domain (collected from flake.caddyVirtualHosts)
# to sorbet via tailnet — TCP passthrough, caddy on sorbet terminates TLS.
# IP banning is handled upstream by crowdsec-firewall-bouncer (nftables).
#
# sorbetTailscaleIp is passed via _module.args from eclair/default.nix.
# Set it to the output of: tailscale ip -4   (run on sorbet)
_: {
  flake.eclairNixosModules.haproxy = {
    lib,
    sorbetTailscaleIp,
    caddyVirtualHosts,
    ...
  }: let
    # Collect all *.ext.kuipr.de hostnames contributed by service modules.
    extHostNames =
      lib.filter
      (lib.hasSuffix ".ext.kuipr.de")
      (lib.attrNames caddyVirtualHosts);

    # One ACL + use-backend line per ext host.
    aclBlock =
      lib.concatMapStrings (host: let
        aclName = "sni_" + lib.replaceStrings ["."] ["_"] host;
      in ''
        acl ${aclName} req.ssl_sni -i ${host}
        use_backend be_sorbet if ${aclName}
      '')
      extHostNames;
  in {
    networking.firewall.allowedTCPPorts = [80 443];
    # Stats, tailnet-only.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [8404];

    services.haproxy = {
      enable = true;
      config = ''
        global
          log /dev/log local0
          log /dev/log local1 notice
          maxconn 50000
          user haproxy
          group haproxy
          daemon

        defaults
          log     global
          option  tcplog
          option  dontlognull
          timeout connect 5s
          timeout client  30s
          timeout server  30s

        #--------------------------------------------------------------------
        # Stats — scraped by local gatus
        #--------------------------------------------------------------------
        # CSV at /stats;csv exposes backend up/down so gatus can alert on
        # be_sorbet flipping to DOWN before users see 503s.
        # Bound to all interfaces; firewall restricts 8404 to tailscale0 +
        # loopback so it's never publicly reachable.
        frontend fe_stats
          mode http
          bind *:8404
          stats enable
          stats uri /stats
          stats refresh 10s
          stats show-node
          # Health check endpoint for monitoring tools
          monitor-uri /haproxy_health

        #--------------------------------------------------------------------
        # HTTP — redirect to HTTPS
        #--------------------------------------------------------------------
        frontend fe_http
          mode http
          bind *:80
          http-request redirect scheme https code 301

        #--------------------------------------------------------------------
        # HTTPS — TCP SNI passthrough
        #--------------------------------------------------------------------
        frontend fe_https
          mode tcp
          bind *:443
          tcp-request inspect-delay 5s
          tcp-request content accept if { req.ssl_hello_type 1 }

        ${aclBlock}
          default_backend be_reject

        #--------------------------------------------------------------------
        # Backend: sorbet via tailnet (TCP passthrough, caddy handles TLS)
        #--------------------------------------------------------------------
        backend be_sorbet
          mode tcp
          server sorbet ${sorbetTailscaleIp}:443 check inter 10s rise 2 fall 3

        #--------------------------------------------------------------------
        # Backend: reject unknown SNI
        #--------------------------------------------------------------------
        backend be_reject
          mode tcp
          tcp-request content reject
      '';
    };
  };
}
