{
  description = "Cached builds of NousResearch/hermes-agent, for hosts too small to build it themselves";

  inputs = {
    # The ONLY input, deliberately.
    #
    # Which store paths this repo caches is decided entirely by (this rev + the
    # nixpkgs that hermes-agent pins internally). Nothing declared here may
    # influence that, or the paths CI builds stop matching the paths a consumer
    # asks for and the cache hit rate goes to zero — not "degrades", zero, since
    # a derivation hash either matches or it does not.
    #
    # That is why there is no `nixpkgs` input, and why the line below carries no
    # `inputs.nixpkgs.follows`. See "Two rules" in the README.
    #
    # The trailing ref pins a tagged release rather than the default branch.
    # `main` moves far faster than the tags do, so an unpinned URL caches
    # whatever mid-development commit the weekly job happens to land on — a
    # commit upstream never declared shippable. `update.yaml` rewrites this line
    # to the newest tag; flake.lock records the rev that tag resolves to.
    hermes-agent.url = "github:NousResearch/hermes-agent/v2026.8.27";
  };

  # Applies only when THIS flake is the top level, e.g.
  #   nix build github:asktt1770/nix-hermes-agent#messaging
  #
  # `nixConfig` is NOT inherited by flakes that take this one as an input, so a
  # consuming NixOS host has to add the substituter to `nix.settings` itself.
  # The README carries that snippet.
  nixConfig = {
    extra-substituters = [ "https://nix-hermes-agent.cachix.org" ];
    # Cachix-managed signing key. Public by design — it verifies signatures, it
    # does not create them, and pushing needs the separate auth token.
    extra-trusted-public-keys = [
      "nix-hermes-agent.cachix.org-1:D9N+4J9YbUXja5rg6B3d/BbL+ivPkTakLspqkACRhCQ="
    ];
  };

  outputs =
    { hermes-agent, ... }:
    {
      # Re-exported verbatim, not rebuilt or reshaped.
      #
      # Two reasons. It makes this flake a drop-in replacement for
      # `github:NousResearch/hermes-agent` as an input, so a consumer swaps one
      # URL and nothing else. And anything that reshaped these — a system filter,
      # an `override`, a wrapper derivation — would produce *different* store
      # paths from the ones upstream produces, which is the one outcome this repo
      # exists to avoid.
      inherit (hermes-agent)
        packages
        nixosModules
        homeManagerModules
        overlays
        ;
    };
}
