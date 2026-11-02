{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "pocket-id-converge";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./converge.sh;
}
