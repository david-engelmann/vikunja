#!/bin/bash
set -euo pipefail
cd /repo
[ ! -d ".git" ] && git init && git remote add origin \
  "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" && git checkout -b main
mkdir -p database files
cp /backups/db/*.sql.gz database/ 2>/dev/null || true
ls -t database/*.sql.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
rsync -a --delete /vikunja-files/ files/
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Backup: $(date +%Y-%m-%d_%H-%M-%S)"
  git push -u origin main --force
fi