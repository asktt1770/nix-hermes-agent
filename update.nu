#!/usr/bin/env nix
#! nix shell nixpkgs#nushell -c nu

# Pin this flake to upstream's newest tagged release, and say which release
# channels that pin advances.
#
# Run it by hand before trusting a change to it:
#
#     ./update.nu --dry-run    # report what would be pinned, write nothing
#     ./update.nu              # rewrite flake.nix, re-lock, print the outcome
#
# Under Actions the outcome goes to $GITHUB_OUTPUT instead of stdout, and
# update.yaml reads `changed`, `tag`, `level` and `channels` from there.
#
# The shebang above resolves nushell from the flake registry rather than with
# `nix shell --inputs-from .`, which is what nix-claude-code does. It cannot
# work here: this flake deliberately has no `nixpkgs` input (see "Two rules" in
# the README), so there is nothing for `--inputs-from` to hand over. Nothing
# this script runs in ends up in a store path, so an unpinned nushell cannot
# perturb what gets cached.

const REPO = "NousResearch/hermes-agent"
const UPSTREAM = "github:NousResearch/hermes-agent"

# The tag of upstream's newest release.
#
# `releases/latest` rather than a sorted tag list: upstream's tag namespace also
# holds non-release refs (`backup/…`, `premerge-oh-god`) that a version sort has
# no way to tell apart from a release.
def latest-release-tag []: nothing -> string {
    gh api $"repos/($REPO)/releases/latest" --jq .tag_name | str trim
}

# The tag this flake currently pins, or "" before one was ever pinned.
#
# Read from flake.lock rather than by parsing flake.nix. Nix writes this field
# itself, so it needs no regex — and no second pattern to keep in step with the
# one `pin-ref` rewrites with.
def pinned-tag []: nothing -> string {
    open flake.lock | from json | get nodes."hermes-agent".original.ref? | default ""
}

# The semver upstream shipped under a release tag, e.g. "0.21.0".
#
# Read from the release title, not from `pyproject.toml` at that ref. Both carry
# the same number, but the title comes back in the release payload we are
# already fetching, and upstream's scripts/release.py writes it from a format
# string — `f"Hermes Agent v{new_version} ({calver_date})"` — so the shape is
# generated rather than typed. All 31 releases to v2026.8.31 parse.
def version-of [
    tag: string # a release tag, e.g. "v2026.8.31"
]: nothing -> string {
    let title = (gh api $"repos/($REPO)/releases/tags/($tag)" --jq .name | str trim)
    let found = ($title | parse --regex '^Hermes Agent v(?<version>[0-9][0-9.]*)')

    # An unparsable title means upstream changed the format, not that this is a
    # patch. Reported as a patch it would freeze the minor channel and look from
    # the outside exactly like a quiet month upstream.
    if ($found | is-empty) {
        error make {msg: $"could not read a version from the release title for ($tag): ($title)"}
    }

    $found.0.version
}

# Which SemVer component moved between two versions: "major", "minor" or "patch".
#
# The same three words upstream itself bumps with — `scripts/release.py` takes
# `--bump {major,minor,patch}` and increments exactly this way — so a release
# upstream calls a minor is one this repo calls a minor too.
#
# A null `old` means nothing was pinned before. Reported as "patch", the level
# that claims least: there is no earlier version to have moved away from, and
# guessing higher would seed the conservative channels off a release nobody
# established was a milestone.
def bump-level [
    old: any # the previous semver, or null
    new: string # the semver being pinned
]: nothing -> string {
    if $old == null { return "patch" }

    let a = ($old | split row "." | each {|p| $p | into int})
    let b = ($new | split row "." | each {|p| $p | into int})

    if ($a | get 0? | default 0) != ($b | get 0? | default 0) {
        "major"
    } else if ($a | get 1? | default 0) != ($b | get 1? | default 0) {
        "minor"
    } else {
        "patch"
    }
}

# The channels a bump of this level advances.
#
# SemVer nests, so the cascade does too: every release is a patch-level change
# to someone, a minor bump is also a patch bump of the line it opens, and a
# major bump is both. A consumer following `minor` wants each `X.Y.0` including
# the `X.0.0` that opens a new major, which is why "major" lists all three
# rather than only itself.
#
# `major` is absent from this repo until upstream ships 1.0.0, and that is
# deliberate: `promote` creates a channel the first time it advances, so the
# branch appears on its own. A branch created early would instead sit frozen for
# however long `0.x` lasts, and a consumer following it would see no updates and
# no errors — indistinguishable from a quiet upstream. An unresolvable branch
# fails immediately, which is the better of the two.
def channels-for [
    level: string # "major", "minor" or "patch"
]: nothing -> list<string> {
    match $level {
        "major" => ["patch" "minor" "major"]
        "minor" => ["patch" "minor"]
        _ => ["patch"]
    }
}

# Point flake.nix's hermes-agent input at `tag`.
#
# Located by whole line and rewritten by index, rather than by replacing the
# first regex match in the file. Two things go wrong with first-match: a URL
# quoted inside a comment above the attribute would be rewritten in its place,
# and a second assignment appearing anywhere would be silently ignored. Either
# leaves the real pin stale while every guard downstream reports success —
# the silent staleness update.yaml's header is about.
#
# So the count is asserted instead: exactly one line, or the run fails.
def pin-ref [
    tag: string # the release tag to pin
]: nothing -> nothing {
    let source = (open --raw flake.nix)
    let pattern = $'^\s*hermes-agent\.url = "($UPSTREAM)[^"]*";\s*$'
    let hits = ($source | lines | enumerate | where {|entry| $entry.item =~ $pattern})

    if ($hits | length) != 1 {
        error make {msg: $"expected exactly one hermes-agent.url assignment in flake.nix, found ($hits | length)"}
    }

    let indent = ($hits.0.item | parse --regex '^(?<indent>\s*)' | get 0.indent)
    let rewritten = (
        $source
        | lines
        | update $hits.0.index $'($indent)hermes-agent.url = "($UPSTREAM)/($tag)";'
        | str join "\n"
    )

    # `lines` drops the final newline, and putting back something the file did
    # not have would be a diff this script did not mean to make.
    let trailer = (if ($source | str ends-with "\n") { "\n" } else { "" })
    $"($rewritten)($trailer)" | save --force flake.nix
}

# The bytes of the two files a pin lives in, for comparing before against after.
#
# Compared directly rather than through `git diff`, which answers "does this
# differ from HEAD" — the same question only while the working tree starts
# clean. It does under Actions and does not on the second local run, where
# `git diff` would report the first run's still-uncommitted change as this one's.
def pin-state []: nothing -> record<nix: string, lock: string> {
    {nix: (open --raw flake.nix), lock: (open --raw flake.lock)}
}

# Hand results to update.yaml, or to the terminal when run outside Actions.
def emit [
    pairs: record # step outputs, e.g. {changed: true, tag: "v2026.8.31"}
]: nothing -> nothing {
    let lines = ($pairs | items {|key, value| $"($key)=($value)"} | str join "\n")
    let output = ($env.GITHUB_OUTPUT? | default "")

    if ($output | is-empty) {
        print $lines
    } else {
        $"($lines)\n" | save --append $output
    }
}

def main [
    --dry-run # report what would be pinned, without writing or re-locking
]: nothing -> nothing {
    let tag = (latest-release-tag)
    let old_tag = (pinned-tag)

    if $dry_run {
        let old_version = (if ($old_tag | is-empty) { null } else { version-of $old_tag })
        let new_version = (version-of $tag)
        let level = (bump-level $old_version $new_version)
        print $"pinned:   ($old_tag | default '<none>') \(($old_version | default '<none>')\)"
        print $"latest:   ($tag) \(($new_version)\)"
        print $"bump:     ($level)"
        print $"advances: (channels-for $level | str join ', ')"
        return
    }

    let before = (pin-state)
    pin-ref $tag
    nix flake update hermes-agent

    if $before == (pin-state) {
        emit {changed: false}
        print $"($tag) is already pinned"
        return
    }

    let old_version = (if ($old_tag | is-empty) { null } else { version-of $old_tag })
    let new_version = (version-of $tag)
    let level = (bump-level $old_version $new_version)
    let channels = (channels-for $level)

    # `channels` is consumed by update.yaml as a matrix, via fromJSON. Compact
    # rather than pretty, because a newline in a value would close the
    # $GITHUB_OUTPUT entry early and leave the rest read as further outputs.
    emit {changed: true, tag: $tag, level: $level, channels: ($channels | to json --raw)}
    print $"($old_version | default '<none>') -> ($new_version) \(($level)\) advances ($channels | str join ', ')"
}
