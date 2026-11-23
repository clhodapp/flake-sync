# SPDX-License-Identifier: MIT
#
# Agent skills for working in a flake-sync workspace: the directories of
# skills/, one per skill with a SKILL.md, in the Agent Skills format.
# Each skill carries the flake-sync reference as reference.md, the file
# its SKILL.md points into, so the reference has one source:
# docs/development/flake-sync.md. In the repo, reference.md is a relative
# symlink to that doc; the package copies the doc itself.
{ lib, runCommand }:
let
  skills = [
    "flake-sync-workspaces"
    "flake-sync-pull-requests"
    "flake-sync-converge"
    "flake-sync-new-workspace"
    "flake-sync-worktrees"
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
      cp ${../../../../skills + "/${skill}/SKILL.md"} "$out/${skill}/SKILL.md"
      cp ${../../../../docs/development/flake-sync.md} "$out/${skill}/reference.md"
    '') skills
  )
