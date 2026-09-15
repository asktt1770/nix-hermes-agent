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

Pick a channel. They are branches of this repo, named for the SemVer component
upstream has to bump before they move:

```nix
# Every release — one every ~6 days
inputs.hermes-agent.url = "github:asktt1770/nix-hermes-agent/patch";

# Every X.Y.0 — one every ~13 days lately, and lengthening
inputs.hermes-agent.url = "github:asktt1770/nix-hermes-agent/minor";

# Every X.0.0 — does not exist yet; see below
inputs.hermes-agent.url = "github:asktt1770/nix-hermes-agent/major";
```

`main` is the default branch and carries the same commits as `patch`, so the
URL with no branch at all is the same subscription written shorter:

```nix
inputs.hermes-agent.url = "github:asktt1770/nix-hermes-agent";
```

**`major` does not exist yet.** Upstream has never left `0.x`, so there has
never been a major bump to create it; CI makes the branch the first time one
happens. Until then that URL fails to resolve, which is deliberate — a branch
created early would sit frozen for however long `0.x` lasts, and a consumer
following it would see no updates and no errors, which reads exactly like a
quiet upstream. `nix` reporting `unable to download … /commits/major` on the
spot is the better of the two.

Every channel is built and pushed to the same cache, so none is faster to
install; the conservative ones trade freshness for fewer rebuild-and-switch
cycles on the consuming host. The choice is made once — `nix flake update`
follows whichever branch the URL names from then on, with nothing to bump by
hand. Switching later is the same one-word edit, and lands on paths the cache
already holds.

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

`packages.messaging` and `packages.default` (= `full`) are siblings, not nested:
both are `minimal.override { extraDependencyGroups = …; }`, differing only in
which groups. So neither contains the other's store path, and a cache holding
one scores nothing for a consumer asking for the other — even though `full`'s
groups are a strict superset and it therefore does everything `messaging` does.

Everything under them *is* shared. The two build closures have 5412 derivations
in common. `default` adds 198 on top — 98 wheels, their 98 unpacked forms, a
venv and a wrapper — and `messaging` keeps two of its own, its venv and its
wrapper. Even hermes' own 67 MiB build lands on the same path in both, because
the dependency set is injected by the wrapper rather than baked into the
compile. CI builds both, and the second one costs those 198 rather than a
second closure.

Which also means a cache holding `default` is two cheap derivations away from
serving `messaging`, and vice versa. "Scores nothing" is the literal answer for
one store path, not the practical cost of guessing wrong.

`default` earns its 198 by being what upstream's NixOS and Home Manager modules
resolve to when `services.hermes-agent.package` is left alone. A consumer who
drops the explicit `.messaging` lands on a path no cache has, and finds out by
waiting an hour.

`tui` and `web` need no entry in `build.yaml`: they are npm builds that do not
depend on the Python dependency set, so `messaging` already produces their exact
paths and the cache already serves them. `minimal`, `desktop` and `sandbox` are
not cached. Add one when something actually pulls it.

## Updates

`update.yaml` runs daily. It resolves upstream's newest **tagged release**,
rewrites the ref in `flake.nix`, re-locks, and — in the same run — rebuilds and
pushes. The rebuild is chained rather than triggered by the commit because
pushes made with `GITHUB_TOKEN` do not start other workflows; the cache would
otherwise go stale silently every time the pin moved.

The deciding is done by [`update.nu`](./update.nu), not by shell inside the
workflow, so it can be read and run on its own:

```console
$ ./update.nu --dry-run
pinned:   v2026.8.27 (0.20.6)
latest:   v2026.8.31 (0.21.0)
bump:     minor
advances: patch, minor
```

The shebang pulls nushell from the flake registry rather than with
`nix shell --inputs-from .`, because this flake has no `nixpkgs` input to hand
over. Nothing the script runs in reaches a store path, so leaving it unpinned
cannot perturb what gets cached.

### Why a tag and not `main`

The input carries an explicit ref (`…/hermes-agent/v2026.8.27`) rather than
tracking the default branch. Upstream merges to `main` far faster than it tags —
thousands of commits a month against a release every six days or so — so an
unpinned URL caches whichever mid-development commit the daily job lands on.
Nothing is wrong with those commits except that upstream never declared them
shippable, and there is no reason for the cache to be the thing that finds out.

Tracking tags does *not* meaningfully reduce the update rate. Upstream tagged 32
releases in the six months to 2026-09-07 — one every 5.8 days — so `patch` moves
about as often as an unpinned URL would.

Note that "wait for a major version" is not a way to wait a long time here. The
git tags are CalVer (`v2026.8.27`, so the major is the year), and
`pyproject.toml` is on `0.x` (`0.21.1`), where the major has never moved at all.
The `major` channel is real, but it is empty until upstream ships 1.0.0.

### The channels

The three channels are the three SemVer components, and they mean what upstream
means by them — `scripts/release.py` takes `--bump {major,minor,patch}` and
increments exactly the way the spec says.

| upstream bumps | `patch` | `minor` | `major` |
| --- | --- | --- | --- |
| patch | moves | — | — |
| minor | moves | moves | — |
| major | moves | moves | moves |

The cascade is not decoration. A `1.0.0` is the `X.Y.0` opening a new major, so
a consumer following `minor` should get it; SemVer nests and so do the channels.

Nothing else separates them. Every channel points at a commit `main` already
passed through, so promoting one is a fast-forward, and it costs no build — the
closure went to Cachix when `main` took the same commit, and the cache is keyed
by store path rather than by branch. Measured at **4 seconds**.

Deciding which channels move needs the semver, and the CalVer tag has none —
`v2026.8.31` is a date. The semver is in the release *title*, which upstream's
`scripts/release.py` writes from a format string:

```python
"--title", f"Hermes Agent v{new_version} ({calver_date})",
```

So `update.nu` reads `.name` off the release, compares each component against
the previously pinned version, and reports the highest one that moved. All 32
releases to `v2026.9.7` parse.

The *nickname* some titles carry is not the signal and cannot be: `0.15.1`
shipped as "The Patch Release" while `0.20.0`, `0.17.0` and `0.14.0` — all
genuine minor bumps — shipped with none. Only the generated part is load-bearing.

If a title fails to parse the run fails, rather than reporting "patch". A
changed format upstream and a quiet month upstream are indistinguishable from
the outside, and only one of them should freeze the conservative channel.

`promote` waits for `build` to go green. `main` does not, by design: it is the
channel that finds out. No channel should ever point a consumer at a pin whose
closure failed to compile.

Cadence, measured over all 32 upstream releases from `0.2.0` to `0.21.1`
(2026-03-12 to 2026-09-07):

| | interval |
| --- | --- |
| `patch` | 5.8 days |
| `minor`, whole span | 8.5 days |
| `minor`, last six | **13.4 days** |
| `major` | never yet |

The `minor` gap has widened steadily: 5 days between the March milestones, then
14, then `0.21.0` landing 28 days after `0.20.0`. The conservative channels are
worth more now than their lifetime averages suggest.

### Why daily

`update.nu` pins whatever `releases/latest` reports, so a release superseded
before the next run is never pinned and never built. When the skipped one is an
`X.Y.0`, `minor` loses that milestone and waits for the next.

Measured against all 32 releases, the expected number of the 20 `X.Y.0`
releases missed:

| poll interval | milestones missed |
| --- | --- |
| weekly | 4.0 of 20 |
| twice weekly | 1.5 of 20 |
| **daily** | **0.7 of 20** |

Daily does not reach zero — `0.15.1` followed `0.15.0` by 7h24m — but a fifth
of milestones lost is a different thing from a thirtieth, and closing the last
3% would mean polling hourly or teaching `update.nu` to walk the releases it
skipped. Neither is worth it.

It costs no extra builds: how many builds happen is set by how often upstream
releases, not by how often this looks. A run with nothing to do is the `update`
job alone, 47s, on a public repo with unlimited free minutes.

### Order of operations

Let this repo build first, then move the consumer's pin. The reverse asks the
consumer for paths nothing has built yet, which is not an error — the consumer
builds them, slowly, exactly as before.

`build.yaml` is filtered to `flake.nix`, `flake.lock` and its own file, so
editing this README starts no run. That saves less than it sounds like — a
no-op rebuild is 1m48s, not the 21 minutes the first one took — and the real
gain is that the run history stays a record of closure changes.
`workflow_dispatch` and `workflow_call` ignore `paths`, so the chained build
after an update always runs.

That filter leaves the workflow files themselves unread — and `update.yaml`,
having no `pull_request` trigger, is unread by its own workflow too. `lint.yaml`
covers the gap: it runs `actionlint` over `.github/workflows/**` whenever one of
those files changes. It is worth having because a workflow GitHub cannot parse
produces no run and no failure, and nothing else would report it.

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
`follows`, anything reshaping `outputs`. Not after the daily ref bump, which
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
- [x] Seed the channel branches. `promote` creates one the first time it
      advances it, so `minor` appeared on its own with `0.21.1` on 2026-09-09.
      `patch` was pushed from `main` by hand at `0.21.1` rather than waiting:
      it is the channel this README leads with, and leaving it to the next
      release would have left that URL unresolvable for up to a week. `major`
      is *not* seeded — see "The channels" for why an absent branch is the
      wanted behaviour there and a missing one is not
- [ ] Switch the consumer's input and add the substituter

The first run was also the experiment, since no public runner had built this
closure before. It succeeded in 21 minutes with `--max-jobs` left at the runner
default, against a host that needs 55 for the same work. Neither failure mode
that was expected turned up, so both remedies are still untried: out-of-memory
would call for `--max-jobs 2`, out-of-disk for `large-packages: true` in the
free-disk-space step.

### Where the time actually goes

That 21 minutes is a cold-cache number and does not describe an update. Four
runs, measured:

| run | total | `nix build` | derivations built |
| --- | --- | --- | --- |
| first ever, `0.20.5`, empty cache | 21m01s | 4m41s | 1038 |
| bump to `0.20.6`, cache warm | 3m10s | 2m16s | **12** |
| same closure again, nothing to do | 1m48s | 46s | 0 |
| adding `default`, `messaging` warm | 3m22s | 53s + 1m26s | 193 |

Two things follow. The compile was never the expensive part of the first run —
**14m21s of the 21 went to uploading** 682 MiB to Cachix, which happens once.
And a version bump rebuilds a dozen derivations, not a thousand, because the
hundreds of npm and PyPI fetches a hermes closure needs carry over unchanged
between adjacent releases.

The `nix build` column understates the upload, because `cachix-action` runs
`cachix watch-store` alongside the build and the post step only drains what is
left. The first run drained for 14m21s after a 4m41s build; the run that added
`default` drained in 3s after 1m26s. Per byte that is 682 MiB across roughly 19
minutes against 319.4 MiB across roughly 90 seconds — the first push was six
times slower and it is not established why. Budget from the measurement, not
from a rate.

Once cached, `default` costs 11s and 169 MiB of extra download on a run with
nothing to build — it substitutes 101 paths the `messaging` step did not need.
Run totals swing by minutes either way on the `free-disk-space` step, which is
where a no-op run actually spends its time.

So the daily cadence is close to free, and it is self-reinforcing: the longer
the gap between updates, the more of the closure has moved and the closer the
run gets to the cold-cache case.

## What is cached, and what it costs

`packages.x86_64-linux.messaging` and `packages.x86_64-linux.default`. Other
systems stay exported but unbuilt because nothing pulls them, not because of the
quota.

Two different sizes get called "the cache", and the gap between them is about
sixfold. The first is what a consumer downloads — the runtime closure of
`messaging`, most of which Cachix never stores because `cache.nixos.org` already
serves it:

| | paths | size |
| --- | --- | --- |
| closure | 551 | 3.29 GiB |
| already on `cache.nixos.org`, skipped | 430 | 2.89 GiB |
| **stored here** | **121** | **409.3 MiB** uncompressed |
| the same, compressed 3.74x | | **109.6 MiB** |

The second is what the cache actually holds, which is larger. `cachix-action`
records the store before the build and pushes everything that appeared by the
end of the job — so the wheels, npm tarballs and sources the build consumed are
in there too, not only what the output references:

| push | new paths | stored |
| --- | --- | --- |
| first ever, `0.20.5` | 1053 | **682 MiB** |
| `0.20.6` | 18 | 39.2 MiB |
| `0.21.0`, from a branch dispatch | 11 | 38.4 MiB |
| `0.21.1` | 21 | 64.6 MiB |
| first `default`, `0.21.1` | 193 | **319.4 MiB** |
| **total** | | **≈ 1.1 GiB** of 5 GB |

So a version bump costs 40–65 MiB rather than the near-nothing the derivation
count suggests: it rebuilds a dozen derivations, but one of them is hermes
itself at 25.9 MiB stored. The path count collapses between versions because
the npm and PyPI fetches carry over unchanged; the byte count does not collapse
with it.

`default` cost a one-off 319.4 MiB across 193 paths. It brings 98 packages
`messaging` does not have, of which `voice` — faster-whisper and its
ctranslate2 / onnxruntime / av / numpy stack — is about three quarters of the
weight, and both the wheel and its unpacked form get stored. For a consumer who
actually switches to it, the closure to download goes from 3.29 GiB to 3.91 GiB.

That still leaves over 3.5 GiB, or 40-odd more versions. Expect each to cost
more than the 40–65 MiB above, since the dependency surface is now nearly twice
as wide and more of it moves per release; how much more is not yet measured.
Ageing them out needs no policy: Cachix evicts least-recently-used entries at
the limit, and the only version anyone pulls is whichever one the consumer
currently pins.

Every figure here is read from this cache's own narinfo (`NarSize` and
`FileSize`), not estimated — the per-push rows by summing the paths each run
logged as pushed, deduplicated against the earlier runs in the order listed.

## Acknowledgements

The shape of this repo — a thin public flake whose CI builds into a Cachix cache
— was learned from [`ryoppippi/nix-claude-code`](https://github.com/ryoppippi/nix-claude-code),
which does the same job for Claude Code. No code was taken from it; the two
flakes and their workflows have little in common, because the underlying builds
are nothing alike. Claude Code ships an official prebuilt binary, so that flake
repackages a download. hermes-agent ships source, so this one caches a real
compile — 1038 derivations and 682 MiB of cache on the first run. Worth reading
if you want the pattern applied to something that builds quickly.

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
