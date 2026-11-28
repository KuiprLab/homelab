_: {
  networking.firewall.allowedTCPPorts = [6443];

  boot = {
    kernelModules = ["br_netfilter" "overlay"];
    kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
    };
  };

  services.k3s = {
    enable = true;
    role = "server";
    # k3s bundles traefik, servicelb, coredns, local-path and metrics-server; Longhorn replaces local-path.
    extraFlags = [
      "--disable=traefik"
      "--disable=metrics-server"
      "--disable=local-path"
    ];
  };
}
