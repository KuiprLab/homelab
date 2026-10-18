{
  # Pangolin exit-node on sorbet: full-tunnel access to the home LAN for
  # pangolin clients. Replaces sorbet's tailscale subnet-router
  # (advertise 192.168.0.0/24) — semantics differ: it routes the entire
  # client traffic through sorbet, toggled per-client in the app.
  # Admin access assumed; users list kept explicit for clarity.
  flake.pangolinExitNodes."home-lan" = {
    site = "sorbet";
    name = "Home LAN";
    users = ["admin@kuipr.de"];
  };
}
