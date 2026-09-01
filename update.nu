#!/usr/bin/env nix
#! nix shell nixpkgs#nushell -c nu

# Pin this flake to upstream's newest tagged release, and say whether that
# release is a milestone.
#
# Run it by hand before trusting a change to it:
#
#     ./update.nu --dry-run    # report what would be pinned, write nothing
#     ./update.nu              # rewrite flake.nix, re-lock, print the outcome
#
# Under Actions the outcome goes to $GITHUB_OUTPUT instead of stdout, and
# update.yaml reads `changed`, `tag` and `milestone` from there.
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

# The part of a semver that identifies a milestone: everything but the patch.
#
# Upstream is on `0.x`, where SemVer puts breaking changes in the minor, so
# `0.20.6` and `0.20.5` share an identity while `0.21.0` starts a new one. A
# future `1.0.0` reads as `1.0` and starts one too, which is what you would want.
def milestone-id [
    version: string # a semver, e.g. "0.21.0"
]: nothing -> string {
    $version | split row "." | first 2 | str join "."
}

# Whether moving from one version to another crosses a milestone.
#
# A null `old` means nothing was pinned before, so there is no crossing to
# detect. Treated as "cannot tell" rather than guessed either way.
def is-milestone [
    old: any # the previous semver, or null
    new: string # the semver being pinned
]: nothing -> bool {
    if $old == null { return false }
    (milestone-id $old) != (milestone-id $new)
}

# Point flake.nix's hermes-agent input at `tag`.
#
# The match is anchored on the attribute so a URL mentioned in a comment cannot
# be rewritten instead, and both halves are built from $UPSTREAM so the pattern
# and its replacement cannot drift apart.
def pin-ref [
    tag: string # the release tag to pin
]: nothing -> nothing {
    let rewritten = (
        open --raw flake.nix
        | str replace --regex $'hermes-agent\.url = "($UPSTREAM)[^"]*"'
            $'hermes-agent.url = "($UPSTREAM)/($tag)"'
    )

    # A replace that matched nothing returns the input unchanged and reports no
    # error, so the run would go on to find no diff and report "nothing to
    # update" — the silent staleness update.yaml's header is about.
    if not ($rewritten | str contains $'"($UPSTREAM)/($tag)"') {
        error make {msg: "could not rewrite the hermes-agent ref in flake.nix"}
    }

    $rewritten | save --force flake.nix
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
        print $"pinned:    ($old_tag | default '<none>') \(($old_version | default '<none>')\)"
        print $"latest:    ($tag) \(($new_version)\)"
        print $"milestone: (is-milestone $old_version $new_version)"
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
    let milestone = (is-milestone $old_version $new_version)

    emit {changed: true, tag: $tag, milestone: $milestone}
    print $"($old_version | default '<none>') -> ($new_version) \(milestone=($milestone)\)"
}
