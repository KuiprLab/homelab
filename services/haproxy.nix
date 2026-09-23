# haproxy TCP SNI reverse proxy for eclair VPS
# Auto-routes any *.ext.kuipr.de domain (collected from flake.caddyVirtualHosts)
# to sorbet via tailnet — TCP passthrough, caddy on sorbet terminates TLS.
# Hosts in flake.eclairCaddyVirtualHosts are instead routed to the local
# caddy (127.0.0.1:8443), which terminates TLS on the VPS itself.
# IP banning is handled upstream by crowdsec-firewall-bouncer (nftables).
#
# sorbetTailscaleIp is passed via _module.args from eclair/default.nix.
# Set it to the output of: tailscale ip -4   (run on sorbet)
_: {
  flake.eclairNixosModules.haproxy = {
    lib,
    sorbetTailscaleIp,
    caddyVirtualHosts,
    eclairCaddyVirtualHosts,
    ...
  }: let
    # Collect all *.ext.kuipr.de hostnames contributed by service modules.
    extHostNames =
      lib.filter
      (lib.hasSuffix ".ext.kuipr.de")
      (lib.attrNames caddyVirtualHosts);

    localHostNames = lib.attrNames eclairCaddyVirtualHosts;

    # One ACL + use-backend line per ext host.
    aclBlockFor = backend:
      lib.concatMapStrings (host: let
        aclName = "sni_" + lib.replaceStrings ["."] ["_"] host;
      in ''
        acl ${aclName} req.ssl_sni -i ${host}
        use_backend ${backend} if ${aclName}
      '');

    aclBlock = aclBlockFor "be_local" localHostNames + aclBlockFor "be_sorbet" extHostNames;
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
          # ACME HTTP-01 for hosts terminated by the local caddy: must reach
          # caddy's http_port unredirected, everything else goes to HTTPS.
          acl acme_challenge path_beg /.well-known/acme-challenge/
          use_backend be_local_http if acme_challenge
          http-request redirect scheme https code 301 unless acme_challenge

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
        # Backend: local caddy (services hosted on eclair itself)
        #--------------------------------------------------------------------
        backend be_local
          mode tcp
          server local 127.0.0.1:8443 check inter 10s rise 2 fall 3

        backend be_local_http
          mode http
          server local 127.0.0.1:8080

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
