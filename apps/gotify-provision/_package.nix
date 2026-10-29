{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
# The script is plain bash with the desired state passed in as environment
# variables, so it can be built -- and shellchecked -- on its own.
writeShellApplication {
  name = "gotify-provision";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./apply.sh;
}
