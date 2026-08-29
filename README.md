# nix-hermes-agent

A thin flake that re-exports [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)
unchanged, and exists so that **CI builds it once and a binary cache hands the
result to machines that cannot afford to build it themselves**.

There is no packaging work in here. Upstream already ships the flake, the NixOS
module and the Home Manager module. What upstream does not ship is a binary
cache, so every NixOS user of hermes compiles the whole thing locally. On decent
hardware that is a few minutes and nobody notices. On a low-powered host it is
most of an hour.

## Why a separate public repository

Measured on the host that prompted this (4 cores, 7.7 GB RAM, 5400 rpm HDD), one
`nixos-rebuild switch` after a hermes version bump took **59 minutes** — 1000
derivations, of which about 767 were small npm/PyPI downloads serialised behind
the `--max-jobs 1` that the host needs to stay inside its memory budget.

Doing the build in the *consuming* repository does not work, because that repo is
private, and private repos land on the wrong side of three separate limits:

| | private repo | public repo |
| --- | --- | --- |
| runner | 2 CPU / 8 GB | **4 CPU / 16 GB** |
| Actions minutes | 2,000/month (Free org) | **unlimited, free** |
| Cachix free tier | not eligible | **5 GB, open-source tier** |

Splitting the *upstream* half into a public repo clears all three at once. It
also means nothing private is ever built or published here: this repo compiles
open-source code and nothing else. No host configuration, no secrets, no
identity files.

## Using it

### 1. Point your flake at this repo instead of upstream

```nix
inputs.hermes-agent.url = "github:asktt1770/nix-hermes-agent";
```

The outputs are re-exported verbatim (`packages`, `nixosModules`,
`homeManagerModules`, `overlays`), so this is a drop-in swap — nothing else in a
consuming config changes.

This step is not what makes the cache work; step 2 is. What it buys is that the
pin lives in exactly one place. With the consumer pinning upstream directly and
this repo pinning it separately, the two drift apart the first time either
updates, and a drifted pin means a 0% hit rate with no error message.

### 2. Add the substituter on the consuming host

```nix
nix.settings = {
  substituters = [ "https://nix-hermes-agent.cachix.org" ];
  trusted-public-keys = [ "nix-hermes-agent.cachix.org-1:REPLACE_ME" ];
};
```

This part is not optional and cannot be inherited. This flake declares
`nixConfig`, but Nix applies `nixConfig` only to the flake being evaluated as the
top level — never to one consumed as an input.

Substitution is governed by `max-substitution-jobs` (16 by default) and is
**unaffected by `--max-jobs`**, so a host that must build serially still
downloads in parallel. That is most of where the hour goes.

## Two rules that keep the cache working

A binary cache hits when the consumer asks for a store path byte-identical to
one CI produced. There is no partial credit. Both rules below are ways of not
changing the hash.

### Never add `follows` to the hermes-agent input

```nix
# Correct — upstream builds against the nixpkgs it pins internally
hermes-agent.url = "github:NousResearch/hermes-agent";

# Breaks the cache completely
hermes-agent = {
  url = "github:NousResearch/hermes-agent";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Adding `follows` rebuilds hermes against *your* nixpkgs. Every derivation hash
changes and not one cached path is reachable any more. It reads as tidying up —
every other input in a typical flake has a `follows` — which is exactly why it
needs writing down. This applies to the consumer's flake as much as to this one.

### Cache the variant that is actually consumed

`packages.messaging` and `packages.default` (= `full`) are different derivations.
CI builds `messaging`, because that is what the consumer asks for. If a consumer
switches to `default`, `tui`, `web` or `minimal`, add it to `build.yaml` — until
then it would be 3 GiB of cache nobody pulls.

## Updates

`update.yaml` runs weekly, moves `flake.lock` forward and, in the same run,
rebuilds and pushes. The rebuild is chained rather than triggered by the commit
because pushes made with `GITHUB_TOKEN` do not start other workflows — the cache
would otherwise go stale silently every time the pin moved.

Order matters when taking an update: let this repo build first, then move the
consumer's pin. The reverse asks the consumer for paths nothing has built yet,
which is not an error — the consumer builds them, slowly, exactly as before.

## The hash match is already verified

The whole design rests on one claim: a path built here is byte-identical to the
path the consumer asks for. That was checked against a host already running
hermes, before any CI existed.

```console
$ nix eval --raw '.#packages.x86_64-linux.messaging'
/nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5

$ ssh <host> 'nix path-info -Sh /nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5'
/nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5    3.3 GiB
```

Same path. It works because `hermes-agent` carries its own nixpkgs pin
(`0954f7ee2f6b` at the rev locked here) and this flake adds nothing that could
perturb it — which is the same fact both rules above are protecting.

This check is worth repeating after any change to `flake.nix`, and it costs an
eval rather than a build.

## Setup checklist

Not yet done — the cache does not exist until these are:

- [ ] Create the `nix-hermes-agent` cache at [app.cachix.org](https://app.cachix.org)
- [ ] Add `CACHIX_AUTH_TOKEN` to this repo's Actions secrets (a **write** token)
- [ ] Replace `REPLACE_ME` with the real public key — in `flake.nix` (`nixConfig`)
      and in step 2 above
- [ ] Run `build` once via `workflow_dispatch` and confirm paths land in the cache
- [ ] Switch the consumer's input and add the substituter

Only after a green run is any of this load-bearing. The first run is also the
experiment: a public runner has never built this closure, and the failure modes
worth distinguishing are out-of-memory (drop to `--max-jobs 2`) and out-of-disk
(turn on `large-packages` in the free-disk-space step).

## What is cached

`packages.x86_64-linux.messaging` only. Other systems and variants are exported
by the flake but not built — Cachix's free tier is 5 GB, and the hermes closure
is ~3.3 GiB before compression, so a second target needs checking against the
quota rather than assuming.

## Acknowledgements

The shape of this repo — a thin public flake whose CI builds into a Cachix cache
— was learned from [`ryoppippi/nix-claude-code`](https://github.com/ryoppippi/nix-claude-code),
which does the same job for Claude Code. No code was taken from it; the two
flakes and their workflows have little in common, because the underlying builds
are nothing alike. Claude Code ships an official prebuilt binary, so that flake
repackages a download. hermes-agent ships source, so this one caches a real
40-minute compile. Worth reading if you want the pattern applied to something
that builds quickly.

## Licence

This repo is MIT licensed — see [LICENSE](./LICENSE). That covers the flake and
the workflows, which is all the original work here.

**What the cache distributes is separate and matters more.** Anything pulled from
`nix-hermes-agent.cachix.org` is a *build artefact of*
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent),
which is MIT licensed. Its terms — including the requirement to keep the
copyright and permission notice with copies — govern those binaries, not this
repo's licence. Nothing here relicenses, vendors or modifies upstream code; the
flake references a rev and the CI compiles it unchanged.
