# Imported into every render: types whose CRDs the cluster already ships.
{...}: {
  kubernetes.customTypes = [
    {
      group = "onepassword.com";
      version = "v1";
      kind = "OnePasswordItem";
      attrName = "onePasswordItems";
    }
  ];
}
