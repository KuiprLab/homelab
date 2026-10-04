_: {
  flake.nixosModules.ollama = {
    # CPU-only inference server backing paperless-ngx AI features
    # (suggestions + RAG embedding index). No GPU on sorbet; 8B-class
    # quantized models run at acceptable speeds on CPU.
    services.ollama = {
      enable = true;
      modelsDir = "/media/data/ollama"; # big disk, not the small SSD
    };

    # Belt and braces: the module creates modelsDir, but /media/data is a
    # separate mount, so make sure the directory exists with the right owner.
    systemd.tmpfiles.rules = [
      "d /media/data/ollama 0750 ollama ollama -"
    ];

    # Guard the rest of the box: an 8B q4 model is ~6G resident; cap the
    # service so ollama can never starve the ~10G of other services.
    systemd.services.ollama.serviceConfig.MemoryMax = "10G";
  };
}
