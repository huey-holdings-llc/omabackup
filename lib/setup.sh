#!/usr/bin/env bash
# First-run wizard, doctor and uninstaller. Every prompt has a flag; --yes
# takes defaults; each step records its own phase in config so a rerun
# resumes rather than repeating finished work. Sourced by bin/omabackup;
# never executed.
# shellcheck shell=bash

cmd_setup() {
  local sub=${1:-}
  case "$sub" in
    check) shift; setup_check "$@"; return ;;
    --remove) shift; setup_remove "$@"; return ;;
  esac
  local data="" remote="" create=0 import="" trust=0 notimers=0 yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data-repo) [[ $# -ge 2 ]] || usage_die "setup: --data-repo needs a value"; data=$2; shift 2 ;;
      --remote) [[ $# -ge 2 ]] || usage_die "setup: --remote needs a value"; remote=$2; shift 2 ;;
      --create-private) create=1; shift ;;
      --import) [[ $# -ge 2 ]] || usage_die "setup: --import needs a value"; import=$2; shift 2 ;;
      --trust-remote) trust=1; shift ;;
      --no-timers) notimers=1; shift ;;
      --yes) yes=1; shift ;;
      *) usage_die "setup: unknown flag $1" ;;
    esac
  done
  [[ -n "$import" && -n "$data" ]] && usage_die "setup: --import and --data-repo are exclusive"

  # Read the phase a PRIOR run reached, and the data repo it chose, before
  # anything below touches config: a rerun can then skip setup_first_scan
  # instead of repeating it, and a FLAGLESS rerun defaults to the repo that
  # is already configured. Without the second read, `setup --yes` (which is
  # what the widget's setup card runs) pointed the config at the hardcoded
  # default, orphaned a repo the user had put anywhere else, and then wrote
  # the new, remote-less repo's origin over remote.url. An unparsable
  # existing config counts as "no prior anything": config_load below will
  # refuse it properly once it is actually loaded.
  local prior_phase="" prior_repo=""
  if config_exists; then
    prior_phase=$(jq -r '.setupPhase // ""' "$CONFIG_FILE" 2>/dev/null) || prior_phase=""
    prior_repo=$(jq -r '.dataRepo // ""' "$CONFIG_FILE" 2>/dev/null) || prior_repo=""
  fi

  setup_tools
  if [[ -n "$import" ]]; then
    setup_import "$import"
  else
    setup_data_repo "${data:-${prior_repo:-$HOME/.local/share/omabackup/data}}" "$yes"
    setup_seed
  fi
  config_load
  setup_phase_at_least "$prior_phase" scanned || setup_first_scan
  setup_remote "$remote" "$create" "$trust" "$yes"
  # The units exec %h/.local/bin/omabackup: the symlink must exist before a
  # timer can fire, so link before enabling anything that would run it.
  setup_cli_link
  [[ $notimers == 1 ]] || setup_units
  setup_shell_nag "$yes"
  # Whether the first snapshot ran is NOT decided by phase rank: a
  # --no-timers run still stamps every phase including "done" (so a rerun
  # is idempotent), which would otherwise make a later, timers-on rerun
  # see "done" >= "snapshot" and skip the first snapshot forever. The real
  # question is whether one has ever actually completed on this data repo,
  # and manifests/.last-run (written by the snapshot pipeline itself) is
  # the one thing that answers that.
  [[ $notimers == 1 ]] || [[ -f "$DATA_REPO/manifests/.last-run" ]] || setup_first_snapshot
  setup_phase "done"
  if [[ $JSON == 1 ]]; then
    jq -cn --arg r "$DATA_REPO" '{ok:true, dataRepo:$r}'
  else
    log "Setup complete. Open the bar widget to triage the first scan."
  fi
}

# setup_phase PHASE: stamp progress in config so a rerun resumes instead of
# repeating finished steps.
setup_phase() { config_write "$(jq --arg p "$1" '.setupPhase=$p' "$CONFIG_FILE")"; }

# setup_phase_rank PHASE: this phase's position in the resume order. seeded
# and imported rank the same (either means the repo layout step is done); an
# empty or unknown phase ranks below everything, so a fresh install always
# runs every step.
setup_phase_rank() {
  case "$1" in
    seeded|imported) echo 1 ;;
    scanned)         echo 2 ;;
    remote)          echo 3 ;;
    units)           echo 4 ;;
    link)            echo 5 ;;
    nag)             echo 6 ;;
    snapshot)        echo 7 ;;
    done)            echo 8 ;;
    *)               echo 0 ;;
  esac
}
# setup_phase_at_least PRIOR TARGET: has a prior run already reached TARGET?
setup_phase_at_least() { [[ $(setup_phase_rank "$1") -ge $(setup_phase_rank "$2") ]]; }

# ask PROMPT DEFAULT YES: gum input, unless --yes was given or stdin is not a
# tty (a systemd unit, a script, this test suite), in which case DEFAULT wins.
ask() {
  local prompt=$1 default=$2 yes=$3
  if [[ $yes == 1 || ! -t 0 ]] || ! have gum; then printf '%s' "$default"; return; fi
  gum input --header "$prompt" --value "$default"
}
# confirm PROMPT YES: a yes/no gate. Only an explicit YES=1 auto-confirms;
# with no tty (a systemd unit, a script, this test suite) or no gum, the
# safe answer is no, since this gates things like trusting a remote enough
# to push to it. Only gum, interactively, can actually decline for a human.
confirm() {
  local prompt=$1 yes=$2
  [[ $yes == 1 ]] && return 0
  [[ -t 0 ]] || return 1
  have gum || return 1
  gum confirm "$prompt"
}

setup_tools() {
  local -a missing=()
  local t
  for t in git rsync jq flock; do have "$t" || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] || die "missing tools: ${missing[*]} (all ship with Omarchy, install with pacman)"
  gitleaks_available || warn "gitleaks is not installed: snapshots will commit locally and never push until it is (pacman -S gitleaks)"
}

# setup_data_repo DIR YES: create (or reuse) the data repo directory, git-init
# it if needed, and write a fresh config that points at it.
setup_data_repo() {
  local dir=$1 yes=$2
  dir=$(ask "Where should the data repo live?" "$dir" "$yes")
  dir=${dir/#\~/$HOME}
  # shellcheck disable=SC2174  # -m only needs to land on the leaf dir; parents keep the default umask
  mkdir -m 700 -p "$dir"
  # Store an ABSOLUTE path. A relative --data-repo (or a relative answer to
  # the gum prompt) resolved against whatever directory setup happened to run
  # in, so the timer, which runs from /, then looked for the repo somewhere
  # else entirely. config_load refuses a relative dataRepo outright; this is
  # the write side of the same rule.
  dir=$(cd "$dir" && pwd -P) || die "could not resolve the data repo path: $1"
  [[ -d "$dir/.git" ]] || git -C "$dir" init -q -b main
  # `mkdir -m 700 -p` above leaves an EXISTING directory's mode alone, so a
  # setup pointed at a directory that was already there kept whatever mode it
  # had. .git holds every backed-up config in full history and never
  # self-heals the way the rsynced trees do.
  chmod 700 "$dir" || warn "could not chmod 700 $dir"
  [[ ! -d "$dir/.git" ]] || chmod 700 "$dir/.git" || warn "could not chmod 700 $dir/.git"
  # A rerun MERGES into whatever config already exists (remote.trusted,
  # shellNag, timer.* and setupPhase must all survive); only a first-ever
  # setup starts clean from CONFIG_DEFAULTS.
  if config_exists; then
    config_write "$(jq -c --argjson d "$CONFIG_DEFAULTS" --arg r "$dir" '$d * . + {dataRepo:$r}' "$CONFIG_FILE")"
  else
    config_write "$(jq -cn --arg r "$dir" --argjson d "$CONFIG_DEFAULTS" '$d + {dataRepo:$r}')"
  fi
  # shellcheck disable=SC2034  # CFG_JSON: read by cfg() (lib/config.sh), not this file
  CFG_JSON=$(cat "$CONFIG_FILE")
  DATA_REPO=$dir
  # shellcheck disable=SC2034  # STAGE: read by later libs (lib/config.sh), not this file
  STAGE="$dir/.staging"
}

# setup_seed: lay down the seed lists, the tree layout and the marker, then
# commit that layout as the repo's first commit.
setup_seed() {
  local f
  # `laid` collects exactly what THIS run wrote, so the commit below can stage
  # it by name. `git add -A` swept the whole data repo instead, which after
  # the flagless-rerun fix means a real repo with real work in it: an
  # in-progress edit to allowlist.txt would have been committed as "omabackup:
  # initial layout" by a wizard rerun the user ran for some other reason. The
  # mutation rule says this tool commits only its own output; this is setup's
  # half of it.
  local -a laid=()
  for f in allowlist drift-ignore etc-allowlist normalize; do
    if [[ ! -f "$DATA_REPO/$f.txt" ]]; then
      cp "$PLUGIN_DIR/share/$f.example" "$DATA_REPO/$f.txt"; laid+=("$f.txt")
    fi
  done
  [[ -f "$DATA_REPO/.gitignore" ]] \
    || { cp "$PLUGIN_DIR/share/data.gitignore" "$DATA_REPO/.gitignore"; laid+=(.gitignore); }
  [[ -f "$DATA_REPO/.gitleaks.toml" ]] \
    || { cp "$PLUGIN_DIR/share/gitleaks.toml" "$DATA_REPO/.gitleaks.toml"; laid+=(.gitleaks.toml); }
  [[ -f "$DATA_REPO/modes.txt" ]] || { : > "$DATA_REPO/modes.txt"; laid+=(modes.txt); }
  mkdir -p "$DATA_REPO/home" "$DATA_REPO/etc" "$DATA_REPO/manifests"
  chmod 700 "$DATA_REPO/home"
  # home/, etc/ and manifests/ are empty here and git does not track empty
  # directories, so they need no entry: the snapshot stages them by name once
  # they hold something.
  setup_marker
  laid+=(.omabackup)      # setup_marker rewrites it on every run, and it is ours
  # Plus any seed file git has never seen. Pointing setup at a directory that
  # already held the lists but had never committed them is legitimate (spec
  # section 6's "point at an existing empty repo"), and untracked means there
  # is no human edit to a tracked file to sweep up.
  local s
  for s in allowlist.txt drift-ignore.txt etc-allowlist.txt normalize.txt modes.txt .gitignore .gitleaks.toml; do
    case " ${laid[*]} " in *" $s "*) continue ;; esac
    git -C "$DATA_REPO" ls-files --error-unmatch -- "$s" >/dev/null 2>&1 || laid+=("$s")
  done
  git -C "$DATA_REPO" add -- "${laid[@]}" >/dev/null
  # `git commit -q` does not suppress "nothing to commit, working tree
  # clean" on stdout when a rerun has nothing new to lay down; that line
  # must never leak into a --json caller's single JSON object.
  git_ident_args
  git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit -qm "omabackup: initial layout" >/dev/null 2>&1 || true
  setup_phase "seeded"
}

setup_marker() { jq -cn --arg v "$VERSION" '{format:1, createdBy:$v}' > "$DATA_REPO/.omabackup"; }

# setup_import DIR: adopt an existing engine repo, one that already carries
# the lists and tree layout but is missing our marker or a config entry.
setup_import() {
  local dir=${1/#\~/$HOME}
  [[ -d "$dir/.git" ]] || die "$dir is not a git repository"
  # Spec section 6: the five list files and the three trees. modes.txt and
  # etc/ were missing from this check, so a repo without them was adopted and
  # then failed later, in the snapshot, with a much worse message.
  local f
  for f in allowlist.txt drift-ignore.txt etc-allowlist.txt normalize.txt modes.txt; do
    [[ -f "$dir/$f" ]] || die "$dir has no $f, not an engine repo"
  done
  local d
  for d in home etc manifests; do
    [[ -d "$dir/$d" ]] || die "$dir has no $d/"
  done
  # Absolute, for the same reason setup_data_repo resolves its own directory.
  dir=$(cd "$dir" && pwd -P) || die "could not resolve the data repo path: $1"
  # An imported repo was cloned by someone else, under whatever umask they
  # had. This path chmod'd nothing at all, so all of .git stayed readable.
  chmod 700 "$dir" || warn "could not chmod 700 $dir"
  [[ ! -d "$dir/.git" ]] || chmod 700 "$dir/.git" || warn "could not chmod 700 $dir/.git"
  if config_exists; then
    config_write "$(jq -c --argjson d "$CONFIG_DEFAULTS" --arg r "$dir" '$d * . + {dataRepo:$r}' "$CONFIG_FILE")"
  else
    config_write "$(jq -cn --arg r "$dir" --argjson d "$CONFIG_DEFAULTS" '$d + {dataRepo:$r}')"
  fi
  # shellcheck disable=SC2034  # CFG_JSON: read by cfg() (lib/config.sh), not this file
  CFG_JSON=$(cat "$CONFIG_FILE")
  DATA_REPO=$dir
  # shellcheck disable=SC2034  # STAGE: read by later libs (lib/config.sh), not this file
  STAGE="$dir/.staging"
  # `adopted` collects exactly what THIS run wrote, so the commit below can
  # stage it by name, the same half of the mutation rule setup_seed keeps.
  local -a adopted=()
  [[ -f "$DATA_REPO/.gitignore" ]] \
    || { cp "$PLUGIN_DIR/share/data.gitignore" "$DATA_REPO/.gitignore"; adopted+=(.gitignore); }
  [[ -f "$DATA_REPO/.gitleaks.toml" ]] \
    || { cp "$PLUGIN_DIR/share/gitleaks.toml" "$DATA_REPO/.gitleaks.toml"; adopted+=(.gitleaks.toml); }
  setup_marker
  adopted+=(.omabackup)
  # Commit the marker. Nothing else ever does: the snapshot commits its four
  # output paths and push --confirm the five lists, so an uncommitted
  # .omabackup meant a clone of the adopted repo carried no marker at all and
  # every verb refused it there. `|| true` for the same reason as setup_seed:
  # a rerun with nothing new to write must be a silent no-op, not a failure.
  git -C "$DATA_REPO" add -- "${adopted[@]}" >/dev/null || die "could not stage the adoption marker"
  git_ident_args
  git -C "$DATA_REPO" ${GIT_IDENT_ARGS[@]+"${GIT_IDENT_ARGS[@]}"} commit -qm "omabackup: adopt existing repo" >/dev/null 2>&1 || true
  setup_phase "imported"
}

setup_first_scan() {
  local rep; rep=$(JSON=1 cmd_drift 2>/dev/null || true)
  local n; n=$(jq -r '.items|length' <<<"$rep" 2>/dev/null || echo "?")
  log "First scan: $n path(s) need a decision. Triage them from the bar widget."
  setup_phase "scanned"
}

# setup_remote URL CREATE TRUST YES: wire (or skip) a git remote, and decide
# whether a non-GitHub remote is trusted enough to push to.
setup_remote() {
  local url=$1 create=$2 trust=$3 yes=$4 have_origin
  # What the config already decided, read BEFORE anything below changes the
  # origin. A trust decision belongs to one specific remote, and a rerun
  # against that same remote must not silently drop it: `setup --yes` used to
  # rewrite the whole remote object from argv, so every rerun (including the
  # one the widget's setup card runs) untrusted a remote the operator had
  # deliberately trusted, and pushes stopped until they noticed.
  local prior_url prior_trusted
  prior_url=$(cfg remote.url)
  prior_trusted=$(cfg remote.trusted)
  have_origin=$(remote_origin_url)
  if [[ -z "$url" && -z "$have_origin" && $create == 0 && $yes == 0 ]]; then
    url=$(ask "Private git remote URL (empty to stay local)" "" 0)
  fi
  if [[ $create == 1 ]]; then
    have gh || die "--create-private needs gh (pacman -S github-cli)"
    gh auth status >/dev/null 2>&1 || die "gh is not signed in, run gh auth login"
    local name; name=$(ask "GitHub repo name" "omabackup-data" "$yes")
    gh repo create "$name" --private --confirm >/dev/null 2>&1 || gh repo create "$name" --private >/dev/null
    url=$(gh repo view "$name" --json sshUrl -q .sshUrl)
  fi
  # Trust is the escape hatch for a remote OmaBackup cannot check. A GitHub
  # remote it can check, so trusting one only ever means "skip the probe on a
  # repo that might be public". Refused BEFORE anything is written, so a
  # refusal leaves neither the git remote nor the config half-changed.
  local target=${url:-$have_origin}
  if [[ $trust == 1 && -n "$target" ]] && remote_is_github "$target"; then
    die "GitHub remotes are verified automatically; trust is only for other hosts"
  fi
  if [[ -n "$url" ]]; then
    assert_argv_safe "$url"
    if [[ -z "$have_origin" ]]; then
      git -C "$DATA_REPO" remote add origin "$url"
    else
      git -C "$DATA_REPO" remote set-url origin "$url"
    fi
  fi
  url=$(remote_origin_url)
  if [[ -n "$url" ]] && remote_is_github "$url"; then
    # Never carry a trust flag on a GitHub host, however the URL is spelled.
    # A shape remote_github_slug cannot turn into owner/repo is unverifiable,
    # and unverifiable must read as "cannot push", not as "trusted".
    trust=0
  elif [[ -n "$url" ]]; then
    # Same remote as last time, already trusted: the operator answered this
    # question once and nothing has changed, so the answer stands. A DIFFERENT
    # url makes the question live again and falls through to the warning
    # below, which is the whole point: trust must never carry over to a remote
    # nobody has vouched for.
    if [[ $trust == 0 && "$prior_trusted" == true && -n "$prior_url" && "$prior_url" == "$url" ]]; then
      trust=1
    fi
    # The trust question is only ever asked interactively: confirm's safe
    # default is no, so an unattended run (--yes, or no tty) leaves a
    # non-GitHub remote untrusted unless --trust-remote said otherwise.
    if [[ $trust == 0 && $yes == 0 ]] && confirm "This remote is not on GitHub, so OmaBackup cannot check that it is private. Push to it anyway? Only say yes if you know it is private." 0; then
      trust=1
    fi
    [[ $trust == 0 ]] && warn "non-GitHub remote left untrusted: commits will not be pushed until remote.trusted is true"
  fi
  config_write "$(jq --arg u "$url" --argjson t "$([[ $trust == 1 ]] && echo true || echo false)" '.remote={url:$u, trusted:$t}' "$CONFIG_FILE")"
  # Reload, because CFG_* is a CACHE and everything after this point in the
  # wizard reads it. setup_first_snapshot runs cmd_snapshot in-process, whose
  # remote_probe compares the live origin against CFG_REMOTE_URL and reads
  # CFG_REMOTE_TRUSTED: with the pre-setup values still in memory, the
  # status.json that setup itself writes said remote-unverified immediately
  # after `--trust-remote`, and the widget showed the "review the remote" card
  # until the next status run. Every setup group passed --no-timers, which
  # skips the first snapshot, so nothing caught it.
  config_load
  setup_phase "remote"
}

setup_units() {
  local dst="$HOME/.config/systemd/user"
  mkdir -p "$dst"
  local f cal jit
  cal=$(cfg timer.calendar); jit=$(cfg timer.jitter)
  for f in "$PLUGIN_DIR"/share/units/*; do
    # Placeholder-safe substitution. This was a sed `s|...|...|` with the
    # config value as the replacement text, so a `|` in the value terminated
    # the command and the rest of it became further sed script, and an `&`
    # expanded to the match. config_load now refuses a value systemd cannot
    # parse, which closes that door; this closes the frame too, by never
    # letting the value be read as syntax at all. index/substr rather than
    # awk's own gsub, whose replacement string gives `&` the same meaning
    # sed's did.
    awk -v cal="$cal" -v jit="$jit" '
      function rep(s, tok, val,   out, i) {
        out = ""
        while ((i = index(s, tok)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(tok)) }
        return out s
      }
      { print rep(rep($0, "@CALENDAR@", cal), "@JITTER@", jit) }
    ' "$f" > "$dst/$(basename "$f")"
  done
  if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]]; then
    systemctl --user daemon-reload
    systemctl --user enable --now omabackup-snapshot.timer omabackup-selftest.timer
  fi
  setup_phase "units"
}

setup_cli_link() {
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$PLUGIN_DIR/bin/omabackup" "$HOME/.local/bin/omabackup"
  setup_phase "link"
}

# The two lines setup_shell_nag appends, named once so setup_remove can take
# back exactly what setup put in and nothing else.
NAG_COMMENT='# OmaBackup login check'
NAG_LINE='command -v omabackup >/dev/null && omabackup health'

# setup_shell_nag YES: opt in when config already carries shellNag, or
# (interactively) on confirm; --yes never turns it on by itself.
setup_shell_nag() {
  local yes=$1
  local rc="$HOME/.bashrc"
  if [[ $(cfg shellNag) == true ]] || { [[ $yes == 0 ]] && confirm "Add a login check to ~/.bashrc that prints only when the backup needs attention?" 0; }; then
    grep -qF "$NAG_LINE" "$rc" 2>/dev/null || printf '\n%s\n%s\n' "$NAG_COMMENT" "$NAG_LINE" >> "$rc"
    config_write "$(jq '.shellNag=true' "$CONFIG_FILE")"
  fi
  setup_phase "nag"
}

# setup_unnag: take the login check back out of ~/.bashrc. Exactly the block
# setup_shell_nag wrote (the blank line, the comment, the command) and nothing
# else: the file is a user's own, so this rewrites it through a temp file next
# to it, keeping its mode, and leaves every other line byte for byte alone.
# Never fatal -- a .bashrc this cannot rewrite must not stop the uninstall.
setup_unnag() {
  local rc="$HOME/.bashrc" tmp
  [[ -f "$rc" ]] || return 0
  grep -qxF -e "$NAG_LINE" -e "$NAG_COMMENT" "$rc" 2>/dev/null || return 0
  tmp=$(mktemp "$(dirname "$rc")/.bashrc.omabackup.XXXXXX") || { warn "could not rewrite $rc; remove the OmaBackup login check by hand"; return 0; }
  if awk -v cmt="$NAG_COMMENT" -v cmd="$NAG_LINE" '
      { lines[NR] = $0 }
      END {
        out = 0
        for (i = 1; i <= NR; i++) {
          # The whole block, in the shape setup wrote it: drop the blank line
          # we added in front of it too, so the file goes back to what it was.
          if (lines[i] == cmt && i < NR && lines[i+1] == cmd) {
            if (out > 0 && buf[out] == "") out--
            i++
            continue
          }
          # A half-edited block: still ours, still goes.
          if (lines[i] == cmt || lines[i] == cmd) continue
          buf[++out] = lines[i]
        }
        for (j = 1; j <= out; j++) print buf[j]
      }' "$rc" > "$tmp" \
    && chmod --reference="$rc" "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$rc"; then
    log "Removed the OmaBackup login check from ~/.bashrc"
  else
    rm -f "$tmp"
    warn "could not rewrite $rc; remove the OmaBackup login check by hand"
  fi
}

setup_first_snapshot() {
  log "Running the first snapshot (no push)"
  # Capture the inner call in a subshell (command substitution always forks
  # one) so its own die() can only exit THAT subshell, not the wizard: die()
  # exits the process outright, and without this a failing snapshot would
  # kill setup before it could report anything in the caller's own mode.
  local out
  if out=$(JSON=1 cmd_snapshot --no-push); then
    :
  else
    die "the first snapshot failed: $(jq -r '.error // "unknown"' <<<"$out" 2>/dev/null). Fix the reported problem and rerun omabackup setup"
  fi
}

# setup_check: the doctor (`setup check`). Probes tools, reads config if
# present, and reports everything needed to diagnose a broken install
# without changing anything. Exits 1 when a required tool or the data repo
# marker is missing.
setup_check() {
  local have_git=false have_rsync=false have_jq=false have_gum=false have_gitleaks=false have_flock=false have_systemd=false
  have git       && have_git=true
  have rsync     && have_rsync=true
  have jq        && have_jq=true
  have gum       && have_gum=true
  have gitleaks  && have_gitleaks=true
  have flock     && have_flock=true
  have systemctl && have_systemd=true

  local ok=true
  [[ $have_git == true && $have_rsync == true && $have_jq == true && $have_flock == true ]] || ok=false

  local cfg=false repo=false marker=false units_s=false units_t=false url="" kind=none trusted=false
  if config_exists; then
    cfg=true
    config_load
    [[ -d "$DATA_REPO/.git" ]] && repo=true
    if [[ -f "$DATA_REPO/.omabackup" ]]; then marker=true; else ok=false; fi
    url=$(remote_origin_url)
    # cfg()'s "getpath(...) // empty" treats a JSON false the same as
    # missing, so CFG_REMOTE_TRUSTED is empty (not "false") when the config
    # explicitly says untrusted; only "true" ever means true.
    [[ "$CFG_REMOTE_TRUSTED" == true ]] && trusted=true
    if [[ -n "$url" ]]; then
      if [[ -n "$(remote_github_slug "$url")" ]]; then kind=github; else kind=other; fi
    fi
    if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]]; then
      systemctl --user is-enabled omabackup-snapshot.timer >/dev/null 2>&1 && units_s=true
      systemctl --user is-enabled omabackup-selftest.timer >/dev/null 2>&1 && units_t=true
    fi
  fi

  # Data is never code: the tools object is assembled by jq from typed
  # arguments, not by concatenating strings into a JSON literal.
  local tools_json
  tools_json=$(jq -cn \
    --argjson git "$have_git" --argjson rsync "$have_rsync" --argjson jq "$have_jq" \
    --argjson gum "$have_gum" --argjson gitleaks "$have_gitleaks" --argjson flock "$have_flock" \
    --argjson systemd "$have_systemd" \
    '{git:$git, rsync:$rsync, jq:$jq, gum:$gum, gitleaks:$gitleaks, flock:$flock, systemd:$systemd}')

  local j
  j=$(jq -cn \
    --argjson ok "$ok" --argjson tools "$tools_json" --argjson cfg "$cfg" --argjson repo "$repo" \
    --argjson marker "$marker" --argjson us "$units_s" --argjson ut "$units_t" \
    --arg url "$url" --arg kind "$kind" --argjson trusted "$trusted" \
    '{ok:$ok, tools:$tools, config:$cfg, dataRepo:$repo, marker:$marker,
      units:{snapshot:$us, selftest:$ut}, remote:{url:$url, kind:$kind, trusted:$trusted}}')

  if [[ $JSON == 1 ]]; then
    printf '%s\n' "$j"
  else
    jq -r 'to_entries[] | "\(.key): \(.value)"' <<<"$j"
    [[ $have_gitleaks == true ]] || echo "gitleaks missing: snapshots commit but never push (pacman -S gitleaks)"
  fi
  [[ $ok == true ]]
}

# setup_remove [--yes]: undo the local install (timers, the ~/.local/bin
# symlink, config). The data repo and its remote are never touched.
setup_remove() {
  local yes=0
  [[ "${1:-}" == --yes ]] && yes=1
  confirm "Remove OmaBackup timers, CLI link, the ~/.bashrc login check and config? The data repo stays." "$yes" || die "cancelled"
  if [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]]; then
    systemctl --user disable --now omabackup-snapshot.timer omabackup-selftest.timer 2>/dev/null || true
  fi
  rm -f "$HOME/.config/systemd/user"/omabackup-*.{service,timer} "$HOME/.local/bin/omabackup"
  [[ "${OMABACKUP_SKIP_TIMERS:-0}" != 1 ]] && systemctl --user daemon-reload || true
  # Step 8 of the setup wizard, undone. Spec section 6 says --remove reverses
  # steps 6, 7 and 8; the .bashrc line was the one it never took back, so an
  # uninstalled OmaBackup kept printing "command not found" at every login.
  setup_unnag
  rm -f "$CONFIG_FILE"
  if [[ $JSON == 1 ]]; then
    jq -cn '{ok:true, removed:true}'
  else
    log "Removed. Your data repo and its remote are untouched."
  fi
}
