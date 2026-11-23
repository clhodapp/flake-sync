#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Scenarios for flake-sync-pin-request, offline. dep.git is an upstream
# flake whose file v the check of app reads: the check builds when v is
# "good" and fails otherwise. app.git is the repository the requests are
# for (test/app), with dep as its input and an allowed-signers file that
# accepts the key of alice for pin requests. Each scenario writes an
# issue title and body, runs `serve` in a checkout of app's main, and
# looks at what reached app.git.
#
# Env: PIN_REQUEST (the flake-sync-pin-request executable).

set -euo pipefail

PR=${PIN_REQUEST:?set PIN_REQUEST to the flake-sync-pin-request executable}
T=${PR_TMP:-/tmp/pr}
mkdir -p "$T"
export GIT_CONFIG_GLOBAL=$T.gitconfig GIT_CONFIG_SYSTEM=/dev/null
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = pin-request-test
	email = test@example.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
EOF

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

set_v() { # commit v=$1 to dep.git main; print the commit
  printf '%s\n' "$1" >"$T/dep-src/v"
  git -C "$T/dep-src" add -A
  git -C "$T/dep-src" commit -q --allow-empty -m "v $1"
  git -C "$T/dep-src" push -q "$T/dep.git" HEAD:refs/heads/main
  git -C "$T/dep-src" rev-parse HEAD
}

git init -q "$T/dep-src"
printf '{ outputs = _: { }; }\n' >"$T/dep-src/flake.nix"
git init -q --bare "$T/dep.git"
set_v good >/dev/null

ssh-keygen -q -t ed25519 -N '' -C alice -f "$T/alice"
ssh-keygen -q -t ed25519 -N '' -C mallory -f "$T/mallory"
ssh-keygen -q -t ed25519 -N '' -C gitonly -f "$T/gitonly"

src=$T/app-src
git init -q "$src"
cd "$src"
cat >flake.nix <<EOF
{
  inputs.dep.url = "git+file://$T/dep.git";
  outputs =
    { dep, ... }:
    {
      checks.x86_64-linux.v = derivation {
        name = "v";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [
          "-c"
          "read v < \${dep}/v; [ \"\$v\" = good ] && echo ok > \$out"
        ];
      };
    };
}
EOF
mkdir -p .github
{
  printf 'alice namespaces="flake-sync-pin-request" %s\n' "$(cut -d' ' -f1,2 "$T/alice.pub")"
  printf 'gitonly namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$T/gitonly.pub")"
} >.github/flake-sync-allowed-signers
git add -A
nix flake lock 2>/dev/null
git add -A
git commit -q -m base
git init -q --bare "$T/app.git"
git push -q "$T/app.git" HEAD:refs/heads/main

srv=$T/srv
git clone -q "$T/app.git" "$srv"

lock_rev() { # print the rev of dep that app.git main locks
  git -C "$T/app.git" show main:flake.lock | jq -r .nodes.dep.locked.rev
}

request() { # write an issue: $1 title, $2 body
  printf '%s' "$1" >"$T/title"
  printf '%s' "$2" >"$T/body"
}

signed_body() { # print the body `sign` makes: $1 key, then sign options and inputs
  local key=$1
  shift
  "$PR" sign --key="$key" "$@" | tail -n +3
}

serve() { # run serve on the request; prints its output, sets RC
  RC=0
  OUT=$(cd "$srv" && GITHUB_OUTPUT=$T/outputs "$PR" serve --repo=test/app --title="$T/title" --body="$T/body" --issue=7 2>&1) || RC=$?
  printf '%s\n' "$OUT"
}

expect() { # $1 description, $2 exit code, $3 text the output contains, $4 dep rev app.git must lock afterwards
  [ "$RC" -eq "$2" ] || fail "$1: expected exit $2, got $RC: $OUT"
  grep -qF -- "$3" <<<"$OUT" || fail "$1: expected '$3' in: $OUT"
  [ "$(lock_rev)" = "$4" ] || fail "$1: app.git locks $(lock_rev), expected $4"
  echo "ok: $1"
}

# --------------------------------------------------------- unsigned requests

D2=$(set_v good)
request "flake-sync update dep" "please"
serve >/dev/null
expect "an unsigned request whose check passes is pushed" 0 "Moved dep in" "$D2"
git -C "$T/app.git" log -1 --format=%B main | grep -qx "Checked-by: nix flake check" || fail "the commit names no check"
git -C "$T/app.git" log -1 --format=%B main | grep -qx "Requested-in: #7" || fail "the commit names no issue"
echo "ok: the commit names the check and the issue"

serve >/dev/null
expect "a request for inputs already at their tips changes nothing" 0 "already at the tips" "$D2"

D3=$(set_v bad)
serve >/dev/null
expect "an unsigned request whose check fails is not pushed" 1 "nix flake check\` fails" "$D2"

# ---------------------------------------------------------- signed requests

request "flake-sync update dep" "$(signed_body "$T/mallory" --repo=test/app dep)"
serve >/dev/null
expect "a request signed by an unknown key runs the check" 1 "does not verify with a key that the allowed-signers file accepts" "$D2"

request "flake-sync update dep" "$(signed_body "$T/gitonly" --repo=test/app dep)"
serve >/dev/null
expect "a request signed by a key allowed only for git runs the check" 1 "does not verify with a key that the allowed-signers file accepts" "$D2"

request "flake-sync update dep" "$(signed_body "$T/alice" --repo=test/other dep)"
serve >/dev/null
expect "a request signed for another repository runs the check" 1 "for another repository or other inputs" "$D2"

request "flake-sync update dep" "$(signed_body "$T/alice" --repo=test/app dep other)"
serve >/dev/null
expect "a request signed for other inputs runs the check" 1 "for another repository or other inputs" "$D2"

# The request text edited after signing: a later expiry.
body=$(signed_body "$T/alice" --repo=test/app dep)
request "flake-sync update dep" "$(sed 's/^expires: .*/expires: 9999999999/' <<<"$body")"
serve >/dev/null
expect "a request edited after signing runs the check" 1 "does not verify with a key that the allowed-signers file accepts" "$D2"

# A signature made with alice's key over an expired request.
past=$(($(date +%s) - 60))
printf 'flake-sync pin request\nrepository: test/app\ninputs: dep\nexpires: %s\n' "$past" >"$T/expired"
sig=$(ssh-keygen -Y sign -n flake-sync-pin-request -f "$T/alice" <"$T/expired" 2>/dev/null)
request "flake-sync update dep" "$(printf '%s\n%s%s\n%s\n' '-----BEGIN FLAKE-SYNC PIN REQUEST-----' "$(cat "$T/expired")" $'\n-----END FLAKE-SYNC PIN REQUEST-----' "$sig")"
serve >/dev/null
expect "an expired signed request runs the check" 1 "the signed request expired" "$D2"

# A signature from the git namespace, by alice, over a valid request.
far=$(($(date +%s) + 3600))
printf 'flake-sync pin request\nrepository: test/app\ninputs: dep\nexpires: %s\n' "$far" >"$T/gitns"
sig=$(ssh-keygen -Y sign -n git -f "$T/alice" <"$T/gitns" 2>/dev/null)
request "flake-sync update dep" "$(printf '%s\n%s%s\n%s\n' '-----BEGIN FLAKE-SYNC PIN REQUEST-----' "$(cat "$T/gitns")" $'\n-----END FLAKE-SYNC PIN REQUEST-----' "$sig")"
serve >/dev/null
expect "a signature made for git commits runs the check" 1 "does not verify with a key that the allowed-signers file accepts" "$D2"

# A request signed by alice, naming the repository in other case, as GitHub ignores case.
request "flake-sync update dep" "$(signed_body "$T/alice" --repo=TEST/App dep)"
serve >/dev/null
expect "a request signed by alice skips the check and is pushed" 0 "Moved dep in" "$D3"
grep -qx "trusted=true" "$T/outputs" || fail "serve did not report the request trusted"
git -C "$T/app.git" log -1 --format=%B main | grep -qx "Checked-by: none, the request is signed by alice" || fail "the commit does not name the signer"
echo "ok: the commit names the signer"

# --------------------------------------------------------- malformed titles

request 'flake-sync update dep; touch /tmp/pr-pwned' "x"
serve >/dev/null
expect "a title with more than input names is refused" 1 "The title is not" "$D3"
[ ! -e /tmp/pr-pwned ] || fail "the title ran"
request "flake-sync update missing" "x"
serve >/dev/null
expect "a request for an input the lock does not have is refused" 1 "locks no input missing" "$D3"
request "flake-sync update" "x"
serve >/dev/null
expect "a request that names no input is refused" 1 "The title is not" "$D3"

# ------------------------------------------------------ a concurrent push

# The first push from srv finds main moved by another commit, made by a
# pre-push hook here; serve starts again from the new tip.
D4=$(set_v good)
cat >"$srv/.git/hooks/pre-push" <<EOF
#!/bin/sh
[ -e $T/raced ] && exit 0
touch $T/raced
other=\$(mktemp -d)
git clone -q $T/app.git "\$other"
echo moved >"\$other/README"
git -C "\$other" add README
git -C "\$other" commit -q -m "docs: readme"
git -C "\$other" push -q origin HEAD:main
EOF
chmod +x "$srv/.git/hooks/pre-push"
request "flake-sync update dep" "please"
serve >/dev/null
expect "a request whose push loses a race is redone on the new tip and pushed" 0 "Moved dep in" "$D4"
grep -qF "the push was refused (attempt 1 of 5)" <<<"$OUT" || fail "the race did not happen: $OUT"
git -C "$T/app.git" show main:README | grep -qx moved || fail "the commit that won the race is lost"
echo "ok: the commit that won the race is kept"

echo "ALL PIN-REQUEST SCENARIOS PASSED"
