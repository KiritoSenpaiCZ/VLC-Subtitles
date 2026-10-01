# dev

Tools for maintaining the addons; not needed to use them.

Code that several addons share lives once in `shared/`. Every addon file
that uses a shared piece keeps a copy between two marker comments
(`>>> shared block "<name>"` ... `<<< shared block "<name>"`), so each
addon still works as a single standalone file.

- Change shared code: edit the file in `shared/`, then run `python dev/sync.py`
  (from this repo, with all the addon repos cloned next to it). It updates
  every copy (and, for VLC, refreshes `extensions/`).
- Check nothing drifted: `python dev/sync.py --check`.
- `targets.json` lists which addon files use which shared block.
