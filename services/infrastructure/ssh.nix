{
  flake.pangolinVirtualHosts."ssh-sorbet" = {
    site = "sorbet";
    name = "Sorbet SSH";
    subdomain = "ssh-sorbet.int.kuipr.de";
    port = 22;
    extra = {
      mode = "ssh";
      alias = "ssh-sorbet.int.kuipr.de";
      scheme = null;
      users = ["admin@kuipr.de"];
    };
  };
}
