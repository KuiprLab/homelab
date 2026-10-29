{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "pangolin-apply";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./apply.sh;
}
