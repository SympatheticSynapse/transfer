#!/usr/bin/env bash
# Usage: ./combine_to_csv.sh <directory> > output.csv
# Processes all *.txt files in the given directory.
# Each txt file is expected to have lines like:
#   123K path/charts/filename
#   22M total
# Output: CSV with filenames as rows, paths as columns, sizes as values.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <directory>" >&2
  exit 1
fi

dir="$1"

if [[ ! -d "$dir" ]]; then
  echo "Error: '$dir' is not a directory." >&2
  exit 1
fi

# Collect all txt files in the directory
mapfile -t txt_files < <(find "$dir" -maxdepth 1 -name "*.txt" | sort)

if [[ ${#txt_files[@]} -eq 0 ]]; then
  echo "Error: No .txt files found in '$dir'." >&2
  exit 1
fi

declare -A data       # data[filename,path]=size
declare -a all_files  # ordered list of unique filenames
declare -a all_paths  # ordered list of paths (one per input file)
declare -A seen_files # tracks insertion order for filenames

for txt in "${txt_files[@]}"; do
  # Derive a column header from the input filename (strip extension)
  path_label=$(basename "$txt" .txt)

  all_paths+=("$path_label")

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and the "total" summary line
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*[0-9]+[KMGTkmgt]*[[:space:]]+total[[:space:]]*$ ]] && continue

    # Parse: <size> <filepath>
    size=$(echo "$line" | awk '{print $1}')
    filepath=$(echo "$line" | awk '{print $2}')

    # Use just the basename as the row identifier
    filename=$(basename "$filepath")

    data["$filename,$path_label"]="$size"

    if [[ -z "${seen_files[$filename]+_}" ]]; then
      seen_files["$filename"]=1
      all_files+=("$filename")
    fi
  done <"$txt"
done

# --- Print CSV ---

# Header row: first column is "filename", then one column per input file
header="filename"
for p in "${all_paths[@]}"; do
  header+=",${p}"
done
echo "$header"

# Data rows
for fname in "${all_files[@]}"; do
  row="$fname"
  for p in "${all_paths[@]}"; do
    key="$fname,$p"
    val="${data[$key]:-}" # empty string if this file didn't appear in that txt
    row+=",${val}"
  done
  echo "$row"
done
