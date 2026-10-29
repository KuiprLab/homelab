# Model pull is manual: `podman exec ollama ollama pull <model>`, then reindex in paperless.
_: {
  flake.nixosModules.ollama = {lib, ...}: {
    virtualisation.oci-containers.containers.ollama = {
      image = "docker.io/ollama/ollama:latest@sha256:b2f0122c476bc9fe7ce679d8bb4bd555351e25e2554eefb156f61cb0a89cf429";
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
