# Triaging drift

`omabackup drift` (and the widget popup) lists every path under `$HOME` and
watched `/etc` drop-in directories that is not already accounted for: a
`NEW` path with no allowlist or ignore entry, a `MODIFIED` stock file you
changed, or a `GONE` path whose allowlist entry no longer resolves on disk.
Nothing on this list is backed up until you decide what it is. This page
walks through making that decision, path by path, without hand-editing the
lists yourself.

Every decision here is recorded with a reason and a date, so a year from now
you (or whoever inherits the machine) can see why a path was skipped, not
just that it was.

## The procedure

1. **Scan fresh.** Run `omabackup drift`. The popup's own list is only as
   current as the last snapshot, so if it has been a while, run the command
   yourself before trusting the count. Read the whole report before deciding
   anything; a stale memory of last week's list is how the wrong decision
   gets made twice.

2. **Look at each path before deciding.** What is it, and does the app that
   owns it already have a config file backed up? A quick look at the file's
   size, age and content tells you more than its name does. Grep the four
   lists (allowlist, drift-ignore, etc-allowlist, and what is already
   present) for a prior decision about the same application; most surprises
   turn out to be a sibling of something already triaged.

3. **Classify it.** Use the table below. Most of it is judgment, not a rule
   you can automate; a blind "back everything up" is the wrong default as
   often as a blind "ignore everything" is.

4. **Act with the CLI or the popup buttons**, not by editing the lists by
   hand:

   - `omabackup allow PATH` adds it to the allowlist (it will be backed up
     on the next snapshot). The popup's Allow button does the same thing.
   - `omabackup ignore PATH [REASON]` records a dated decision not to back
     it up. Give it a real reason; if none is supplied the entry gets a
     generic placeholder that is barely more useful than no reason at all.
     If the path can contain a secret (a token, a key, a session cookie,
     clipboard history, anything that would be bad to leak), say so in the
     reason with a leading `SECRET:` so a future read of the list knows this
     one was excluded on purpose, not overlooked. The popup's ignore action
     offers the same reason field.
   - `omabackup resolve-gone PATH remove` deletes the dead allowlist entry
     for a path that is never coming back. `omabackup resolve-gone PATH
     optional` marks it `?optional` instead, for a path that might reappear
     (the app gets reinstalled, a profile gets recreated) and should stop
     warning without being forgotten. The popup's two buttons on a `GONE`
     row do the same.

5. **Verify.** Each of the commands above checks the list it just edited
   before keeping the change, and rolls it back if the check fails, so a bad
   edit cannot slip through unnoticed. Run `omabackup lint` on its own
   whenever you want the wider picture: duplicate entries, an ignore
   pattern wide enough to hide everything, a dead allowlist line for a path
   that no longer exists, and more, across all four lists at once. Fix
   anything it flags red; a yellow note is informational, not a failure.

6. **Snapshot.** `omabackup snapshot` copies every newly allowlisted path
   into the data repo, regenerates the manifests, commits, and pushes that
   commit. Run `omabackup drift` again afterward; a clean report (no
   unclaimed `NEW` or `GONE` entries) is the goal, not zero output.

7. **Push the list changes.** The snapshot above commits and pushes the
   backed-up files and the manifests, but not the four lists you just
   edited (allow, ignore and resolve-gone only change your working copy).
   Run `omabackup push --confirm` to commit and push those; it shows
   exactly which files it is about to stage first, since a list edit is
   worth a second look before it leaves the machine.

## Classification

| What you're looking at | Verdict | Where it goes |
|---|---|---|
| A token, password, key, cookie, session id, or anything else that would be bad to leak | Ignore, with a reason starting `SECRET:` | drift-ignore |
| A log file, lock file, cache directory, telemetry file, image cache, or anything rewritten every time the app runs | Ignore | drift-ignore |
| Rule packs, models, or clones an app downloads and refreshes on its own | Ignore | drift-ignore |
| A dotfile or config file you actually edited by hand, or a script you wrote yourself | Allow | allowlist |
| A stock Omarchy file you changed (reported `MODIFIED`) | Allow | allowlist |
| An install record or intent file with no other source of truth for what you meant to have installed | Allow | allowlist |
| Config owned by a plugin or app that disappears cleanly when it's uninstalled | Allow, marked optional (`?`) | allowlist |
| A file under an `/etc` drop-in directory that no package owns | Allow | etc-allowlist |
| A path reported `GONE` whose app is never coming back | Remove the entry | allowlist |
| A path reported `GONE` whose app might return | Mark optional | allowlist |

Prefer allowing the specific config file over the whole directory when the
directory also holds logs or state next to it; the file is what you want
back on a new machine, the state next to it is usually not.

## A few things that trip people up

- Ignoring a whole directory with a wide pattern is faster than ignoring
  files one at a time, and it is also how real config quietly stops being
  backed up. Only collapse a directory to a single ignore entry when nothing
  under it will ever matter; if that turns out to be wrong later, the fix is
  a narrower ignore entry, not un-ignoring the whole thing.
- A missing reason is a decision nobody can audit later. Take the extra ten
  seconds and say why.
- `omabackup lint` catches most of these mistakes before they reach the
  data repo. Read what it flags rather than re-running it until it goes
  quiet.
