{ pkgs, ... }:

{
  # Reproducible toolchain for working on this image repo.
  packages = with pkgs; [
    cosign # generate/manage the image signing keypair
    jq
    gh # GitHub CLI
  ];

  enterShell = ''
    echo "plasma-machine devenv — cosign $(cosign version --json 2>/dev/null | jq -r .gitVersion 2>/dev/null || echo ready)"
  '';
}
