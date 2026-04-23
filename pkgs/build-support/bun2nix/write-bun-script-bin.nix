# writeBunScriptBin { name, text }
# Creates a simple bun shebang script at $out/bin/$name.
{ pkgs, bun }:

{ name, text }:

pkgs.writeTextFile {
  inherit name;
  text = ''
    #!${bun}/bin/bun
    ${text}
  '';
  executable = true;
  destination = "/bin/${name}";
}
