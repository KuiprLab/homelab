{
  # SSH into sorbet from pangolin clients off-LAN (private SSH resource):
  # `pangolin ssh sorbet` from the pangolin CLI, or plain `ssh root@sorbet`
  # through the client tunnel (the alias resolves to the resource's alias
  # IP inside the client tunnel). Existing host credentials — no auth
  # daemon; TCP 22 is always allowed for ssh-mode resources.
  flake.pangolinVirtualHosts."ssh-sorbet" = {
    site = "sorbet";
    name = "Sorbet SSH";
    subdomain = "ssh-sorbet.int.kuipr.de";
    port = 22;
    extra = {
      mode = "ssh";
      alias = "sorbet";
      # scheme is meaningless for ssh; nullable per blueprint schema.
      scheme = null;
      users = ["admin@kuipr.de"];
    };
  };
}
