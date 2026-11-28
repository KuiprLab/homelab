_: {
  # 10250: kubelet; the API server and metrics-server scrape it.
  networking.firewall.allowedTCPPorts = [6443 10250];

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
    # k3s bundles traefik, servicelb, coredns, local-path and metrics-server.
    extraFlags = [
      "--disable=traefik"
    ];
  };
}
