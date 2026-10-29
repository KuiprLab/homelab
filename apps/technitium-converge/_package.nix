{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "technitium-converge";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./converge.sh;
}
