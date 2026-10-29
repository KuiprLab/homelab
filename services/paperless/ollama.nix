# Ollama in podman: CPU-only embedding server backing the paperless-ngx RAG
# index. No LLM here on purpose — 8B-class models pin every core for minutes on
# this box.
#
# Models live on the big disk (/media/data), not the small SSD. The container
# runs as root and owns the tree; the old unit's pre-start chown existed only to
# keep a host user and the mount in sync, which no longer applies.
#
# Nix does not fetch models. After a model change: `podman exec ollama ollama
# pull <model>` as root, then reindex on the consumer side (paperless:
# `podman exec paperless python3 manage.py document_index reindex`).
#
# The image must stay at ollama >= 0.40.4: embeddinggemma-2 declares
# `requires 0.40.4` (model family gemma-embedding2).
#
# Paperless reaches this by aardvark name (http://ollama:11434). The loopback
# publish exists for host-side checks only.
_: {
  flake.nixosModules.ollama = {lib, ...}: {
    # 2G covers embeddinggemma (~0.8G resident) plus the runtime.
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
        # The client inside the image talks to the server over loopback; the
        # server itself is bound to 0.0.0.0 so paperless can reach it.
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
