{
  inputs,
  lib,
  config,
  ...
}: let
  k8sModules = config.flake.k8sModules;

  render = system: name: contrib:
    (inputs.kubenix.evalModules.${system} {
      module = {kubenix, ...}: {
        imports = [
          kubenix.modules.k8s
          contrib
        ];
        kubenix.project = name;
        # One sha1 over the whole list would relabel every object on any change.
        kubernetes.addHashLabel = false;
        # Pinned to the k3s version, so a nixpkgs bump does not rewrite every manifest.
        kubernetes.version = "1.36";
      };
    }).config.kubernetes.resultYAML;
in {
  options.flake.k8sModules = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {};
    description = "kubenix modules contributed by services and apps.";
  };

  config.perSystem = {
    system,
    pkgs,
    self',
    ...
  }: {
    checks.manifests = self'.packages.manifests;

    packages =
      lib.mapAttrs' (
        name: module: lib.nameValuePair "manifests-${name}" (render system name module)
      )
      k8sModules
      // {
        manifests = pkgs.linkFarm "manifests" (
          lib.mapAttrsToList (name: module: {
            name = "${name}/app.yaml";
            path = render system name module;
          })
          k8sModules
        );
      };
  };
}
