#!/usr/bin/env bash
# =============================================================================
# helm-scan.sh — Helm repo bloat & redundancy scanner
# Usage: ./helm-scan.sh [REPO_ROOT] [--html] [--skip-dep-update] [--globals FILE ...]
#   REPO_ROOT          Path to your helm repo (default: current directory)
#   --html             Also emit an HTML report (helm-scan-report.html)
#   --skip-dep-update  Skip 'helm dependency update' (use if deps are pre-vendored)
#   --globals FILE     Explicit global values file(s) prepended to every helm template call.
#                      May be repeated: --globals global.yaml --globals env/prod.yaml
#                      If omitted, the script auto-discovers files matching common patterns.
# =============================================================================
set -euo pipefail

REPO_ROOT="${1:-.}"
EMIT_HTML=false
SKIP_DEP_UPDATE=false
EXPLICIT_GLOBALS=() # files passed via --globals

# parse flags (consume --globals FILE pairs; leave other args alone)
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  if [[ "$arg" == "--html" ]]; then
    EMIT_HTML=true
  elif [[ "$arg" == "--skip-dep-update" ]]; then
    SKIP_DEP_UPDATE=true
  elif [[ "$arg" == "--globals" ]]; then
    i=$((i + 1))
    [[ $i -le $# ]] && EXPLICIT_GLOBALS+=("${!i}")
  fi
  i=$((i + 1))
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

# =============================================================================
# 0. GLOBAL VALUES RESOLUTION
# =============================================================================
# Common naming patterns for repo-wide / environment global values files.
# Searched at REPO_ROOT and one level deep. Chart-local values.yaml files are
# excluded here — they are picked up per-chart in section 2.
GLOBAL_PATTERNS=(
  "global.yaml"
  "global-values.yaml"
  "globals.yaml"
  "values-global.yaml"
  "values.global.yaml"
  "common.yaml"
  "common-values.yaml"
  "env.yaml"
  "env-values.yaml"
  "values-env.yaml"
  "base.yaml"
  "base-values.yaml"
  "shared.yaml"
  "shared-values.yaml"
  "defaults.yaml"
)

GLOBAL_VALUES_FLAGS=() # -f flags prepended to every helm template call

if [[ ${#EXPLICIT_GLOBALS[@]} -gt 0 ]]; then
  # User supplied explicit files — trust them, skip auto-discovery
  for gf in "${EXPLICIT_GLOBALS[@]}"; do
    if [[ -f "$gf" ]]; then
      GLOBAL_VALUES_FLAGS+=(-f "$gf")
    else
      printf "${YEL}  WARNING: --globals file not found: %s${RST}\n" "$gf"
    fi
  done
else
  # Auto-discover: search REPO_ROOT and one level of subdirectories
  for pattern in "${GLOBAL_PATTERNS[@]}"; do
    while IFS= read -r found; do
      # Skip files that live inside a chart directory (they have a sibling Chart.yaml)
      found_dir=$(dirname "$found")
      if [[ ! -f "$found_dir/Chart.yaml" ]]; then
        GLOBAL_VALUES_FLAGS+=(-f "$found")
      fi
    done < <(find "$REPO_ROOT" -maxdepth 2 -name "$pattern" 2>/dev/null | sort)
  done
fi

# Print what we found
hdr "0 · Global values files"
if [[ ${#GLOBAL_VALUES_FLAGS[@]} -eq 0 ]]; then
  printf "  ${YEL}None found.${RST} If templates use .Values.global.* you will get nil pointer\n"
  printf "  errors. Pass explicit files with:  --globals path/to/global.yaml\n"
else
  printf "  Will prepend to every helm template call:\n"
  for flag in "${GLOBAL_VALUES_FLAGS[@]}"; do
    [[ "$flag" == "-f" ]] && continue
    printf "    ${GRN}%s${RST}\n" "$flag"
  done
fi

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
  ver=$(yq '.version // "—"' "$c" 2>/dev/null)
  app_ver=$(yq '.appVersion // "—"' "$c" 2>/dev/null)
  dep_count=$(yq '.dependencies | length' "$c" 2>/dev/null || echo "0")
  kind_badge="<span class='badge info'>$kind</span>"
  [[ "$kind" == "library" ]] && kind_badge="<span class='badge muted'>$kind</span>"
  CHART_TABLE+="<tr data-status='ok'><td>$name</td><td style='color:var(--muted)'>$chart_dir</td><td>$kind_badge</td><td>$ver</td><td>$app_ver</td><td>${dep_count:-0}</td></tr>"
done

GLOBAL_HTML_ROWS=""
for flag in "${GLOBAL_VALUES_FLAGS[@]}"; do
  [[ "$flag" == "-f" ]] && continue
  GLOBAL_HTML_ROWS+="<tr data-status='ok'><td><span class='badge ok'>auto</span></td><td style='font-family:var(--mono);font-size:.75rem'>$flag</td></tr>"
done
[[ -z "$GLOBAL_HTML_ROWS" ]] && GLOBAL_HTML_ROWS="<tr><td colspan='2'><span class='badge warn'>None found</span> &nbsp;nil pointer errors likely if templates reference <code>.Values.global.*</code></td></tr>"

html_section "
<section id='sec0'>
  <div class='section-header'>
    <span class='section-num'>0</span>
    <h2>Global Values Files</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Files prepended to every <code>helm template</code> call. If missing, templates referencing <code>.Values.global.*</code> will produce nil pointer errors. Pass explicit files with <code>--globals path/to/global.yaml</code>.</div>
  <div class='section-body'>
    <div class='table-wrap'>
      <table id='tbl0'>
        <thead><tr><th>Source</th><th>Path</th></tr></thead>
        <tbody>$GLOBAL_HTML_ROWS</tbody>
      </table>
    </div>
  </div>
</section>"

html_section "
<section id='sec1'>
  <div class='section-header'>
    <span class='section-num'>1</span>
    <h2>Charts Discovered</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>All <code>Chart.yaml</code> files found in the repo (excluding vendored <code>charts/</code> subdirectories).</div>
  <div class='section-body'>
    <div class='table-wrap'>
      <table id='tbl1'>
        <thead><tr>
          <th data-col='0'>Name<span class='sort-icon'></span></th>
          <th data-col='1'>Path<span class='sort-icon'></span></th>
          <th data-col='2'>Type<span class='sort-icon'></span></th>
          <th data-col='3'>Version<span class='sort-icon'></span></th>
          <th data-col='4'>App Version<span class='sort-icon'></span></th>
          <th data-col='5'>Dependencies<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$CHART_TABLE</tbody>
      </table>
    </div>
  </div>
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

  if helm template "scan-release" "$chart_dir" \
    "${GLOBAL_VALUES_FLAGS[@]}" "${VALUES_FLAGS[@]}" \
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
    SIZE_ROWS+="<tr class='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')' data-status='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')'>"
    bar_cls="ok"
    [[ "$tag" == "WARNING" ]] && bar_cls="warn"
    [[ "$tag" == "OVER LIMIT" ]] && bar_cls="err"
    badge_cls="ok"
    [[ "$tag" == "WARNING" ]] && badge_cls="warn"
    [[ "$tag" == "OVER LIMIT" ]] && badge_cls="err"
    SIZE_ROWS+="<td>$name</td><td data-val='$size'>$h</td>"
    SIZE_ROWS+="<td><div class='bar-wrap'><div class='bar-track'><div class='bar-fill $bar_cls' style='width:${pct}%'></div></div><span class='bar-label'>$pct%</span></div></td>"
    SIZE_ROWS+="<td><span class='badge $badge_cls'>$tag</span></td></tr>"
  else
    render_err=$(helm template "scan-release" "$chart_dir" \
      "${GLOBAL_VALUES_FLAGS[@]}" "${VALUES_FLAGS[@]}" \
      --include-crds 2>&1 | head -6 || true)
    printf "  ${RED}%-40s  render failed${RST}\n" "$name"
    echo "$render_err" | sed 's/^/    /'
    SIZE_ROWS+="<tr class='error'><td>$name</td><td colspan='3'>render failed</td></tr>"
  fi
done

html_section "
<section id='sec2'>
  <div class='section-header'>
    <span class='section-num'>2</span>
    <h2>Rendered Manifest Sizes</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Output of <code>helm template</code> per chart. <strong>Hard limit: 5 MB.</strong> Warning at ${WARN_RATIO}%. Render failures usually mean missing dependencies or globals.</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl2'>
      <input type='search' placeholder='Filter charts…'>
      <button class='filter-btn active' data-status='all'>All</button>
      <button class='filter-btn' data-status='over-limit'>Over Limit</button>
      <button class='filter-btn' data-status='warning'>Warning</button>
      <button class='filter-btn' data-status='ok'>OK</button>
      <button class='filter-btn' data-status='error'>Failed</button>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl2'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>Rendered Size<span class='sort-icon'></span></th>
          <th data-col='2'>% of 5 MB limit<span class='sort-icon'></span></th>
          <th data-col='3'>Status<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$SIZE_ROWS</tbody>
      </table>
    </div>
    <div class='tip-box'>
      <div class='tip-title'>💡 Remediation</div>
      <ul>
        <li><strong>Over limit:</strong> Split the umbrella chart by domain, or extract large ConfigMaps/Secrets to raw manifests managed by GitOps.</li>
        <li><strong>Render failed:</strong> Check missing <code>--globals</code> files (nil pointer) or run <code>helm dependency update</code> for missing sub-charts.</li>
        <li><strong>Near limit:</strong> Trim redundant values (see §4) and add <code>.helmignore</code> (see §8).</li>
      </ul>
    </div>
  </div>
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
    status = "over-limit" if "OVER" in flag else ("warning" if "⚠" in flag else "ok")
    flag_html = f"<span class='badge err'>{flag.strip()}</span>" if "OVER" in flag else (f"<span class='badge warn'>{flag.strip()}</span>" if flag.strip() else "")
    html_rows += f"<tr class='{css}' data-status='{status}'><td>{chart_name}</td><td><span class='badge muted'>{kind}</span></td><td style='font-family:var(--mono);font-size:.75rem'>{label}</td><td data-val='{sz}'>{h}</td><td>{flag_html}</td></tr>"

# write partial HTML to stdout marker
print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

done | tee /tmp/helm-scan-res-raw.txt | grep -v "__HTML_ROWS__" || true

# extract html rows
RES_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' -- \
  /tmp/helm-scan-res-raw.txt | tr -d '\n' || true)

html_section "
<section id='sec3'>
  <div class='section-header'>
    <span class='section-num'>3</span>
    <h2>Largest Rendered Resources</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Top 15 resources by JSON-serialized size per chart. Secrets over <strong>1 MB</strong> will be rejected by Kubernetes. Secrets over <strong>${WARN_RATIO}% of 1 MB</strong> are flagged.</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl3'>
      <input type='search' placeholder='Filter by chart, kind, name…'>
      <button class='filter-btn active' data-status='all'>All</button>
      <button class='filter-btn' data-status='over-limit'>Secret Over Limit</button>
      <button class='filter-btn' data-status='warning'>Secret Warning</button>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl3'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>Kind<span class='sort-icon'></span></th>
          <th data-col='2'>Name<span class='sort-icon'></span></th>
          <th data-col='3'>Size<span class='sort-icon'></span></th>
          <th data-col='4'>Flag<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$RES_ROWS</tbody>
      </table>
    </div>
    <div class='tip-box'>
      <div class='tip-title'>💡 Remediation</div>
      <ul>
        <li><strong>Secret over 1 MB:</strong> Move to an external secret manager (External Secrets Operator, Vault, AWS Secrets Manager) or split into multiple scoped Secrets.</li>
        <li><strong>Large ConfigMap:</strong> Mount from a volume or external store rather than embedding in the chart.</li>
      </ul>
    </div>
  </div>
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
import sys, os, yaml

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

override_file = os.path.basename(override_path)
html_rows = ""
for k, v in redundant[:30]:
    val_str = str(v)[:80]
    print(f"      {k} = {val_str}")
    html_rows += f"<tr data-status='warning'><td>{chart_name}</td><td><span class='badge muted'>{override_file}</span></td><td style='font-family:var(--mono);font-size:.75rem;color:var(--yellow)'>{k}</td><td style='font-family:var(--mono);font-size:.72rem;color:var(--muted)'>{val_str}</td></tr>"

print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

  done < <(find "$chart_dir" -maxdepth 2 -name "values*.yaml" | sort)
done | tee /tmp/helm-scan-redundant-raw.txt | grep -v "__HTML_ROWS__" || true

REDUNDANT_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' -- \
  /tmp/helm-scan-redundant-raw.txt | tr -d '\n' || true)

html_section "
<section id='sec4'>
  <div class='section-header'>
    <span class='section-num'>4</span>
    <h2>Redundant Values</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Keys in your override files whose value is <strong>identical to the chart default</strong>. Safe to delete — they add size without changing behaviour.</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl4'>
      <input type='search' placeholder='Filter by chart or key…'>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl4'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>File<span class='sort-icon'></span></th>
          <th data-col='2'>Key<span class='sort-icon'></span></th>
          <th data-col='3'>Value (same as default)<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$REDUNDANT_ROWS</tbody>
      </table>
    </div>
  </div>
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
    html_rows += f"<tr data-status='warning'><td>{chart_name}</td><td style='font-family:var(--mono);font-size:.75rem;color:var(--yellow)'>.Values.{k}</td></tr>"

print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF

done | tee /tmp/helm-scan-unused-raw.txt | grep -v "__HTML_ROWS__" || true

UNUSED_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' -- \
  /tmp/helm-scan-unused-raw.txt | tr -d '\n' || true)

html_section "
<section id='sec5'>
  <div class='section-header'>
    <span class='section-num'>5</span>
    <h2>Unused Values</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Keys defined in <code>values.yaml</code> with no reference found in any template. Candidates for removal — verify manually before deleting (may be used by sub-chart dependencies).</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl5'>
      <input type='search' placeholder='Filter by chart or key…'>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl5'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>Key<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$UNUSED_ROWS</tbody>
      </table>
    </div>
  </div>
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
  python3 - "${ALL_VALUES_FILES[@]}" <<'PYEOF' | tee /tmp/helm-scan-dup-raw.txt | grep -v "__HTML_ROWS__" || true
import sys, os, yaml
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
html_rows = ""
for kv, sources in sorted(dupes.items(), key=lambda x: -len(x[1]))[:30]:
    k, _, v = kv.partition("=")
    print(f"  {k} = {v[:60]}")
    for s in sources:
        print(f"      {s}")
    srcs_html = " ".join(f"<span class='badge muted'>{os.path.basename(s)}</span>" for s in sources)
    html_rows += f"<tr data-status='warning'><td style='font-family:var(--mono);font-size:.75rem;color:var(--yellow)'>{k}</td><td style='font-family:var(--mono);font-size:.72rem;color:var(--muted)'>{v[:80]}</td><td>{len(sources)}</td><td>{srcs_html}</td></tr>"
print(f"__HTML_ROWS__{html_rows}__END_HTML_ROWS__")
PYEOF
fi

DUP_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' -- \
  /tmp/helm-scan-dup-raw.txt | tr -d '\n' 2>/dev/null || true)

html_section "
<section id='sec6'>
  <div class='section-header'>
    <span class='section-num'>6</span>
    <h2>Duplicate Values Across Charts</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Key=value pairs that appear identically in multiple charts. Hoist into a shared <code>global:</code> block or a repo-level values file to eliminate duplication.</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl6'>
      <input type='search' placeholder='Filter by key or value…'>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl6'>
        <thead><tr>
          <th data-col='0'>Key<span class='sort-icon'></span></th>
          <th data-col='1'>Value<span class='sort-icon'></span></th>
          <th data-col='2'># Charts<span class='sort-icon'></span></th>
          <th data-col='3'>Found In<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$DUP_ROWS</tbody>
      </table>
    </div>
  </div>
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
  DIR_ROWS+="<tr class='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')' data-status='$(echo $tag | tr ' ' '-' | tr '[:upper:]' '[:lower:]')'>"
  bar_cls="ok"
  [[ "$tag" == "WARNING" ]] && bar_cls="warn"
  [[ "$tag" == "OVER LIMIT" ]] && bar_cls="err"
  badge_cls="ok"
  [[ "$tag" == "WARNING" ]] && badge_cls="warn"
  [[ "$tag" == "OVER LIMIT" ]] && badge_cls="err"
  DIR_ROWS+="<td>$name</td><td data-val='$sz'>$h</td>"
  DIR_ROWS+="<td><div class='bar-wrap'><div class='bar-track'><div class='bar-fill $bar_cls' style='width:${pct}%'></div></div><span class='bar-label'>$pct%</span></div></td>"
  DIR_ROWS+="<td><span class='badge $badge_cls'>$tag</span></td></tr>"
done

html_section "
<section id='sec7'>
  <div class='section-header'>
    <span class='section-num'>7</span>
    <h2>Chart Directory Sizes</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'>Raw disk size of each chart directory — a fast pre-package estimate before <code>helm package</code> runs. Does not account for <code>.helmignore</code> exclusions.</div>
  <div class='section-body'>
    <div class='filter-bar' data-table='tbl7'>
      <input type='search' placeholder='Filter charts…'>
      <button class='filter-btn active' data-status='all'>All</button>
      <button class='filter-btn' data-status='over-limit'>Over Limit</button>
      <button class='filter-btn' data-status='warning'>Warning</button>
      <button class='filter-btn' data-status='ok'>OK</button>
      <span class='row-count'></span>
    </div>
    <div class='table-wrap'>
      <table id='tbl7'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>Dir Size<span class='sort-icon'></span></th>
          <th data-col='2'>% of 5 MB<span class='sort-icon'></span></th>
          <th data-col='3'>Status<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$DIR_ROWS</tbody>
      </table>
    </div>
  </div>
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
    IGNORE_ROWS+="<tr class='ok' data-status='ok'><td>$name</td><td><span class='badge ok'>Present</span></td><td>$sz</td></tr>"
  else
    printf "  ${YEL}%-40s  .helmignore MISSING${RST}\n" "$name"
    IGNORE_ROWS+="<tr class='warning' data-status='warning'><td>$name</td><td><span class='badge warn'>Missing</span></td><td>—</td></tr>"
  fi
done

RECOMMENDED_IGNORE='*.md\n*.txt\nCHANGELOG\ntests/\ntest/\nci/\n.github/\n.git/\n*.orig\n*.bak'
echo
echo "  Recommended .helmignore entries:"
printf "  %b\n" "$RECOMMENDED_IGNORE" | sed 's/^/    /'

html_section "
<section id='sec8'>
  <div class='section-header'>
    <span class='section-num'>8</span>
    <h2>.helmignore Audit</h2>
    <span class='collapse-icon'>▶</span>
  </div>
  <div class='section-desc'><code>.helmignore</code> must exist in <strong>each chart root</strong> — it is not inherited. Missing files mean docs, tests, and CI artifacts inflate package size unnecessarily.</div>
  <div class='section-body'>
    <div class='table-wrap'>
      <table id='tbl8'>
        <thead><tr>
          <th data-col='0'>Chart<span class='sort-icon'></span></th>
          <th data-col='1'>Status<span class='sort-icon'></span></th>
          <th data-col='2'>Lines<span class='sort-icon'></span></th>
        </tr></thead>
        <tbody>$IGNORE_ROWS</tbody>
      </table>
    </div>
    <div class='tip-box'>
      <div class='tip-title'>💡 Recommended .helmignore entries</div>
      <ul>
        <li><code>*.md</code> &nbsp;<code>*.txt</code> &nbsp;<code>CHANGELOG</code> — documentation</li>
        <li><code>tests/</code> &nbsp;<code>test/</code> — test fixtures</li>
        <li><code>ci/</code> &nbsp;<code>.github/</code> &nbsp;<code>.git/</code> — CI and VCS metadata</li>
        <li><code>*.orig</code> &nbsp;<code>*.bak</code> — editor artifacts</li>
      </ul>
    </div>
  </div>
</section>"

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

  # ── compute summary counts for the dashboard ────────────────────────────────
  TOTAL_CHARTS=${#CHARTS[@]}
  OVER_LIMIT_COUNT=0
  WARN_COUNT=0
  OK_COUNT=0
  SECRET_WARN_COUNT=0
  MISSING_IGNORE_COUNT=0

  for c in "${CHARTS[@]}"; do
    chart_dir=$(dirname "$c")
    TMP_RENDER="${CHART_RENDER_PATH[$chart_dir]:-}"
    if [[ -n "$TMP_RENDER" && -s "$TMP_RENDER" ]]; then
      sz=$(wc -c <"$TMP_RENDER")
      pct=$((sz * 100 / HELM_LIMIT))
      if ((sz > HELM_LIMIT)); then
        ((OVER_LIMIT_COUNT++)) || true
      elif ((pct > WARN_RATIO)); then
        ((WARN_COUNT++)) || true
      else
        ((OK_COUNT++)) || true
      fi
      # check for large secrets
      secret_issues=$(python3 -c "
import sys, yaml, json
try:
    with open('$TMP_RENDER') as f:
        docs = [d for d in yaml.safe_load_all(f.read().replace('\t','  ')) if d]
    count = sum(1 for d in docs if d.get('kind')=='Secret' and len(json.dumps(d).encode()) > int($SECRET_LIMIT * $WARN_RATIO / 100))
    print(count)
except: print(0)
" 2>/dev/null || echo 0)
      ((SECRET_WARN_COUNT += secret_issues)) || true
    else
      ((OVER_LIMIT_COUNT++)) || true
    fi
    [[ ! -f "$chart_dir/.helmignore" ]] && ((MISSING_IGNORE_COUNT++)) || true
  done

  TOTAL_ISSUES=$((OVER_LIMIT_COUNT + WARN_COUNT + SECRET_WARN_COUNT + MISSING_IGNORE_COUNT))

  {
    cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Helm Repo Scan Report</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&family=JetBrains+Mono:wght@400;500&display=swap');

  :root {
    --bg:        #090c10;
    --surface:   #0d1117;
    --surface2:  #161b22;
    --surface3:  #1c2128;
    --border:    #30363d;
    --border2:   #21262d;
    --text:      #e6edf3;
    --muted:     #7d8590;
    --muted2:    #484f58;
    --red:       #f85149;
    --red-dim:   rgba(248,81,73,.12);
    --yellow:    #e3b341;
    --yellow-dim:rgba(227,179,65,.12);
    --green:     #3fb950;
    --green-dim: rgba(63,185,80,.12);
    --blue:      #58a6ff;
    --blue-dim:  rgba(88,166,255,.1);
    --purple:    #bc8cff;
    --nav-w:     220px;
    --font:      'Inter', system-ui, sans-serif;
    --mono:      'JetBrains Mono', 'Fira Code', monospace;
    --radius:    6px;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--font);
    font-size: 13px;
    line-height: 1.6;
    display: flex;
    min-height: 100vh;
  }

  /* ── NAV ── */
  nav {
    position: fixed; top: 0; left: 0; bottom: 0;
    width: var(--nav-w);
    background: var(--surface);
    border-right: 1px solid var(--border);
    display: flex; flex-direction: column;
    overflow-y: auto; z-index: 100;
    padding-bottom: 2rem;
  }
  .nav-header {
    padding: 1.25rem 1rem 1rem;
    border-bottom: 1px solid var(--border);
    position: sticky; top: 0;
    background: var(--surface);
    z-index: 1;
  }
  .nav-header .logo { font-size: 1.1rem; font-weight: 600; color: var(--blue); letter-spacing: -.01em; }
  .nav-header .repo { font-family: var(--mono); font-size: .68rem; color: var(--muted); margin-top: .2rem;
                      overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .nav-section-label {
    font-size: .65rem; font-weight: 600; text-transform: uppercase; letter-spacing: .08em;
    color: var(--muted2); padding: 1.1rem 1rem .3rem;
  }
  nav a {
    display: flex; align-items: center; gap: .5rem;
    padding: .38rem 1rem; text-decoration: none;
    color: var(--muted); font-size: .8rem;
    border-left: 2px solid transparent;
    transition: all .15s;
  }
  nav a:hover { color: var(--text); background: var(--surface2); }
  nav a.active { color: var(--blue); border-left-color: var(--blue); background: var(--blue-dim); }
  nav a .nav-badge {
    margin-left: auto; font-size: .65rem; font-family: var(--mono);
    padding: .1rem .35rem; border-radius: 99px;
  }
  nav a .nav-badge.err  { background: var(--red-dim);    color: var(--red); }
  nav a .nav-badge.warn { background: var(--yellow-dim); color: var(--yellow); }
  nav a .nav-badge.ok   { background: var(--green-dim);  color: var(--green); }

  /* ── MAIN ── */
  main {
    margin-left: var(--nav-w);
    flex: 1;
    padding: 2rem 2.5rem;
    max-width: 1100px;
  }

  /* ── PAGE HEADER ── */
  .page-header { margin-bottom: 2rem; }
  .page-header h1 { font-size: 1.4rem; font-weight: 600; color: var(--text); letter-spacing: -.02em; }
  .page-header .meta {
    font-family: var(--mono); font-size: .72rem; color: var(--muted); margin-top: .3rem;
    display: flex; gap: 1.5rem;
  }
  .page-header .meta span::before { content: ''; }

  /* ── DASHBOARD CARDS ── */
  .dashboard {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: .75rem;
    margin-bottom: 2.5rem;
  }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 1rem;
    display: flex; flex-direction: column; gap: .3rem;
  }
  .card .card-label { font-size: .7rem; color: var(--muted); text-transform: uppercase;
                      letter-spacing: .06em; font-weight: 500; }
  .card .card-value { font-size: 2rem; font-weight: 600; line-height: 1; font-family: var(--mono); }
  .card .card-sub   { font-size: .7rem; color: var(--muted); }
  .card.red    { border-color: var(--red);    background: var(--red-dim); }
  .card.yellow { border-color: var(--yellow); background: var(--yellow-dim); }
  .card.green  { border-color: var(--green);  background: var(--green-dim); }
  .card.blue   { border-color: var(--blue);   background: var(--blue-dim); }
  .card.red    .card-value { color: var(--red); }
  .card.yellow .card-value { color: var(--yellow); }
  .card.green  .card-value { color: var(--green); }
  .card.blue   .card-value { color: var(--blue); }

  /* ── SECTIONS ── */
  section { margin-bottom: 3rem; scroll-margin-top: 1.5rem; }
  .section-header {
    display: flex; align-items: center; gap: .75rem;
    margin-bottom: 1rem; cursor: pointer; user-select: none;
  }
  .section-header h2 {
    font-size: .95rem; font-weight: 600; color: var(--text);
    flex: 1;
  }
  .section-header .section-num {
    font-family: var(--mono); font-size: .7rem; color: var(--muted);
    background: var(--surface2); border: 1px solid var(--border);
    padding: .15rem .5rem; border-radius: 99px;
  }
  .section-header .collapse-icon {
    font-size: .75rem; color: var(--muted); transition: transform .2s;
  }
  .section-header .collapse-icon.open { transform: rotate(90deg); }
  .section-desc {
    font-size: .78rem; color: var(--muted); margin-bottom: .85rem; line-height: 1.5;
    padding: .6rem .85rem;
    background: var(--surface2); border-left: 3px solid var(--border);
    border-radius: 0 var(--radius) var(--radius) 0;
  }
  .section-desc strong { color: var(--text); }
  .section-body { overflow: hidden; }

  /* ── TABLES ── */
  .table-wrap { overflow-x: auto; border-radius: var(--radius); border: 1px solid var(--border); }
  table { width: 100%; border-collapse: collapse; font-family: var(--mono); font-size: .76rem; }
  thead { position: sticky; top: 0; z-index: 2; }
  th {
    background: var(--surface2); color: var(--muted);
    padding: .5rem .85rem; text-align: left;
    border-bottom: 1px solid var(--border); font-weight: 500;
    font-size: .7rem; text-transform: uppercase; letter-spacing: .05em;
    cursor: pointer; white-space: nowrap; user-select: none;
  }
  th:hover { color: var(--text); }
  th .sort-icon { margin-left: .3rem; opacity: .4; }
  th.sorted-asc  .sort-icon::after { content: ' ▲'; opacity: 1; }
  th.sorted-desc .sort-icon::after { content: ' ▼'; opacity: 1; }
  th:not(.sorted-asc):not(.sorted-desc) .sort-icon::after { content: ' ⇅'; }
  td {
    padding: .45rem .85rem; border-bottom: 1px solid var(--border2);
    vertical-align: middle; color: var(--text);
  }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: var(--surface2); }

  /* row status colours */
  tr.over-limit td:first-child { border-left: 3px solid var(--red); }
  tr.warning    td:first-child { border-left: 3px solid var(--yellow); }
  tr.ok         td:first-child { border-left: 3px solid var(--green); }
  tr.error      td:first-child { border-left: 3px solid var(--muted2); }

  /* ── BADGES ── */
  .badge {
    display: inline-flex; align-items: center;
    padding: .15rem .5rem; border-radius: 99px;
    font-size: .68rem; font-weight: 500; font-family: var(--mono);
    white-space: nowrap;
  }
  .badge.err  { background: var(--red-dim);    color: var(--red);    border: 1px solid var(--red); }
  .badge.warn { background: var(--yellow-dim); color: var(--yellow); border: 1px solid var(--yellow); }
  .badge.ok   { background: var(--green-dim);  color: var(--green);  border: 1px solid var(--green); }
  .badge.info { background: var(--blue-dim);   color: var(--blue);   border: 1px solid var(--blue); }
  .badge.muted{ background: var(--surface3);   color: var(--muted);  border: 1px solid var(--border); }

  /* ── PROGRESS BAR ── */
  .bar-wrap { display: flex; align-items: center; gap: .6rem; min-width: 140px; }
  .bar-track {
    flex: 1; height: 6px; background: var(--surface3);
    border-radius: 99px; overflow: hidden;
  }
  .bar-fill { height: 100%; border-radius: 99px; transition: width .3s; }
  .bar-fill.ok   { background: var(--green); }
  .bar-fill.warn { background: var(--yellow); }
  .bar-fill.err  { background: var(--red); }
  .bar-label { font-size: .7rem; color: var(--muted); white-space: nowrap; }

  /* ── FILTER BAR ── */
  .filter-bar {
    display: flex; gap: .5rem; margin-bottom: .75rem; flex-wrap: wrap; align-items: center;
  }
  .filter-bar input[type=search] {
    background: var(--surface2); border: 1px solid var(--border);
    color: var(--text); font-family: var(--mono); font-size: .76rem;
    padding: .35rem .7rem; border-radius: var(--radius); outline: none;
    width: 220px;
  }
  .filter-bar input[type=search]:focus { border-color: var(--blue); }
  .filter-btn {
    background: var(--surface2); border: 1px solid var(--border);
    color: var(--muted); font-size: .72rem; padding: .3rem .7rem;
    border-radius: var(--radius); cursor: pointer; font-family: var(--font);
  }
  .filter-btn:hover { color: var(--text); border-color: var(--muted); }
  .filter-btn.active { color: var(--blue); border-color: var(--blue); background: var(--blue-dim); }
  .row-count { font-size: .7rem; color: var(--muted); margin-left: auto; }

  /* ── TIPS BOX ── */
  .tip-box {
    background: var(--surface2); border: 1px solid var(--border);
    border-radius: var(--radius); padding: .85rem 1rem;
    margin-top: .85rem;
  }
  .tip-box .tip-title { font-size: .72rem; font-weight: 600; color: var(--blue);
                        text-transform: uppercase; letter-spacing: .06em; margin-bottom: .5rem; }
  .tip-box ul { padding-left: 1.2rem; }
  .tip-box li { font-size: .77rem; color: var(--muted); line-height: 1.7; }
  .tip-box li strong { color: var(--text); }
  .tip-box code {
    background: var(--surface3); border: 1px solid var(--border);
    border-radius: 3px; padding: .1rem .35rem;
    font-family: var(--mono); font-size: .72rem; color: var(--purple);
  }

  /* ── SCROLLBAR ── */
  ::-webkit-scrollbar { width: 6px; height: 6px; }
  ::-webkit-scrollbar-track { background: var(--surface); }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  ::-webkit-scrollbar-thumb:hover { background: var(--muted2); }

  /* ── EMPTY STATE ── */
  .empty { text-align: center; padding: 2rem; color: var(--muted); font-size: .82rem; }

  /* ── TOOLTIP ── */
  [data-tip] { position: relative; cursor: help; }
  [data-tip]::after {
    content: attr(data-tip);
    position: absolute; bottom: calc(100% + 6px); left: 50%; transform: translateX(-50%);
    background: var(--surface3); border: 1px solid var(--border);
    color: var(--text); font-size: .7rem; padding: .3rem .6rem;
    border-radius: var(--radius); white-space: nowrap; pointer-events: none;
    opacity: 0; transition: opacity .15s; z-index: 999;
  }
  [data-tip]:hover::after { opacity: 1; }
</style>
</head>
<body>
HTML_HEAD

    # ── NAV ────────────────────────────────────────────────────────────────────
    cat <<NAVEOF
<nav>
  <div class="nav-header">
    <div class="logo">⎈ Helm Scan</div>
    <div class="repo">$REPO_ROOT</div>
  </div>
  <div class="nav-section-label">Overview</div>
  <a href="#dashboard">Dashboard</a>
  <div class="nav-section-label">Sections</div>
  <a href="#sec0">0 · Global Values</a>
  <a href="#sec1">1 · Charts</a>
  <a href="#sec2">2 · Rendered Sizes</a>
  <a href="#sec3">3 · Largest Resources</a>
  <a href="#sec4">4 · Redundant Values</a>
  <a href="#sec5">5 · Unused Values</a>
  <a href="#sec6">6 · Cross-chart Dupes</a>
  <a href="#sec7">7 · Dir Sizes</a>
  <a href="#sec8">8 · .helmignore</a>
</nav>
NAVEOF

    # ── PAGE HEADER + DASHBOARD ────────────────────────────────────────────────
    echo "<main>"
    echo "<div class='page-header'>"
    echo "  <h1>Helm Repository Scan Report</h1>"
    echo "  <div class='meta'>"
    echo "    <span>Generated: $(date -u '+%Y-%m-%d %H:%M UTC')</span>"
    echo "    <span>Repo: <code style='font-family:var(--mono);font-size:.72rem;color:var(--purple)'>$REPO_ROOT</code></span>"
    echo "    <span>Charts: $TOTAL_CHARTS</span>"
    echo "  </div>"
    echo "</div>"

    # dashboard cards
    echo "<div id='dashboard' class='dashboard'>"
    echo "  <div class='card blue'><div class='card-label'>Charts Scanned</div><div class='card-value'>$TOTAL_CHARTS</div><div class='card-sub'>in repo</div></div>"

    if ((OVER_LIMIT_COUNT > 0)); then
      echo "  <div class='card red'><div class='card-label'>Over Limit</div><div class='card-value'>$OVER_LIMIT_COUNT</div><div class='card-sub'>exceed 5 MB</div></div>"
    else
      echo "  <div class='card green'><div class='card-label'>Over Limit</div><div class='card-value'>0</div><div class='card-sub'>none exceed 5 MB</div></div>"
    fi

    if ((WARN_COUNT > 0)); then
      echo "  <div class='card yellow'><div class='card-label'>Near Limit</div><div class='card-value'>$WARN_COUNT</div><div class='card-sub'>&gt;${WARN_RATIO}% of 5 MB</div></div>"
    else
      echo "  <div class='card green'><div class='card-label'>Near Limit</div><div class='card-value'>0</div><div class='card-sub'>all under ${WARN_RATIO}%</div></div>"
    fi

    if ((SECRET_WARN_COUNT > 0)); then
      echo "  <div class='card red'><div class='card-label'>Secret Issues</div><div class='card-value'>$SECRET_WARN_COUNT</div><div class='card-sub'>near/over 1 MB</div></div>"
    else
      echo "  <div class='card green'><div class='card-label'>Secret Issues</div><div class='card-value'>0</div><div class='card-sub'>all secrets ok</div></div>"
    fi

    if ((MISSING_IGNORE_COUNT > 0)); then
      echo "  <div class='card yellow'><div class='card-label'>Missing .helmignore</div><div class='card-value'>$MISSING_IGNORE_COUNT</div><div class='card-sub'>charts affected</div></div>"
    else
      echo "  <div class='card green'><div class='card-label'>Missing .helmignore</div><div class='card-value'>0</div><div class='card-sub'>all charts covered</div></div>"
    fi

    echo "  <div class='card'><div class='card-label'>Total Issues</div><div class='card-value' style='color:var(--text)'>$TOTAL_ISSUES</div><div class='card-sub'>across all checks</div></div>"
    echo "</div>"

    # ── SECTIONS ───────────────────────────────────────────────────────────────
    for section in "${HTML_SECTIONS[@]}"; do echo "$section"; done

    cat <<'HTML_FOOT'
</main>

<script>
// ── Active nav link on scroll ──────────────────────────────────────────────
const sections = document.querySelectorAll('section[id]');
const navLinks  = document.querySelectorAll('nav a[href^="#"]');
const observer  = new IntersectionObserver(entries => {
  entries.forEach(e => {
    if (e.isIntersecting) {
      navLinks.forEach(a => a.classList.toggle('active', a.getAttribute('href') === '#' + e.target.id));
    }
  });
}, { rootMargin: '-20% 0px -70% 0px' });
sections.forEach(s => observer.observe(s));

// ── Collapsible sections ───────────────────────────────────────────────────
document.querySelectorAll('.section-header').forEach(hdr => {
  const body = hdr.nextElementSibling?.classList.contains('section-desc')
    ? hdr.nextElementSibling.nextElementSibling
    : hdr.nextElementSibling;
  const icon = hdr.querySelector('.collapse-icon');
  if (!body) return;
  icon.classList.add('open');
  hdr.addEventListener('click', () => {
    const open = icon.classList.toggle('open');
    body.style.display = open ? '' : 'none';
    if (hdr.nextElementSibling?.classList.contains('section-desc'))
      hdr.nextElementSibling.style.display = open ? '' : 'none';
  });
});

// ── Sortable tables ────────────────────────────────────────────────────────
document.querySelectorAll('th[data-col]').forEach(th => {
  th.innerHTML += '<span class="sort-icon"></span>';
  th.addEventListener('click', () => {
    const table = th.closest('table');
    const tbody = table.querySelector('tbody');
    const col   = parseInt(th.dataset.col);
    const asc   = !th.classList.contains('sorted-asc');
    table.querySelectorAll('th').forEach(t => t.classList.remove('sorted-asc','sorted-desc'));
    th.classList.add(asc ? 'sorted-asc' : 'sorted-desc');
    const rows = [...tbody.querySelectorAll('tr')];
    rows.sort((a, b) => {
      const av = a.cells[col]?.dataset.val ?? a.cells[col]?.textContent ?? '';
      const bv = b.cells[col]?.dataset.val ?? b.cells[col]?.textContent ?? '';
      const an = parseFloat(av), bn = parseFloat(bv);
      return (isNaN(an) || isNaN(bn))
        ? (asc ? av.localeCompare(bv) : bv.localeCompare(av))
        : (asc ? an - bn : bn - an);
    });
    rows.forEach(r => tbody.appendChild(r));
  });
});

// ── Per-table search + status filter ──────────────────────────────────────
document.querySelectorAll('.filter-bar').forEach(bar => {
  const tableId = bar.dataset.table;
  const tbody   = document.querySelector(`#${tableId} tbody`);
  if (!tbody) return;
  const countEl = bar.querySelector('.row-count');
  const search  = bar.querySelector('input[type=search]');
  const btns    = bar.querySelectorAll('.filter-btn[data-status]');
  let activeStatus = 'all';

  function applyFilters() {
    const q = search?.value.toLowerCase() ?? '';
    let visible = 0;
    tbody.querySelectorAll('tr').forEach(row => {
      const text   = row.textContent.toLowerCase();
      const status = row.dataset.status ?? '';
      const matchQ = !q || text.includes(q);
      const matchS = activeStatus === 'all' || status === activeStatus;
      row.style.display = matchQ && matchS ? '' : 'none';
      if (matchQ && matchS) visible++;
    });
    if (countEl) countEl.textContent = `${visible} row${visible !== 1 ? 's' : ''}`;
  }

  search?.addEventListener('input', applyFilters);
  btns.forEach(btn => {
    btn.addEventListener('click', () => {
      btns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      activeStatus = btn.dataset.status;
      applyFilters();
    });
  });
  applyFilters();
});
</script>
</body></html>
HTML_FOOT

  } >helm-scan-report.html
  echo
  echo "  → HTML report written to: helm-scan-report.html"
fi

# =============================================================================
# CLEANUP TEMP FILES
# =============================================================================
for c in "${CHARTS[@]}"; do
  chart_dir=$(dirname "$c")
  tmp="${CHART_RENDER_PATH[$chart_dir]:-}"
  [[ -n "$tmp" && -f "$tmp" ]] && rm -f "$tmp"
done
rm -f /tmp/helm-scan-res-raw.txt /tmp/helm-scan-redundant-raw.txt \
  /tmp/helm-scan-unused-raw.txt /tmp/helm-scan-dup-raw.txt
