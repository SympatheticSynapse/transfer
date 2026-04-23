#!/usr/bin/env bash
# =============================================================================
# helm-scan.sh — Helm repo bloat & redundancy scanner
# Usage: ./helm-scan.sh [REPO_ROOT] [--html] [--skip-dep-update]
#   REPO_ROOT          Path to your helm repo (default: current directory)
#   --html             Also emit an HTML report (helm-scan-report.html)
#   --skip-dep-update  Skip 'helm dependency update' (use if deps are pre-vendored)
# =============================================================================
set -euo pipefail

REPO_ROOT="${1:-.}"
EMIT_HTML=false
SKIP_DEP_UPDATE=false
for arg in "$@"; do
  [[ "$arg" == "--html" ]] && EMIT_HTML=true
  [[ "$arg" == "--skip-dep-update" ]] && SKIP_DEP_UPDATE=true
done

# ── colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'
hr() { printf "${CYN}%s${RST}\n" "$(printf '─%.0s' {1..72})"; }
hdr() {
  echo
  hr
  printf "${BLD}  %-68s${RST}\n" "$1"
  hr
}

# ── dependency checks ─────────────────────────────────────────────────────────
need() { command -v "$1" &>/dev/null || {
  echo "ERROR: '$1' not found"
  exit 1
}; }
need helm
need yq
need python3

HELM_LIMIT=$((5 * 1024 * 1024))   # 5 MB
SECRET_LIMIT=$((1 * 1024 * 1024)) # 1 MB
WARN_RATIO=80                     # % of limit that triggers a warning

# ── accumulator for HTML ──────────────────────────────────────────────────────
HTML_SECTIONS=()
html_section() { HTML_SECTIONS+=("$1"); }

# ── helper: bytes → human ─────────────────────────────────────────────────────
human() {
  python3 -c "
v=$1
for u in ['B','KB','MB','GB']:
    if v < 1024: print(f'{v:.1f} {u}'); break
    v /= 1024
"
}

# =============================================================================
# 1. DISCOVER CHARTS
# =============================================================================
hdr "1 · Discovering charts"

mapfile -t CHARTS < <(find "$REPO_ROOT" -name "Chart.yaml" -not -path "*/charts/*" | sort)

if [[ ${#CHARTS[@]} -eq 0 ]]; then
  echo "No Chart.yaml files found under $REPO_ROOT"
  exit 1
fi

echo "Found ${#CHARTS[@]} chart(s):"
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  kind=$(yq '.type // "application"' "$c" 2>/dev/null)
  printf "  ${GRN}%-40s${RST}  %s\n" "$name" "$kind"
done

CHART_TABLE=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  kind=$(yq '.type // "application"' "$c" 2>/dev/null)
  CHART_TABLE+="<tr><td>$name</td><td>$chart_dir</td><td>$kind</td></tr>"
done

html_section "
<section>
  <h2>1 · Charts Discovered</h2>
  <table>
    <thead><tr><th>Name</th><th>Path</th><th>Type</th></tr></thead>
    <tbody>$CHART_TABLE</tbody>
  </table>
</section>"

# =============================================================================
# 2. RENDERED SIZE PER CHART
# =============================================================================
hdr "2 · Rendered manifest sizes  (helm template)"

SIZE_ROWS=""
declare -A CHART_RENDER_PATH # chart_dir → tmp rendered file

for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")

  # collect values files next to Chart.yaml
  VALUES_FLAGS=()
  while IFS= read -r vf; do
    VALUES_FLAGS+=(-f "$vf")
  done < <(find "$chart_dir" -maxdepth 2 -name "values*.yaml" \
    -not -name "values.schema.json" | sort)

  TMP_RENDER=$(mktemp /tmp/helm-scan-render-XXXX.yaml)
  CHART_RENDER_PATH["$chart_dir"]="$TMP_RENDER"

  # ── resolve dependencies ──────────────────────────────────────────────────
  DEP_ERR=""
  if [[ "$SKIP_DEP_UPDATE" == false && -f "$chart_dir/Chart.yaml" ]]; then
    has_deps=$(yq '.dependencies | length' "$chart_dir/Chart.yaml" 2>/dev/null || echo "0")
    if [[ "$has_deps" != "0" && "$has_deps" != "null" ]]; then
      printf "    updating dependencies for %s ... " "$name"
      if dep_out=$(helm dependency update "$chart_dir" 2>&1); then
        printf "${GRN}ok${RST}\n"
      else
        DEP_ERR="$dep_out"
        printf "${YEL}warn (continuing anyway)${RST}\n"
        echo "    $dep_out" | head -5
      fi
    fi
  fi

  if helm template "scan-release" "$chart_dir" "${VALUES_FLAGS[@]}" \
    --include-crds 2>/dev/null >"$TMP_RENDER"; then
    size=$(wc -c <"$TMP_RENDER")
    pct=$((size * 100 / HELM_LIMIT))
    h=$(human $size)

    if ((size > HELM_LIMIT)); then
      col=$RED tag="OVER LIMIT"
    elif ((pct > WARN_RATIO)); then
      col=$YEL tag="WARNING"
    else
      col=$GRN tag="OK"
    fi

    printf "  ${col}%-40s  %8s  (%3d%% of 5 MB)  %s${RST}\n" \
      "$name" "$h" "$pct" "$tag"
    SIZE_ROWS+="<tr class='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')'>"
    SIZE_ROWS+="<td>$name</td><td>$h</td><td>$pct%</td><td>$tag</td></tr>"
  else
    render_err=$(helm template "scan-release" "$chart_dir" "${VALUES_FLAGS[@]}" \
      --include-crds 2>&1 | head -6 || true)
    printf "  ${RED}%-40s  render failed${RST}\n" "$name"
    echo "$render_err" | sed 's/^/    /'
    SIZE_ROWS+="<tr class='error'><td>$name</td><td colspan='3'>render failed</td></tr>"
  fi
done

html_section "
<section>
  <h2>2 · Rendered Manifest Sizes</h2>
  <p>Helm limit: 5 MB. Warning threshold: ${WARN_RATIO}%.</p>
  <table>
    <thead><tr><th>Chart</th><th>Size</th><th>% of limit</th><th>Status</th></tr></thead>
    <tbody>$SIZE_ROWS</tbody>
  </table>
</section>"

# =============================================================================
# 3. LARGEST RESOURCES INSIDE EACH RENDERED CHART
# =============================================================================
hdr "3 · Largest rendered resources per chart"

RES_ROWS=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  TMP_RENDER="${CHART_RENDER_PATH[$chart_dir]:-}"
  [[ -z "$TMP_RENDER" || ! -s "$TMP_RENDER" ]] && continue

  echo
  printf "  ${BLD}%s${RST}\n" "$name"

  python3 - "$TMP_RENDER" "$name" "$SECRET_LIMIT" "$WARN_RATIO" <<'PYEOF'
import sys, yaml, json

path, chart_name, secret_limit, warn_ratio = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
secret_limit = int(secret_limit)
warn_ratio   = int(warn_ratio)

def safe_load_file(p):
    with open(p) as fh:
        raw = fh.read().replace('\t', '  ')
    return list(yaml.safe_load_all(raw))

try:
    docs = [d for d in safe_load_file(path) if d]
except yaml.YAMLError as e:
    print(f"    YAML parse error in rendered output: {e}")
    docs = []

rows = []
for d in docs:
    kind = d.get("kind", "?")
    meta = d.get("metadata", {})
    ns   = meta.get("namespace", "")
    nm   = meta.get("name", "?")
    sz   = len(json.dumps(d).encode())
    rows.append((sz, kind, ns, nm))

rows.sort(reverse=True)
html_rows = ""
for sz, kind, ns, nm in rows[:15]:
    label = f"{ns}/{nm}" if ns else nm
    h = f"{sz/1024:.1f} KB" if sz >= 1024 else f"{sz} B"
    flag = ""
    if kind == "Secret":
        pct = sz * 100 // secret_limit
        if sz > secret_limit:      flag = f"  ⚠ SECRET OVER 1 MB ({pct}%)"
        elif pct > warn_ratio:     flag = f"  ⚠ SECRET large ({pct}% of 1 MB)"
    print(f"    {h:>10}  {kind:<20} {label}{flag}")
    css = "over-limit" if "OVER" in flag else ("warning" if "⚠" in flag else "")
    html_rows += f"<tr class='{css}'><td>{chart_name}</td><td>{kind}</td><td>{label}</td><td>{h}</td><td>{flag.strip()}</td></tr>"

# write partial HTML to stdout marker
print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

done | tee /tmp/helm-scan-res-raw.txt | grep -v "__HTML_ROWS__"

# extract html rows
RES_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' \
  /tmp/helm-scan-res-raw.txt | tr -d '\n' || true)

html_section "
<section>
  <h2>3 · Largest Rendered Resources</h2>
  <table>
    <thead><tr><th>Chart</th><th>Kind</th><th>Name</th><th>Size</th><th>Flag</th></tr></thead>
    <tbody>$RES_ROWS</tbody>
  </table>
</section>"

# =============================================================================
# 4. VALUES REDUNDANCY — keys identical to chart defaults
# =============================================================================
hdr "4 · Values redundant vs chart defaults"

REDUNDANT_ROWS=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")

  default_values="$chart_dir/values.yaml"
  [[ ! -f "$default_values" ]] && continue

  # find override values files (values-*.yaml, values.*.yaml, etc.)
  while IFS= read -r override; do
    [[ "$override" == "$default_values" ]] && continue

    echo
    printf "  ${BLD}%s${RST}  ←  %s\n" "$name" "$(basename "$override")"

    python3 - "$default_values" "$override" "$name" <<'PYEOF'
import sys, yaml

def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
    elif isinstance(d, list):
        for i, v in enumerate(d):
            out.update(flatten(v, f"{prefix}[{i}]"))
    else:
        out[prefix] = d
    return out

defaults_path, override_path, chart_name = sys.argv[1], sys.argv[2], sys.argv[3]

def safe_load(p):
    try:
        with open(p) as fh:
            return yaml.safe_load(fh.read().replace('\t', '  ')) or {}
    except yaml.YAMLError as e:
        print(f"    YAML parse error in {p}: {e}")
        return {}

defaults  = flatten(safe_load(defaults_path))
overrides = flatten(safe_load(override_path))

redundant = [(k, v) for k, v in overrides.items()
             if k in defaults and defaults[k] == v]
unique    = [k for k in overrides if k not in defaults or defaults[k] != overrides[k]]

print(f"    Redundant keys (same as default): {len(redundant)}")
print(f"    Unique/overriding keys:           {len(unique)}")

html_rows = ""
for k, v in redundant[:30]:
    val_str = str(v)[:80]
    print(f"      {k} = {val_str}")
    html_rows += f"<tr><td>{chart_name}</td><td>{k}</td><td>{val_str}</td></tr>"

print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

  done < <(find "$chart_dir" -maxdepth 2 -name "values*.yaml" | sort)
done | tee /tmp/helm-scan-redundant-raw.txt | grep -v "__HTML_ROWS__"

REDUNDANT_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' \
  /tmp/helm-scan-redundant-raw.txt | tr -d '\n' || true)

html_section "
<section>
  <h2>4 · Redundant Values (identical to chart defaults)</h2>
  <table>
    <thead><tr><th>Chart</th><th>Key</th><th>Value</th></tr></thead>
    <tbody>$REDUNDANT_ROWS</tbody>
  </table>
</section>"

# =============================================================================
# 5. UNUSED VALUES — defined but never referenced in templates
# =============================================================================
hdr "5 · Unused values (not referenced in templates)"

UNUSED_ROWS=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  values_file="$chart_dir/values.yaml"
  templates_dir="$chart_dir/templates"
  [[ ! -f "$values_file" || ! -d "$templates_dir" ]] && continue

  echo
  printf "  ${BLD}%s${RST}\n" "$name"

  python3 - "$values_file" "$templates_dir" "$name" <<'PYEOF'
import sys, os, yaml, re

values_path, templates_dir, chart_name = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(values_path) as f:
        values = yaml.safe_load(f.read().replace('\t', '  ')) or {}
except yaml.YAMLError as e:
    print(f"    YAML parse error in {values_path}: {e}")
    values = {}

# collect all template text
template_text = ""
for root, _, files in os.walk(templates_dir):
    for fn in files:
        if fn.endswith((".yaml", ".tpl", ".txt")):
            try:
                with open(os.path.join(root, fn)) as tf:
                    template_text += tf.read()
            except Exception:
                pass

def top_keys(d, prefix=""):
    out = []
    if isinstance(d, dict):
        for k in d:
            full = f"{prefix}.{k}" if prefix else k
            out.append(full)
            out.extend(top_keys(d[k], full))
    return out

unused, used = [], []
for key in top_keys(values):
    leaf = key.split(".")[-1]
    # check both .Values.key and quoted references
    if re.search(rf'\.Values\.{re.escape(key)}|\.Values\[.{re.escape(leaf)}.', template_text):
        used.append(key)
    elif re.search(rf'\b{re.escape(leaf)}\b', template_text):
        used.append(key)   # leaf found somewhere — count as used
    else:
        unused.append(key)

print(f"    Used keys:   {len(used)}")
print(f"    Unused keys: {len(unused)}")

html_rows = ""
for k in unused[:40]:
    print(f"      .Values.{k}")
    html_rows += f"<tr><td>{chart_name}</td><td>.Values.{k}</td></tr>"

print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

done | tee /tmp/helm-scan-unused-raw.txt | grep -v "__HTML_ROWS__"

UNUSED_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' \
  /tmp/helm-scan-unused-raw.txt | tr -d '\n' || true)

html_section "
<section>
  <h2>5 · Unused Values (not referenced in templates)</h2>
  <table>
    <thead><tr><th>Chart</th><th>Key</th></tr></thead>
    <tbody>$UNUSED_ROWS</tbody>
  </table>
</section>"

# =============================================================================
# 6. DUPLICATE VALUES ACROSS CHARTS
# =============================================================================
hdr "6 · Duplicate leaf values across charts"

ALL_VALUES_FILES=()
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  while IFS= read -r vf; do
    ALL_VALUES_FILES+=("$vf")
  done < <(find "$chart_dir" -maxdepth 2 -name "values*.yaml" | sort)
done

if [[ ${#ALL_VALUES_FILES[@]} -gt 1 ]]; then
  python3 - "${ALL_VALUES_FILES[@]}" <<'PYEOF'
import sys, yaml
from collections import defaultdict

files = sys.argv[1:]

def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
    elif isinstance(d, list):
        for i, v in enumerate(d):
            out.update(flatten(v, f"{prefix}[{i}]"))
    else:
        out[prefix] = d
    return out

key_sources = defaultdict(list)
for fp in files:
    try:
        with open(fp) as f:
            raw = f.read().replace('\t', '  ')
        flat = flatten(yaml.safe_load(raw) or {})
        for k, v in flat.items():
            key_sources[f"{k}={v}"].append(fp)
    except Exception as e:
        print(f"  skipping {fp}: {e}")

dupes = {k: v for k, v in key_sources.items() if len(v) > 1}
print(f"  Duplicated key=value pairs across charts: {len(dupes)}")
print(f"  (Candidates to hoist into a global values file)\n")
for kv, sources in sorted(dupes.items(), key=lambda x: -len(x[1]))[:30]:
    k, _, v = kv.partition("=")
    print(f"  {k} = {v[:60]}")
    for s in sources:
        print(f"      {s}")
PYEOF
fi

html_section "
<section>
  <h2>6 · Duplicate Values Across Charts</h2>
  <p>Candidates to hoist into a shared <code>global:</code> block.</p>
  <pre id='dup-out'>See terminal output — run with --html for full list</pre>
</section>"

# =============================================================================
# 7. CHART PACKAGE SIZE ESTIMATE
# =============================================================================
hdr "7 · Chart directory sizes (pre-package estimate)"

DIR_ROWS=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  sz=$(du -sb "$chart_dir" 2>/dev/null | awk '{print $1}')
  h=$(human "$sz")
  pct=$((sz * 100 / HELM_LIMIT))
  if ((sz > HELM_LIMIT)); then
    col=$RED tag="OVER LIMIT"
  elif ((pct > WARN_RATIO)); then
    col=$YEL tag="WARNING"
  else
    col=$GRN tag="OK"
  fi
  printf "  ${col}%-40s  %8s  (%3d%% of 5 MB)  %s${RST}\n" "$name" "$h" "$pct" "$tag"
  DIR_ROWS+="<tr class='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')'>"
  DIR_ROWS+="<td>$name</td><td>$h</td><td>$pct%</td><td>$tag</td></tr>"
done

html_section "
<section>
  <h2>7 · Chart Directory Sizes</h2>
  <table>
    <thead><tr><th>Chart</th><th>Size</th><th>% of 5 MB</th><th>Status</th></tr></thead>
    <tbody>$DIR_ROWS</tbody>
  </table>
</section>"

# =============================================================================
# 8. .helmignore CHECK
# =============================================================================
hdr "8 · .helmignore audit"

IGNORE_ROWS=""
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  name=$(yq '.name' "$c" 2>/dev/null || basename "$chart_dir")
  ignore_file="$chart_dir/.helmignore"
  if [[ -f "$ignore_file" ]]; then
    sz=$(wc -l <"$ignore_file")
    printf "  ${GRN}%-40s  .helmignore present (%d lines)${RST}\n" "$name" "$sz"
    IGNORE_ROWS+="<tr class='ok'><td>$name</td><td>Present</td><td>$sz lines</td></tr>"
  else
    printf "  ${YEL}%-40s  .helmignore MISSING${RST}\n" "$name"
    IGNORE_ROWS+="<tr class='warning'><td>$name</td><td>Missing</td><td>—</td></tr>"
  fi
done

RECOMMENDED_IGNORE='*.md\n*.txt\nCHANGELOG\ntests/\ntest/\nci/\n.github/\n.git/\n*.orig\n*.bak'
echo
echo "  Recommended .helmignore entries:"
printf "  %b\n" "$RECOMMENDED_IGNORE" | sed 's/^/    /'

html_section "
<section>
  <h2>8 · .helmignore Audit</h2>
  <table>
    <thead><tr><th>Chart</th><th>Status</th><th>Lines</th></tr></thead>
    <tbody>$IGNORE_ROWS</tbody>
  </table>
  <p>Recommended entries: <code>*.md, *.txt, CHANGELOG, tests/, ci/, .github/, .git/</code></p>
</section>"

# =============================================================================
# CLEANUP TEMP FILES
# =============================================================================
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  tmp="${CHART_RENDER_PATH[$chart_dir]:-}"
  [[ -n "$tmp" && -f "$tmp" ]] && rm -f "$tmp"
done
rm -f /tmp/helm-scan-res-raw.txt /tmp/helm-scan-redundant-raw.txt \
  /tmp/helm-scan-unused-raw.txt

# =============================================================================
# SUMMARY
# =============================================================================
hdr "✓ Scan complete"
echo "  Charts scanned : ${#CHARTS[@]}"
echo "  Helm limit     : 5 MB"
echo "  Secret limit   : 1 MB"
echo "  Warn threshold : ${WARN_RATIO}% of limit"
[[ "$EMIT_HTML" == true ]] && echo "  HTML report    : helm-scan-report.html"

# =============================================================================
# HTML REPORT
# =============================================================================
if [[ "$EMIT_HTML" == true ]]; then
  {
    cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Helm Repo Scan Report</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600&display=swap');
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #c9d1d9; --muted: #8b949e;
    --red: #f85149; --yellow: #d29922; --green: #3fb950; --blue: #58a6ff;
    --font-mono: 'IBM Plex Mono', monospace;
    --font-sans: 'IBM Plex Sans', sans-serif;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: var(--font-sans);
         font-size: 14px; line-height: 1.6; padding: 2rem; }
  h1 { font-size: 1.6rem; font-weight: 600; color: var(--blue); margin-bottom: .25rem; }
  .subtitle { color: var(--muted); font-size: .85rem; margin-bottom: 2.5rem; font-family: var(--font-mono); }
  h2 { font-size: 1rem; font-weight: 600; color: var(--blue); margin: 2rem 0 .75rem;
       padding-bottom: .4rem; border-bottom: 1px solid var(--border); }
  section { margin-bottom: 2rem; }
  table { width: 100%; border-collapse: collapse; font-family: var(--font-mono); font-size: .8rem; }
  th { background: var(--surface); color: var(--muted); text-align: left;
       padding: .5rem .75rem; border: 1px solid var(--border); font-weight: 600; }
  td { padding: .45rem .75rem; border: 1px solid var(--border); vertical-align: top; word-break: break-word; }
  tr:nth-child(even) td { background: rgba(255,255,255,.02); }
  tr.over-limit td, tr.over-limit td { color: var(--red); }
  tr.warning td { color: var(--yellow); }
  tr.ok td { color: var(--green); }
  tr.error td { color: var(--muted); font-style: italic; }
  p { color: var(--muted); margin: .5rem 0; font-size: .85rem; }
  code { background: var(--surface); border: 1px solid var(--border); border-radius: 3px;
         padding: .1rem .4rem; font-family: var(--font-mono); font-size: .8rem; }
  pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
        padding: 1rem; font-family: var(--font-mono); font-size: .78rem;
        overflow-x: auto; color: var(--muted); }
</style>
</head>
<body>
<h1>⎈ Helm Repo Scan</h1>
HTML_HEAD
    echo "<p class='subtitle'>Generated: $(date -u '+%Y-%m-%d %H:%M UTC') · Repo: $REPO_ROOT</p>"
    for section in "${HTML_SECTIONS[@]}"; do echo "$section"; done
    echo "</body></html>"
  } >helm-scan-report.html
  echo
  echo "  → HTML report written to: helm-scan-report.html"
fi
