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
