# Model pull is manual: `podman exec ollama ollama pull <model>`, then reindex in paperless.
_: let
  proxyIp = "10.89.0.34";
in {
  flake = {
    podmanProxyHosts.ollama.ip = proxyIp;

    nixosModules.ollama = {lib, ...}: {
      virtualisation.oci-containers.containers.ollama = {
        image = "docker.io/ollama/ollama:latest@sha256:910d0d8107b538fb0894e63163eb195de0cc7aefcbc666dc62d3b18f71124592";
        volumes = [
          "/media/data/ollama:/root/.ollama"
        ];
        environment = {
          OLLAMA_HOST = "0.0.0.0:11434";
          OLLAMA_MODELS = "/root/.ollama";
        };
        log-driver = "journald";
        extraOptions = [
          "--network=proxy:ip=${proxyIp}"
          "--memory=2g"
          # The image's client talks over loopback; the server binds 0.0.0.0 for paperless.
          "--health-cmd=OLLAMA_HOST=127.0.0.1:11434 ollama list"
          "--health-interval=60s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=30s"
        ];
      };

      systemd.services."podman-ollama".serviceConfig.Restart = lib.mkOverride 90 "on-failure";
    };
  };
}
