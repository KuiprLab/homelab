_: {
  flake.nixosModules.ollama = {
    # CPU-only embedding server backing paperless-ngx RAG index
    # (nomic-embed-text, ~300M resident). No LLM here on purpose —
    # 8B-class models pin every core for minutes on this box.
    services.ollama = {
      enable = true;
      modelsDir = "/media/data/ollama"; # big disk, not the small SSD
      # Pin a persistent user so modelsDir ownership is stable.
      user = "ollama";
    };

    systemd.services.ollama = {
      serviceConfig = {
        Restart = "on-failure"; # don't stay dead after an OOM blip
        # Cap the CPU budget: llama.cpp defaults to ALL cores, which made
        # suggestions and nightly re-indexes pin the whole box. 200% = 2
        # cores max, for anything ollama does.
        CPUQuota = "200%";
        # Embedding-only now: embeddinggemma ~0.8G resident + runtime.
        MemoryMax = "2G";

        # modelsDir is on a separate mount. A tmpfiles "d" rule can't fix the
        # owner of a pre-existing directory, so enforce it as root (+ prefix)
        # before the server starts; the ollama user exists by then.
        ExecStartPre = [
          "+/bin/sh -c 'mkdir -p /media/data/ollama && /run/current-system/sw/bin/chown ollama:ollama /media/data/ollama'"
        ];
      };
    };
  };
}
