# script to make nested subvolume of any directory
snapper-ignore() {
  if [[ -z "$1" ]]; then
    echo "Usage: snapper-ignore <directory_path>"
    return 1
  fi

  # Resolve absolute path to handle relative paths like './.cache'
  local target=$(realpath "$1")

  # Guard 1: Prevent running on critical roots
  if [[ "$target" == "/" || "$target" == "$HOME" || "$target" == "" ]]; then
    echo "Error: Cannot convert root or home directory into a nested subvolume."
    return 1
  fi

  # Guard 2: Ensure it exists and is a directory
  if [[ ! -d "$target" ]]; then
    echo "Error: Directory '$target' does not exist."
    return 1
  fi

  # Guard 3: Check if it is already a subvolume
  if sudo btrfs subvolume show "$target" &>/dev/null; then
    echo "Info: '$target' is already a subvolume. Nothing to do."
    return 0
  fi

  echo "Converting '$target' into an ignored Btrfs subvolume..."
  local backup="${target}_btrfs_backup"

  # Guard 4: Ensure backup directory doesn't already exist
  if [[ -e "$backup" ]]; then
    echo "Error: Backup path '$backup' already exists. Aborting for safety."
    return 1
  fi

  # Step 1: Move the original directory out of the way
  echo "-> Moving current directory to backup..."
  mv "$target" "$backup"

  # Step 2: Create the new subvolume
  echo "-> Creating new subvolume..."
  if ! sudo btrfs subvolume create "$target"; then
    echo "Error: Failed to create subvolume. Reverting..."
    mv "$backup" "$target"
    return 1
  fi

  # Step 3: Fix ownership (btrfs subvolume create runs as root)
  echo "-> Restoring user permissions..."
  sudo chown -R "$(id -un):$(id -gn)" "$target"

  # Step 4: Restore data using Btrfs reflink (instant, zero extra space)
  echo "-> Restoring data via CoW reflink..."
  if cp -a --reflink=always "$backup"/. "$target"/; then
    # Step 5: Clean up only on absolute success
    echo "-> Copy successful. Cleaning up backup..."
    rm -rf "$backup"
    echo "Success! '$target' is now an independent subvolume and will be ignored by Snapper."
  else
    echo "Error: Data restore failed. Your data is safely preserved in '$backup'."
    return 1
  fi
}


# Compare the most recent Snapper snapshot to the live system
snapper-latest() {
  # Grab the first column of the very last line of the snapper list
  local latest=$(snapper -c home list | tail -n 1 | awk '{print $1}')
  
  if [[ -z "$latest" || "$latest" == "0" ]]; then
    echo "Error: Could not find a valid previous snapshot."
    return 1
  fi

  echo "-> Comparing latest snapshot (#$latest) against live system (#0)..."
  echo "--------------------------------------------------------------"
  snapper -c home status ${latest}..0
}

snapper-track() {
  if [[ -z "$1" ]]; then
    echo "Usage: snapper-track <directory_path>"
    return 1
  fi

  # Resolve absolute path
  local target=$(realpath "$1")

  # Guard 1: Prevent running on critical roots
  if [[ "$target" == "/" || "$target" == "$HOME" || "$target" == "" ]]; then
    echo "Error: Cannot modify root or home directory."
    return 1
  fi

  # Guard 2: Ensure it exists
  if [[ ! -d "$target" ]]; then
    echo "Error: Directory '$target' does not exist."
    return 1
  fi

  # Guard 3: Ensure it actually IS a subvolume
  if ! sudo btrfs subvolume show "$target" &>/dev/null; then
    echo "Error: '$target' is not a subvolume. It is already being tracked by Snapper."
    return 1
  fi

  echo "Converting '$target' from a subvolume back to a tracked directory..."
  local backup="${target}_btrfs_subvol_backup"

  # Guard 4: Ensure backup directory doesn't already exist
  if [[ -e "$backup" ]]; then
    echo "Error: Backup path '$backup' already exists. Aborting for safety."
    return 1
  fi

  # Step 1: Move the subvolume out of the way
  echo "-> Moving subvolume to temporary backup..."
  mv "$target" "$backup"

  # Step 2: Create the new standard directory
  echo "-> Creating standard directory..."
  mkdir "$target"

  # Step 3: Restore user permissions
  echo "-> Setting ownership..."
  sudo chown -R "$(id -un):$(id -gn)" "$target"

  # Step 4: Restore data using Btrfs reflink (instant, zero extra space)
  echo "-> Copying data back via CoW reflink..."
  if cp -a --reflink=always "$backup"/. "$target"/; then
    # Step 5: Clean up old subvolume only on absolute success
    echo "-> Copy successful. Deleting the old subvolume..."
    sudo btrfs subvolume delete "$backup"
    echo "Success! '$target' is now a standard directory and will be tracked by Snapper."
  else
    # Auto-Revert on failure
    echo "Error: Data restore failed. Reverting changes..."
    rm -rf "$target"
    mv "$backup" "$target"
    return 1
  fi
}

snapperls() {
	snapper -c home list
}

# 1. Rollback file to the absolutely most recent snapshot
snapper-undo-latest() {
  if [[ -z "$1" ]]; then
    echo "Usage: snapper-undo-latest <file_path>"
    return 1
  fi
  
  local target=$(realpath "$1")
  local snap_id=$(snapper -c home list | tail -n 1 | awk '{print $1}')
  
  if [[ -z "$snap_id" || "$snap_id" == "0" ]]; then
    echo "Error: No valid snapshots found."
    return 1
  fi
  
  echo "-> Restoring '$(basename "$target")' from Latest Snapshot (#$snap_id)..."
  snapper -c home undochange ${snap_id}..0 "$target"
}

# 2. Rollback file to the last snapshot taken yesterday
snapper-undo-yesterday() {
  if [[ -z "$1" ]]; then
    echo "Usage: snapper-undo-yesterday <file_path>"
    return 1
  fi
  
  local target=$(realpath "$1")
  # Generate exact date strings (handles both '05 Apr' and ' 5 Apr' padding quirks)
  local d1=$(date -d "yesterday" "+%d %b %Y")
  local d2=$(date -d "yesterday" "+%e %b %Y")
  
  # Find the highest snapshot ID from that specific date
  local snap_id=$(snapper -c home list | grep -E "$d1|$d2" | tail -n 1 | awk '{print $1}')
  
  if [[ -z "$snap_id" ]]; then
    echo "Error: No snapshots exist for yesterday."
    return 1
  fi
  
  echo "-> Restoring '$(basename "$target")' from Yesterday's Snapshot (#$snap_id)..."
  snapper -c home undochange ${snap_id}..0 "$target"
}

# 3. Rollback file to the last snapshot taken exactly 7 days ago
snapper-undo-lastweek() {
  if [[ -z "$1" ]]; then
    echo "Usage: snapper-undo-lastweek <file_path>"
    return 1
  fi
  
  local target=$(realpath "$1")
  local d1=$(date -d "7 days ago" "+%d %b %Y")
  local d2=$(date -d "7 days ago" "+%e %b %Y")
  
  local snap_id=$(snapper -c home list | grep -E "$d1|$d2" | tail -n 1 | awk '{print $1}')
  
  if [[ -z "$snap_id" ]]; then
    echo "Error: No snapshots exist for exactly one week ago."
    return 1
  fi
  
  echo "-> Restoring '$(basename "$target")' from Last Week's Snapshot (#$snap_id)..."
  snapper -c home undochange ${snap_id}..0 "$target"
}

