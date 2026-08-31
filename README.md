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
  trusted-public-keys = [
    "nix-hermes-agent.cachix.org-1:D9N+4J9YbUXja5rg6B3d/BbL+ivPkTakLspqkACRhCQ="
  ];
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
hermes-agent.url = "github:NousResearch/hermes-agent/v2026.8.27";

# Breaks the cache completely
hermes-agent = {
  url = "github:NousResearch/hermes-agent/v2026.8.27";
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

`update.yaml` runs weekly. It resolves upstream's newest **tagged release**,
rewrites the ref in `flake.nix`, re-locks, and — in the same run — rebuilds and
pushes. The rebuild is chained rather than triggered by the commit because
pushes made with `GITHUB_TOKEN` do not start other workflows; the cache would
otherwise go stale silently every time the pin moved.

### Why a tag and not `main`

The input carries an explicit ref (`…/hermes-agent/v2026.8.27`) rather than
tracking the default branch. Upstream merges to `main` far faster than it tags —
thousands of commits a month against a release every six days or so — so an
unpinned URL caches whichever mid-development commit the Monday 03:00 job lands
on. Nothing is wrong with those commits except that upstream never declared them
shippable, and there is no reason for the cache to be the thing that finds out.

Tracking tags does *not* meaningfully reduce the update rate. Upstream tagged 30
releases in the five and a half months to 2026-08-27 — one every 5.7 days — so
the weekly job usually still has something to take.

Nor is there a "wait for a major version" option, which is the obvious next
question. Upstream has two version numbers and neither offers one: the git tags
are CalVer (`v2026.8.27`, so the major is the year), and `pyproject.toml` is
still on `0.x` (`0.20.6`), where SemVer puts breaking changes in the minor.
Gating on the minor would mean updating every ~9 days, which is the weekly job
with extra steps.

### Order of operations

Let this repo build first, then move the consumer's pin. The reverse asks the
consumer for paths nothing has built yet, which is not an error — the consumer
builds them, slowly, exactly as before.

`build.yaml` is filtered to `flake.nix`, `flake.lock` and its own file. Editing
this README does not spend 21 minutes rebuilding a closure that is already
cached. `workflow_dispatch` and `workflow_call` ignore `paths`, so the chained
build after an update always runs.

## The hash match is already verified

The whole design rests on one claim: a path built here is byte-identical to the
path the consumer asks for. That was checked against a host already running
hermes, before any CI existed. The transcript below is from `0.20.5`, which is
what was pinned at the time; the pin has since moved to `0.20.6`.

```console
$ nix eval --raw '.#packages.x86_64-linux.messaging'
/nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5

$ ssh <host> 'nix path-info -Sh /nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5'
/nix/store/ywxc4dicfbzxj3xmr30yb236vqvfjvdi-hermes-agent-0.20.5    3.3 GiB
```

Same path. It works because `hermes-agent` carries its own nixpkgs pin and this
flake adds nothing that could perturb it — which is the same fact both rules
above are protecting. That pin is still `0954f7ee2f6b` at `v2026.8.27`, so the
move to `0.20.6` changed the hermes rev and nothing underneath it.

Worth repeating after any *structural* change to `flake.nix` — a new input, a
`follows`, anything reshaping `outputs`. Not after the weekly ref bump, which
`update.yaml` makes to that file by design and which is supposed to change the
hash. It costs an eval rather than a build.

## Setup checklist

Not yet done — the cache does not exist until these are:

- [x] Create the `nix-hermes-agent` cache at [app.cachix.org](https://app.cachix.org) — public, Cachix-managed signing
- [x] Record the public signing key, in `flake.nix` (`nixConfig`) and in step 2 above
- [x] Add `CACHIX_AUTH_TOKEN` to this repo's Actions secrets — a **per-cache
      write** token from the cache's own Settings, not a personal token, which
      would carry account-wide access into CI
- [x] Run `build` once and confirm paths land in the cache
- [ ] Switch the consumer's input and add the substituter

The first run was also the experiment, since no public runner had built this
closure before. It succeeded in 21 minutes with `--max-jobs` left at the runner
default, against a host that needs 55 for the same work. Neither failure mode
that was expected turned up, so both remedies are still untried: out-of-memory
would call for `--max-jobs 2`, out-of-disk for `large-packages: true` in the
free-disk-space step.

## What is cached, and what it costs

`packages.x86_64-linux.messaging` only — the one target a consumer asks for.
Other systems and variants stay exported but unbuilt because nothing pulls them,
not because of the quota.

The quota is nowhere near the constraint it looks like. Cachix does not store
anything already served by `cache.nixos.org`, and most of a hermes closure is
exactly that — CPython, glibc, node, the usual base:

| | paths | size |
| --- | --- | --- |
| closure | 551 | 3.29 GiB |
| already on `cache.nixos.org`, skipped | 430 | 2.89 GiB |
| **actually stored here** | **121** | **409.3 MiB** uncompressed |
| the same, compressed 3.74x | | **109.6 MiB** |

So one version costs about 110 MiB of the free 5 GB tier — roughly 45 of them,
comfortably past a year at the weekly update cadence. Ageing them out needs no
policy either: Cachix evicts least-recently-used entries at the limit, and the
only version anyone pulls is whichever one the consumer currently pins.

These are read from this cache's own narinfo after the first push (`NarSize` and
`FileSize` over the closure), not estimated.

## Acknowledgements

The shape of this repo — a thin public flake whose CI builds into a Cachix cache
— was learned from [`ryoppippi/nix-claude-code`](https://github.com/ryoppippi/nix-claude-code),
which does the same job for Claude Code. No code was taken from it; the two
flakes and their workflows have little in common, because the underlying builds
are nothing alike. Claude Code ships an official prebuilt binary, so that flake
repackages a download. hermes-agent ships source, so this one caches a real
21-minute compile. Worth reading if you want the pattern applied to something
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
