{
  coreutils,
  curl,
  jq,
  writeShellApplication,
}:
# The script is plain bash with every identifier passed in as an environment
# variable, so it can be built -- and shellchecked -- on its own.
writeShellApplication {
  name = "pangolin-apply";
  runtimeInputs = [coreutils curl jq];
  text = builtins.readFile ./apply.sh;
}
