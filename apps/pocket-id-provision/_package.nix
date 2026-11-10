{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "pocket-id-provision";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./apply.sh;
}
