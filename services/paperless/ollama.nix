# Model pull is manual: `podman exec ollama ollama pull <model>`, then reindex in paperless.
_: {
  flake.nixosModules.ollama = {lib, ...}: {
    virtualisation.oci-containers.containers.ollama = {
      image = "docker.io/ollama/ollama:latest@sha256:0e59999e0e8f9fd4e704bd788a89b7e4cad399367fb1365f8c102ac662288761";
      volumes = [
        "/media/data/ollama:/root/.ollama"
      ];
      ports = ["127.0.0.1:11434:11434"];
      environment = {
        OLLAMA_HOST = "0.0.0.0:11434";
        OLLAMA_MODELS = "/root/.ollama";
      };
      log-driver = "journald";
      extraOptions = [
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
}
