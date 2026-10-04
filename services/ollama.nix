_: {
  flake.nixosModules.ollama = {
    # CPU-only inference server backing paperless-ngx AI features
    # (suggestions + RAG embedding index). No GPU on sorbet; 8B-class
    # quantized models run at acceptable speeds on CPU.
    services.ollama = {
      enable = true;
      modelsDir = "/media/data/ollama"; # big disk, not the small SSD
      # Pin a persistent user so modelsDir ownership is stable.
      user = "ollama";
    };

    systemd.services.ollama = {
      serviceConfig = {
        MemoryMax = "10G";

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
