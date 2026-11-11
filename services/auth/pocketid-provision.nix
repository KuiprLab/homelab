{
  flake.nixosModules.pocketidProvision = {
    imports = [
      (import ../../apps/pocket-id-provision/_module.nix {
        baseUrl = "http://127.0.0.1:1411";
      })
    ];

    sops.secrets."pocketid/clients" = {
      sopsFile = ../../secrets/sorbet/pocketid/clients.json;
      format = "json";
      key = "";
      owner = "root";
      mode = "0400";
      restartUnits = ["pocketid-provision.service"];
    };
  };
}
