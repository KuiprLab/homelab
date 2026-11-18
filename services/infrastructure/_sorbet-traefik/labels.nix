{lib}: name: vh: let
  router = "traefik.http.routers.${name}";
  service = "traefik.http.services.${name}";

  # A trailing * means the whole subtree; anything else is one exact path.
  bypassRule = path:
    if lib.hasSuffix "/*" path
    then "PathPrefix(`${lib.removeSuffix "*" path}`)"
    else "Path(`${path}`)";

  bypassRouter = index: path: {
    "${router}-bypass-${toString index}.rule" = "Host(`${vh.subdomain}`) && ${bypassRule path}";
    "${router}-bypass-${toString index}.entrypoints" = "websecure";
    "${router}-bypass-${toString index}.tls.certresolver" = "letsencrypt";
    "${router}-bypass-${toString index}.service" = name;
    "${router}-bypass-${toString index}.priority" = "1000";
    "${router}-bypass-${toString index}.middlewares" = "sec-headers@file";
  };
in
  {
    "traefik.enable" = "true";
    "${router}.rule" = "Host(`${vh.subdomain}`)";
    "${router}.entrypoints" = "websecure";
    "${router}.tls.certresolver" = "letsencrypt";
    "${router}.service" = name;
    "${router}.middlewares" = lib.concatStringsSep "," (["sec-headers@file"] ++ lib.optional vh.auth.enable "oidc-auth@file");
    "${service}.loadbalancer.server.port" = toString vh.port;
  }
  // lib.optionalAttrs (vh.protocol == "https") {
    "${service}.loadbalancer.server.scheme" = "https";
  }
  // lib.optionalAttrs (vh.serversTransport != null) {
    "${service}.loadbalancer.serverstransport" = vh.serversTransport;
  }
  // lib.mergeAttrsList (lib.imap0 bypassRouter vh.auth.bypassPaths)
