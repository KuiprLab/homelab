_: {
  flake.crossaintNixosModules.crossaintConfiguration = _: {
    system.stateVersion = "26.11";

    networking.hostName = "crossaint";

    services.qemuGuest.enable = true;

    # The base image creates this account; declare it so sudo keeps working.
    users.users = {
      nixos = {
        isNormalUser = true;
        extraGroups = ["wheel"];
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdCR6ug7iyoOzbG30Yn5kcgp6Tngd3NNi2+QSoIaUy/"
        ];
      };

      root.openssh.authorizedKeys.keys = [
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCo089vTmBwFAMv6d7ix3D6gPx0X0DEwOELB0i9AyDpct4kj3II8IjtwovZDalE53CZAlczhae+/9EV+3cn1YwvKMEU9MkY3nY6/HIPqvQaWVNrhLAP7W1JWNMwNl+ndkm+Xa1ZlaYbOJrKED8E63j2j5WNnNN6WUld7d4Nf5oog0YaYYoD22fiMvnTMdFg2pE2lLFZ4mX2NBHU8r/1hcy6XTXdryoZB4KuzvnMOZPb5j48rsH6AZG5i9CMq7iSi3+DeSGzdrxVvJ1HWKTpTlKlvz/7LKhrCwtXrvFwzxh4xxFig/As05LfmxShThUb1QqS874USBwM5lacrZ4lJbIEwbtQ9zJad8p0pVzlby+BwLaQmmljrR9H0AZMagmD0Gv5K/DC035XCI9acSazL84qJ0IfGugfXdFQbT+ViFRrV7+9J5IbulOV40lwHrgnIeFc2Msbe2PelphKIlrx9JqW6ArtT7zbtbG8q+oZSb8TqCdFx5pZuQCA8gtj4Y5wxo0pFhym5qqN6Eh0CbliqYsDwIcUfmkj0omsFXFLN5U9D25jUxPmFZUFU/PJnbWxjfu6835PZtchHozV/vqYqc8WKBis+HWjBM1OH26fbo7FmT60hod8K6fsKV6HN/tpuY9gCQBD/CuVO+nlSBr/kVmO9KGi9jEaPTF2JylnujN1ow=="
      ];
    };

    security.sudo.wheelNeedsPassword = false;
  };
}
