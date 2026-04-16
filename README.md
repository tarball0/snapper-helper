# `snapper-helper`
These are a bunch of shell functions that make the usage of [snapper](https://wiki.archlinux.org/title/Snapper) easier for btrfs users

## Functions
* `snapperls`
list available snapshots
* `snapper-ignore <directory>`
turn a directory into a recursive subvolume (to "ignore" said directory from snapshots and save space)
* `snapper-track <directory>`
undo the previous command
* `snapper-undo-latest <filepath>`
runs `undochange` on file from latest snapshot
* `snapper-undo-yesterday <filepath>`
runs `undochange` on file from yesterday's snapshot
* `snapper-undo-lastweek <filepath>`
runs `undochange` on file from last week's snapshot
