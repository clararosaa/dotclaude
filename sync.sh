#!/bin/bash
# Keeps the published parts of ~/.claude and this checkout in step.
#
#   sync.sh                          pull, reconcile, scan, copy into mirrors, print git status
#   sync.sh --commit <msg> [path...] the same, then commit and push here and in every mirror
#   sync.sh --install                copy the mirrored files into ~/.claude, keeping .bak copies
#   sync.sh --check-message <msg>    hold a commit message to the scan (the commit-msg hook)
#
# Optional files beside this script:
#   sync-mirrors.txt  directories that get a copy of every published file (git-ignored)
#   sync-allow.txt    literals the scan lets through, one per line
#   sync-deny.txt     literals that always fail the scan and commit messages (git-ignored)
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
live="$HOME/.claude"
# What gets published. Add a path here before adding a file under it.
mirrored=(CLAUDE.md settings.json hooks workflows agents skills/pull-requests)
secrets='(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|figd_[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|xox[abprs]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{20}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
emails='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

die() { echo "sync: $*" >&2; exit 1; }
git_c() { git -C "$repo" "$@"; }

files_under() {
  local root="$1" p
  for p in "${mirrored[@]}"; do
    if [ -d "$root/$p" ]; then
      (cd "$root" && find "$p" -type f ! -name '.DS_Store' ! -name '._*' ! -name '*.bak')
    elif [ -f "$root/$p" ]; then
      echo "$p"
    fi
  done
}

# JSON compares by value, so a key order change alone is no change.
same() {
  local a="$1" b="$2" x y
  [ -f "$a" ] || [ -f "$b" ] || return 0
  [ -f "$a" ] && [ -f "$b" ] || return 1
  case "$a" in
    *.json)
      if x="$(jq -S . "$a" 2>/dev/null)" && y="$(jq -S . "$b" 2>/dev/null)"; then
        [ "$x" = "$y" ]
        return
      fi
      ;;
  esac
  cmp -s "$a" "$b"
}

# Writes $1 in the key order of $2, new keys last.
in_order_of() {
  jq --slurpfile ref "$2" '
    def like($r):
      if type == "object" and ($r | type) == "object" then
        . as $o
        | ([$r | keys_unsorted[] | select(. as $k | $o | has($k))]
           + [keys_unsorted[] | select(. as $k | $r | has($k) | not)]) as $ks
        | reduce $ks[] as $k ({}; . + {($k): ($o[$k] | like($r[$k]))})
      else . end;
    like($ref[0])' "$1"
}

literal_list() {
  [ -f "$1" ] && grep -v -e '^[[:space:]]*$' -e '^#' "$1" || true
}

identity_literals() {
  printf '%s\n' "$HOME" "$USER"
  git_c config user.name || true
  git_c config user.email || true
  git config --global user.name || true
  git config --global user.email || true
}

# Prints file:line:match for everything that must not be published; empty means clean.
scan_files() {
  local allow deny ids
  allow="$(mktemp)"; deny="$(mktemp)"; ids="$(mktemp)"
  literal_list "$repo/sync-allow.txt" > "$allow"
  literal_list "$repo/sync-deny.txt" > "$deny"
  identity_literals | grep -v '^[[:space:]]*$' | sort -u > "$ids"
  (
    cd "$repo"
    git ls-files -co --exclude-standard -z | xargs -0 grep -I -n -o -i -F -f "$ids" -- || true
    git ls-files -co --exclude-standard -z | xargs -0 grep -I -n -o -E -e "$emails" -e "$secrets" -- || true
  ) | while IFS= read -r hit; do
    grep -q -x -F -e "${hit#*:*:}" "$allow" || printf '%s\n' "$hit"
  done
  if [ -s "$deny" ]; then
    (cd "$repo" && git ls-files -co --exclude-standard -z | xargs -0 grep -I -n -o -i -F -f "$deny" -- || true)
  fi
  rm -f "$allow" "$deny" "$ids"
}

check_message() {
  local msg="$1" text deny ids hits=""
  text="$(mktemp)"; deny="$(mktemp)"; ids="$(mktemp)"
  grep -v '^#' "$msg" > "$text" || true
  literal_list "$repo/sync-deny.txt" > "$deny"
  identity_literals | grep -v '^[[:space:]]*$' | sort -u > "$ids"
  [ -s "$deny" ] && hits="$hits$(grep -n -o -i -F -f "$deny" "$text" || true)"
  hits="$hits$(grep -n -o -i -F -f "$ids" "$text" || true)"
  hits="$hits$(grep -n -o -E -e "$secrets" "$text" || true)"
  rm -f "$text" "$deny" "$ids"
  if [ -n "$hits" ]; then
    echo "sync: the commit message names something that must not be published:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
}

ensure_msg_hook() {
  local hook="$repo/.git/hooks/commit-msg"
  [ -f "$hook" ] && return 0
  mkdir -p "$(dirname "$hook")"
  printf '#!/bin/sh\nexec "%s/sync.sh" --check-message "$1"\n' "$repo" > "$hook"
  chmod +x "$hook"
}

# The files as they were when ~/.claude and the checkout last agreed.
agreed="$repo/.git/sync-agreed"
save_agreed() {
  local f
  rm -rf "$agreed"
  while IFS= read -r f; do
    mkdir -p "$(dirname "$agreed/$f")"
    cp -p "$repo/$f" "$agreed/$f"
  done < <(files_under "$repo")
}

reconcile() {
  local old f installs=() copies=() conflicts=() base
  old="$(git_c rev-parse -q --verify HEAD || true)"
  if git_c rev-parse -q --verify '@{u}' > /dev/null 2>&1; then
    git_c pull --ff-only --quiet || die "the pull did not fast-forward; sort out the checkout first"
  fi
  base="$(mktemp -d)"
  if [ -d "$agreed" ]; then
    cp -Rp "$agreed/." "$base/"
  elif [ -n "$old" ]; then
    while IFS= read -r f; do
      mkdir -p "$base/$(dirname "$f")"
      git_c show "$old:$f" > "$base/$f"
    done < <(git_c ls-tree -r --name-only "$old" -- "${mirrored[@]}")
  fi

  while IFS= read -r f; do
    same "$live/$f" "$repo/$f" && continue
    if ! same "$live/$f" "$base/$f" && ! same "$repo/$f" "$base/$f"; then
      conflicts+=("$f")
    elif ! same "$repo/$f" "$base/$f"; then
      installs+=("$f")
    else
      copies+=("$f")
    fi
  done < <({ files_under "$live"; files_under "$repo"; files_under "$base"; } | sort -u)
  rm -rf "$base"

  if [ "${#conflicts[@]}" -gt 0 ]; then
    echo "sync: changed both in ~/.claude and in the checkout, merge by hand and run again:" >&2
    printf '  %s\n' "${conflicts[@]}" >&2
    exit 2
  fi
  for f in ${installs[@]+"${installs[@]}"}; do
    if [ -f "$repo/$f" ]; then
      mkdir -p "$(dirname "$live/$f")"
      cp -p "$repo/$f" "$live/$f"
      echo "installed ~/.claude/$f"
    else
      rm -f "$live/$f"
      echo "removed ~/.claude/$f"
    fi
  done
  for f in ${copies[@]+"${copies[@]}"}; do
    if [ ! -f "$live/$f" ]; then
      rm -f "$repo/$f"
      echo "removed $f from the checkout"
    elif [ -f "$repo/$f" ] && [ "${f##*.}" = json ]; then
      in_order_of "$live/$f" "$repo/$f" > "$repo/$f.tmp"
      mv "$repo/$f.tmp" "$repo/$f"
      echo "copied ~/.claude/$f"
    else
      mkdir -p "$(dirname "$repo/$f")"
      cp -p "$live/$f" "$repo/$f"
      echo "copied ~/.claude/$f"
    fi
  done
  save_agreed
}

mirror_dirs=()
copy_into_mirrors() {
  local line dir f
  [ -f "$repo/sync-mirrors.txt" ] || return 0
  while IFS= read -r line; do
    case "$line" in '' | '#'*) continue ;; esac
    dir="${line/#\~/$HOME}"
    if [ ! -d "$dir" ]; then
      echo "sync: mirror $line is not a directory, skipped" >&2
      continue
    fi
    while IFS= read -r f; do
      mkdir -p "$(dirname "$dir/$f")"
      cp -p "$repo/$f" "$dir/$f"
    done < <(git_c ls-files -co --exclude-standard)
    while IFS= read -r f; do
      [ -n "$f" ] && [ ! -e "$repo/$f" ] && [ -f "$dir/$f" ] || continue
      rm "$dir/$f"
      echo "removed $f from $line"
    done < <({ git_c log --diff-filter=D --name-only --format= 2> /dev/null || true
               git_c diff --name-only --diff-filter=D HEAD 2> /dev/null || true; } | sort -u)
    echo "copied into $line"
    mirror_dirs+=("$dir")
  done < "$repo/sync-mirrors.txt"
}

commit_all() {
  local msg="$1" branch sha dir note
  shift
  check_message "$msg" || exit 1
  if [ "$#" -gt 0 ]; then git_c add -A -- "$@"; else git_c add -A; fi
  if git_c diff --cached --quiet; then
    echo "nothing to commit in the checkout"
  else
    git_c commit -q -F "$msg"
  fi
  branch="$(git_c symbolic-ref --short HEAD)"
  if git_c remote get-url origin > /dev/null 2>&1; then
    git_c push -q -u origin "$branch"
    echo "pushed $branch"
  fi
  sha="$(git_c rev-parse --short HEAD)"
  note="$(mktemp)"
  { cat "$msg"; printf '\ndotclaude %s\n' "$sha"; } > "$note"
  for dir in ${mirror_dirs[@]+"${mirror_dirs[@]}"}; do
    git -C "$dir" add -A -- .
    if git -C "$dir" diff --cached --quiet -- .; then
      echo "nothing to commit in $dir"
      continue
    fi
    git -C "$dir" commit -q -F "$note" -- .
    git -C "$dir" push -q
    echo "committed and pushed $dir"
  done
  rm -f "$note"
}

case "${1:-}" in
  --check-message)
    [ -f "${2:-}" ] || die "usage: sync.sh --check-message <file>"
    check_message "$2"
    exit
    ;;
  --install)
    ensure_msg_hook
    while IFS= read -r f; do
      same "$repo/$f" "$live/$f" && continue
      mkdir -p "$(dirname "$live/$f")"
      if [ -f "$live/$f" ]; then
        cp -p "$live/$f" "$live/$f.bak"
        echo "kept ~/.claude/$f.bak"
      fi
      cp -p "$repo/$f" "$live/$f"
      echo "installed ~/.claude/$f"
    done < <(files_under "$repo")
    save_agreed
    exit
    ;;
  --commit)
    [ -f "${2:-}" ] || die "usage: sync.sh --commit <message file> [path...]"
    check_message "$2" || exit 1
    ;;
  '') ;;
  *) die "unknown option $1" ;;
esac

ensure_msg_hook
reconcile
hits="$(scan_files)"
if [ -n "$hits" ]; then
  echo "sync: these would publish something private, fix them or list the literal in sync-allow.txt:" >&2
  printf '%s\n' "$hits" >&2
  git_c status --short
  exit 1
fi
copy_into_mirrors
if [ "${1:-}" = --commit ]; then
  msg="$2"
  shift 2
  commit_all "$msg" "$@"
fi
git_c status --short
