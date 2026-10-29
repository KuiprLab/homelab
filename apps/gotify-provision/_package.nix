{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
writeShellApplication {
  name = "gotify-provision";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./apply.sh;
}
