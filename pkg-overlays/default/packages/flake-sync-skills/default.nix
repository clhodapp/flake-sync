# SPDX-License-Identifier: MIT
#
# Agent skills for working in a flake-sync workspace, one directory per
# skill with a SKILL.md, the format Claude Code, Codex and OpenCode read.
# Each skill carries the flake-sync reference as reference.md, the file
# its SKILL.md points into, so the reference has one source:
# docs/development/flake-sync.md.
{ lib, runCommand }:
let
  skills = [
    "flake-sync-workspaces"
    "flake-sync-pull-requests"
    "flake-sync-converge"
  ];
in
runCommand "flake-sync-skills"
  {
    meta = {
      description = "Agent skills for working in a flake-sync workspace";
      license = lib.licenses.mit;
    };
  }
  (
    lib.concatMapStrings (skill: ''
      mkdir -p "$out/${skill}"
      cp ${./${skill}/SKILL.md} "$out/${skill}/SKILL.md"
      cp ${../../../../docs/development/flake-sync.md} "$out/${skill}/reference.md"
    '') skills
  )
