default:
    @just --list

check:
    zig build check

test:
    zig build test --summary failures

format:
    zig fmt build.zig src

run *args:
    zig build run -- {{args}}

install:
    zig build -Doptimize=ReleaseFast --prefix ~/.local

# Re-record goldens: fixtures via POST /markdown (gfm mode renders soft breaks as <br>),
# real READMEs as raw source plus GitHub's README view.
record:
    #!/usr/bin/env bash
    set -euo pipefail
    for md in tests/markdown/*.md; do
        jq -n --rawfile t "$md" '{text: $t, mode: "gfm", context: "github/cmark-gfm"}' \
            | gh api -X POST /markdown --input - > "${md%.md}.github.html"
    done
    mkdir -p tests/readme
    for repo in github/cmark-gfm sindresorhus/github-markdown-css; do
        name="${repo#*/}"
        gh api -H 'Accept: application/vnd.github.raw' "/repos/$repo/readme" > "tests/readme/$name.md"
        gh api -H 'Accept: application/vnd.github.html' "/repos/$repo/readme" > "tests/readme/$name.github.html"
    done
