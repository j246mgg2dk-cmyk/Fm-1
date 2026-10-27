#!/bin/sh
# CI (this fork): the release package of version $1 onto the branch builds/<branch> ($GH_TOKEN), one commit, forced
set -e
v="$1"
d=$(mktemp -d)
ls -la "build/release-$v"
cp "build/release-$v"/* "$d/"
cd "$d"
git init -q
git checkout -q -b main
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -A
git commit -qm "firmware $v from $(echo "$GITHUB_SHA" | cut -c1-7) ($GITHUB_REF_NAME)"
echo "pushing to builds/$GITHUB_REF_NAME"
git push -f "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git" "HEAD:refs/heads/builds/$GITHUB_REF_NAME"
