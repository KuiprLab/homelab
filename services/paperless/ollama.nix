# Model pull is manual: `podman exec ollama ollama pull <model>`, then reindex in paperless.
{config, ...}: let
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.34";
in {
  flake = {
    podmanProxyHosts.ollama.ip = proxyIp;

    nixosModules.ollama = {lib, ...}: {
      virtualisation.oci-containers.containers.ollama = {
        image = "docker.io/ollama/ollama:latest@sha256:4793b080b3a70fbcca3a79672bd208ff7b3c51692a9ba9b3a319bf1e3915c0a9";
        volumes = [
          "/media/data/ollama:/root/.ollama"
        ];
        environment = {
          OLLAMA_HOST = "0.0.0.0:11434";
          OLLAMA_MODELS = "/root/.ollama";
        };
        log-driver = "journald";
        extraOptions =
          [
            "--network=proxy:ip=${proxyIp}"
            "--memory=2g"
            # The image's client talks over loopback; the server binds 0.0.0.0 for paperless.
          ]
          ++ healthFlags {
            cmd = "OLLAMA_HOST=127.0.0.1:11434 ollama list";
            interval = "60s";
            startPeriod = "30s";
            timeout = "30s";
          };
      };

      systemd.services."podman-ollama".serviceConfig.Restart = lib.mkOverride 90 "on-failure";
    };
  };
}
