#!/usr/bin/env bash
# =============================================================================
# helm-scan.sh — Umbrella chart size, duplication & template analyser
#
# Usage:
#   ./helm-scan.sh <UMBRELLA_CHART_DIR> [OPTIONS]
#
# Options:
#   --html                  Emit helm-scan-report.html in current directory
#   --skip-dep-update       Skip helm dependency update
#   --globals FILE          Extra values file prepended to helm template (repeatable)
#   --values FILE           Additional values override file (repeatable)
#   --out FILE              Custom HTML output path (default: helm-scan-report.html)
# =============================================================================
set -uo pipefail

# =============================================================================
# ARG PARSING
# =============================================================================
UMBRELLA=""
EMIT_HTML=false
SKIP_DEP_UPDATE=false
EXPLICIT_GLOBALS=()
EXTRA_VALUES=()
HTML_OUT="helm-scan-report.html"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <UMBRELLA_CHART_DIR> [--html] [--skip-dep-update] [--globals FILE] [--values FILE] [--out FILE]"
  exit 1
fi

i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
  --html) EMIT_HTML=true ;;
  --skip-dep-update) SKIP_DEP_UPDATE=true ;;
  --globals)
    i=$((i + 1))
    [[ $i -le $# ]] && EXPLICIT_GLOBALS+=("${!i}")
    ;;
  --values)
    i=$((i + 1))
    [[ $i -le $# ]] && EXTRA_VALUES+=("${!i}")
    ;;
  --out)
    i=$((i + 1))
    [[ $i -le $# ]] && HTML_OUT="${!i}"
    ;;
  -*)
    echo "Unknown flag: $arg"
    exit 1
    ;;
  *) [[ -z "$UMBRELLA" ]] && UMBRELLA="$arg" ;;
  esac
  i=$((i + 1))
done

if [[ -z "$UMBRELLA" || ! -f "$UMBRELLA/Chart.yaml" ]]; then
  echo "ERROR: '$UMBRELLA' is not a valid chart directory (no Chart.yaml found)"
  exit 1
fi
UMBRELLA=$(realpath "$UMBRELLA")

# =============================================================================
# HELPERS
# =============================================================================
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
need() { command -v "$1" &>/dev/null || {
  echo "ERROR: '$1' not found"
  exit 1
}; }
need helm
need yq
need python3

human_bytes() {
  python3 -c "
v=$1
for u in ['B','KB','MB']:
    if v < 1024 or u=='MB': print(f'{v:.1f} {u}'); break
    v /= 1024
"
}

HELM_LIMIT=$((5 * 1024 * 1024))
SECRET_LIMIT=$((1 * 1024 * 1024))
WARN_PCT=80

# Temp files
TMP_RENDER=$(mktemp /tmp/helm-scan-render-XXXX.yaml)
TMP_PY=$(mktemp /tmp/helm-scan-py-XXXX.txt)
trap 'rm -f "$TMP_RENDER" "$TMP_PY"' EXIT

# =============================================================================
# 1. UMBRELLA OVERVIEW
# =============================================================================
hdr "1 · Umbrella chart overview"

UMBRELLA_NAME=$(yq '.name' "$UMBRELLA/Chart.yaml" 2>/dev/null || basename "$UMBRELLA")
UMBRELLA_VER=$(yq '.version' "$UMBRELLA/Chart.yaml" 2>/dev/null || echo "—")
UMBRELLA_TYPE=$(yq '.type // "application"' "$UMBRELLA/Chart.yaml" 2>/dev/null)
DEP_COUNT=$(yq '.dependencies | length' "$UMBRELLA/Chart.yaml" 2>/dev/null || echo 0)

printf "  Name    : ${BLD}%s${RST}\n" "$UMBRELLA_NAME"
printf "  Path    : %s\n" "$UMBRELLA"
printf "  Version : %s\n" "$UMBRELLA_VER"
printf "  Type    : %s\n" "$UMBRELLA_TYPE"
printf "  Declared dependencies: %s\n" "$DEP_COUNT"

SUBCHARTS_DIR="$UMBRELLA/charts"
SUBCHART_DIRS=()
if [[ -d "$SUBCHARTS_DIR" ]]; then
  while IFS= read -r sc; do
    SUBCHART_DIRS+=("$(dirname "$sc")")
  done < <(find "$SUBCHARTS_DIR" -mindepth 2 -maxdepth 2 -name "Chart.yaml" | sort)
fi

echo
printf "  Vendored sub-charts: %d\n" "${#SUBCHART_DIRS[@]}"
for sc in "${SUBCHART_DIRS[@]}"; do
  scname=$(yq '.name' "$sc/Chart.yaml" 2>/dev/null || basename "$sc")
  scver=$(yq '.version' "$sc/Chart.yaml" 2>/dev/null || echo "—")
  printf "    ${GRN}%-35s${RST}  %s\n" "$scname" "$scver"
done

# =============================================================================
# 2. DEPENDENCY UPDATE
# =============================================================================
if [[ "$SKIP_DEP_UPDATE" == false && "$DEP_COUNT" != "0" && "$DEP_COUNT" != "null" ]]; then
  hdr "2 · Resolving dependencies"
  if dep_out=$(helm dependency update "$UMBRELLA" 2>&1); then
    echo "  ${GRN}Dependencies updated successfully${RST}"
  else
    echo "  ${YEL}WARNING: dependency update had issues (continuing):${RST}"
    echo "$dep_out" | head -8 | sed 's/^/    /'
  fi
else
  hdr "2 · Dependencies"
  echo "  Skipped (--skip-dep-update or no dependencies declared)"
fi

# Re-discover after dep update
SUBCHART_DIRS=()
if [[ -d "$SUBCHARTS_DIR" ]]; then
  while IFS= read -r sc; do
    SUBCHART_DIRS+=("$(dirname "$sc")")
  done < <(find "$SUBCHARTS_DIR" -mindepth 2 -maxdepth 2 -name "Chart.yaml" | sort)
fi

# =============================================================================
# 3. SIZE BREAKDOWN
# =============================================================================
hdr "3 · Size breakdown"

dir_size() { du -sb "$1" 2>/dev/null | awk '{print $1}'; }
count_files() { find "$1" -type f -name "$2" 2>/dev/null | wc -l; }

UMB_TMPL_SIZE=$(find "$UMBRELLA/templates" -type f 2>/dev/null |
  xargs wc -c 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
[[ -z "$UMB_TMPL_SIZE" ]] && UMB_TMPL_SIZE=0

UMB_VALS_SIZE=0
for vf in "$UMBRELLA"/values*.yaml; do
  [[ -f "$vf" ]] && UMB_VALS_SIZE=$((UMB_VALS_SIZE + $(wc -c <"$vf"))) || true
done

UMB_TOTAL_SIZE=$(dir_size "$UMBRELLA")
[[ -z "$UMB_TOTAL_SIZE" ]] && UMB_TOTAL_SIZE=0

echo
printf "  ${BLD}%-38s  %10s  %8s  %8s  %8s${RST}\n" \
  "Component" "Dir Size" "Templates" "Values" "# Tmpls"
printf "  %s\n" "$(printf '─%.0s' {1..80})"

SIZE_ROWS=""

fmt_row() {
  local label="$1" dsize="$2" tsize="$3" vsize="$4" ntmpls="$5"
  local dh th vh
  dh=$(human_bytes "$dsize")
  th=$(human_bytes "$tsize")
  vh=$(human_bytes "$vsize")
  printf "  %-38s  %10s  %8s  %8s  %8s\n" "$label" "$dh" "$th" "$vh" "$ntmpls"
  local pct=$((dsize * 100 / HELM_LIMIT)) || true
  local bcls="ok"
  ((pct > WARN_PCT)) && bcls="warn" || true
  ((dsize > HELM_LIMIT)) && bcls="err" || true
  local badge_txt="${pct}% of 5MB"
  SIZE_ROWS+="<tr data-status='$bcls'>"
  SIZE_ROWS+="<td>$label</td>"
  SIZE_ROWS+="<td data-val='$dsize'><div class='bar-wrap'><div class='bar-track'><div class='bar-fill $bcls' style='width:${pct}%'></div></div><span class='bar-label'>$dh</span></div></td>"
  SIZE_ROWS+="<td>$th</td><td>$vh</td><td>$ntmpls</td>"
  SIZE_ROWS+="<td><span class='badge $bcls'>$badge_txt</span></td></tr>"
}

UMB_NTMPLS=$(count_files "$UMBRELLA/templates" "*.yaml")
fmt_row "⎈ $UMBRELLA_NAME (umbrella)" \
  "$UMB_TOTAL_SIZE" "$UMB_TMPL_SIZE" "$UMB_VALS_SIZE" "$UMB_NTMPLS"

for sc in "${SUBCHART_DIRS[@]}"; do
  scname=$(yq '.name' "$sc/Chart.yaml" 2>/dev/null || basename "$sc")
  sc_total=$(dir_size "$sc")
  [[ -z "$sc_total" ]] && sc_total=0
  sc_tmpl_size=$(find "$sc/templates" -type f 2>/dev/null |
    xargs wc -c 2>/dev/null | tail -1 | awk '{print $1}' || echo 0)
  [[ -z "$sc_tmpl_size" ]] && sc_tmpl_size=0
  sc_vals_size=0
  for vf in "$sc"/values*.yaml; do
    [[ -f "$vf" ]] && sc_vals_size=$((sc_vals_size + $(wc -c <"$vf"))) || true
  done
  sc_ntmpls=$(count_files "$sc/templates" "*.yaml")
  fmt_row "  ↳ $scname" "$sc_total" "$sc_tmpl_size" "$sc_vals_size" "$sc_ntmpls"
done

# =============================================================================
# 4. RENDER THE UMBRELLA
# =============================================================================
hdr "4 · Rendering umbrella chart"

VALUES_FLAGS=()
for vf in "$UMBRELLA"/values*.yaml; do [[ -f "$vf" ]] && VALUES_FLAGS+=(-f "$vf") || true; done
for gf in "${EXPLICIT_GLOBALS[@]}"; do [[ -f "$gf" ]] && VALUES_FLAGS+=(-f "$gf") || true; done
for vf in "${EXTRA_VALUES[@]}"; do [[ -f "$vf" ]] && VALUES_FLAGS+=(-f "$vf") || true; done

RENDER_OK=false
RENDER_BYTES=0
RENDER_H="0 B"
RENDER_PCT=0

if helm template "scan-release" "$UMBRELLA" "${VALUES_FLAGS[@]}" \
  --include-crds 2>/dev/null >"$TMP_RENDER"; then
  RENDER_BYTES=$(wc -c <"$TMP_RENDER")
  RENDER_H=$(human_bytes "$RENDER_BYTES")
  RENDER_PCT=$((RENDER_BYTES * 100 / HELM_LIMIT)) || true
  RENDER_OK=true
  if ((RENDER_BYTES > HELM_LIMIT)); then
    printf "  ${RED}Rendered size: %s  (%d%% — OVER 5 MB LIMIT)${RST}\n" "$RENDER_H" "$RENDER_PCT"
  elif ((RENDER_PCT > WARN_PCT)); then
    printf "  ${YEL}Rendered size: %s  (%d%% of 5 MB — WARNING)${RST}\n" "$RENDER_H" "$RENDER_PCT"
  else
    printf "  ${GRN}Rendered size: %s  (%d%% of 5 MB — OK)${RST}\n" "$RENDER_H" "$RENDER_PCT"
  fi
else
  RENDER_ERR=$(helm template "scan-release" "$UMBRELLA" "${VALUES_FLAGS[@]}" \
    --include-crds 2>&1 | head -8 || true)
  printf "  ${RED}Render failed:${RST}\n"
  echo "$RENDER_ERR" | sed 's/^/    /'
fi

RESOURCE_ROWS=""
if [[ "$RENDER_OK" == true ]]; then
  echo
  printf "  ${BLD}%-12s  %-40s  %10s  %s${RST}\n" "Kind" "Name" "Size" "Flag"
  printf "  %s\n" "$(printf '─%.0s' {1..75})"
  python3 - "$TMP_RENDER" "$SECRET_LIMIT" "$WARN_PCT" <<'PYEOF' | tee "$TMP_PY"
import sys, yaml, json
path, secret_limit, warn_pct = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f.read().replace('\t','  ')) if d]
except Exception as e:
    print(f"  Parse error: {e}"); sys.exit(0)

rows = []
for d in docs:
    kind = d.get('kind','?')
    name = d.get('metadata',{}).get('name','?')
    ns   = d.get('metadata',{}).get('namespace','')
    sz   = len(json.dumps(d).encode())
    rows.append((sz, kind, name, ns))

rows.sort(reverse=True)
html = ""
for sz, kind, name, ns in rows:
    h = f"{sz/1024:.1f}KB" if sz>=1024 else f"{sz}B"
    flag = ""; css = "ok"
    if kind == "Secret":
        pct = sz*100//secret_limit
        if sz > secret_limit:   flag="SECRET OVER 1MB"; css="err"
        elif pct > warn_pct:    flag=f"Secret {pct}% of 1MB"; css="warn"
    label = f"{ns}/{name}" if ns else name
    print(f"  {kind:<12}  {label:<40}  {h:>10}  {flag}")
    bcls = 'err' if css=='err' else ('warn' if css=='warn' else 'ok')
    badge = f"<span class='badge {bcls}'>{flag if flag else 'ok'}</span>"
    html += f"<tr data-status='{css}'><td><span class='badge muted'>{kind}</span></td><td>{label}</td><td data-val='{sz}'>{h}</td><td>{badge}</td></tr>"
print(f"__HTML_ROWS__{html}__END_HTML_ROWS__")
PYEOF
  RESOURCE_ROWS=$(grep -oP '(?<=__HTML_ROWS__).*(?=__END_HTML_ROWS__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
fi

# =============================================================================
# 5. VALUES ANALYSIS
# =============================================================================
hdr "5 · Values analysis"

ALL_VALUES=()
for vf in "$UMBRELLA"/values*.yaml; do [[ -f "$vf" ]] && ALL_VALUES+=("$vf") || true; done
for sc in "${SUBCHART_DIRS[@]}"; do
  for vf in "$sc"/values*.yaml; do [[ -f "$vf" ]] && ALL_VALUES+=("$vf") || true; done
done

DUPE_ROWS=""
REDUNDANT_ROWS=""

if [[ ${#ALL_VALUES[@]} -gt 0 ]]; then
  python3 - "${ALL_VALUES[@]}" <<'PYEOF' | tee "$TMP_PY" | grep -v '__HTML__' || true
import sys, os, yaml
from collections import defaultdict

files = sys.argv[1:]

def safe_load(p):
    try:
        with open(p) as f: return yaml.safe_load(f.read().replace('\t','  ')) or {}
    except: return {}

def flatten(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k,v in d.items(): out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
    elif isinstance(d, list):
        for i,v in enumerate(d): out.update(flatten(v, f"{prefix}[{i}]"))
    else: out[prefix] = d
    return out

print("\n  Values file summary:")
file_flats = {}
for fp in files:
    flat = flatten(safe_load(fp))
    file_flats[fp] = flat
    kb = os.path.getsize(fp)/1024
    print(f"    {os.path.relpath(fp):<55}  {len(flat):>4} keys  {kb:.1f} KB")

# cross-file duplicate key=value
kv_sources = defaultdict(list)
for fp, flat in file_flats.items():
    for k,v in flat.items():
        kv_sources[f"{k}||{v}"].append(fp)

dupes = [(k,v,srcs) for kv,srcs in kv_sources.items()
         for k,_,v in [kv.partition('||')] if len(srcs) > 1]
dupes.sort(key=lambda x: -len(x[2]))

print(f"\n  Duplicate key=value pairs: {len(dupes)}")
dup_html = ""
for k,v,srcs in dupes[:60]:
    val_str = str(v)[:70]
    src_names = ", ".join(os.path.basename(s) for s in srcs)
    print(f"    {k} = {val_str}  [{src_names}]")
    badges = " ".join(f"<span class='badge muted'>{os.path.basename(s)}</span>" for s in srcs)
    dup_html += f"<tr data-status='warn'><td class='mono hi-yellow'>{k}</td><td class='mono muted'>{val_str}</td><td>{len(srcs)}</td><td>{badges}</td></tr>"
print(f"__HTML_DUP__{dup_html}__END_HTML_DUP__")

# sub-chart keys redundant vs umbrella
if len(files) >= 2:
    umbrella_flat = file_flats[files[0]]
    redundant = []
    for fp in files[1:]:
        for k,v in file_flats[fp].items():
            if k in umbrella_flat and umbrella_flat[k] == v:
                redundant.append((k, v, fp))
    print(f"\n  Sub-chart keys redundant vs umbrella values: {len(redundant)}")
    red_html = ""
    for k,v,fp in redundant[:60]:
        val_str = str(v)[:70]
        print(f"    {os.path.relpath(fp)}  ->  {k} = {val_str}")
        red_html += f"<tr data-status='warn'><td class='mono muted'>{os.path.basename(fp)}</td><td class='mono hi-yellow'>{k}</td><td class='mono muted'>{val_str}</td></tr>"
    print(f"__HTML_RED__{red_html}__END_HTML_RED__")
PYEOF

  DUPE_ROWS=$(grep -oP '(?<=__HTML_DUP__).*(?=__END_HTML_DUP__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
  REDUNDANT_ROWS=$(grep -oP '(?<=__HTML_RED__).*(?=__END_HTML_RED__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
fi

# ── unused values ─────────────────────────────────────────────────────────────
hdr "5b · Unused values"

UNUSED_ROWS=""
for vf in "${ALL_VALUES[@]}"; do
  python3 - "$vf" "$UMBRELLA" <<'PYEOF' | tee -a "$TMP_PY" | grep -v '__HTML_UNUSED__\|__END_HTML_UNUSED__' || true
import sys, os, yaml, re

vf, umbrella = sys.argv[1], sys.argv[2]

def safe_load(p):
    try:
        with open(p) as f: return yaml.safe_load(f.read().replace('\t','  ')) or {}
    except: return {}

def flatten_keys(d, prefix=""):
    out = []
    if isinstance(d, dict):
        for k,v in d.items():
            full = f"{prefix}.{k}" if prefix else k
            out.append(full)
            out.extend(flatten_keys(v, full))
    return out

tmpl_text = ""
for root,_,files in os.walk(umbrella):
    for fn in files:
        if fn.endswith(('.yaml','.tpl')):
            try:
                with open(os.path.join(root,fn)) as f: tmpl_text += f.read()
            except: pass

vals = safe_load(vf)
unused = []
for key in flatten_keys(vals):
    leaf = key.split('.')[-1]
    if not (re.search(rf'\.Values\.{re.escape(key)}', tmpl_text) or
            re.search(rf'\b{re.escape(leaf)}\b', tmpl_text)):
        unused.append(key)

if unused:
    fname = os.path.relpath(vf)
    print(f"  {fname}: {len(unused)} unused keys")
    for k in unused[:30]: print(f"    .Values.{k}")
    html = "".join(
        f"<tr data-status='warn'><td class='mono muted'>{os.path.basename(vf)}</td>"
        f"<td class='mono hi-yellow'>.Values.{k}</td></tr>"
        for k in unused[:30])
    print(f"__HTML_UNUSED__{html}__END_HTML_UNUSED__")
PYEOF
done

UNUSED_ROWS=$(grep -oP '(?<=__HTML_UNUSED__).*(?=__END_HTML_UNUSED__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)

# =============================================================================
# 6. TEMPLATE ANALYSIS
# =============================================================================
hdr "6 · Template analysis"

python3 - "$UMBRELLA" <<'PYEOF' | tee "$TMP_PY" | grep -v '__HTML_' || true
import sys, os, re
from collections import defaultdict

umbrella = sys.argv[1]
subcharts_dir = os.path.join(umbrella, "charts")
umbrella_name = os.path.basename(umbrella)

def read_templates(base, chart_name, is_sub):
    results = []
    if not os.path.isdir(base): return results
    for root,_,files in os.walk(base):
        for fn in files:
            if not fn.endswith(('.yaml','.tpl')): continue
            fp = os.path.join(root, fn)
            try:
                with open(fp) as f: content = f.read()
                results.append((fp, content, os.path.getsize(fp), chart_name, is_sub))
            except: pass
    return results

all_templates = read_templates(os.path.join(umbrella,"templates"), umbrella_name, False)
if os.path.isdir(subcharts_dir):
    for entry in sorted(os.listdir(subcharts_dir)):
        sc = os.path.join(subcharts_dir, entry)
        if os.path.isfile(os.path.join(sc,"Chart.yaml")):
            all_templates += read_templates(os.path.join(sc,"templates"), entry, True)

# ── template sizes ────────────────────────────────────────────────────────────
print("\n  Template sizes (all):")
tmpl_html = ""
for fp, content, size, chart, is_sub in sorted(all_templates, key=lambda x: -x[2]):
    h = f"{size/1024:.1f}KB" if size >= 1024 else f"{size}B"
    flag = ""; css = "ok"
    if size > 50*1024:   flag="LARGE >50KB"; css="err"
    elif size > 20*1024: flag="BIG >20KB";   css="warn"
    rel = os.path.relpath(fp)
    print(f"    {h:>8}  {rel}  {flag}")
    bcls = 'info' if not is_sub else 'muted'
    badge = f"<span class='badge {'err' if css=='err' else 'warn' if css=='warn' else 'ok'}'>{flag if flag else 'ok'}</span>"
    tmpl_html += f"<tr data-status='{css}'><td><span class='badge {bcls}'>{chart}</span></td><td class='mono'>{os.path.basename(fp)}</td><td data-val='{size}'>{h}</td><td>{badge}</td></tr>"
print(f"__HTML_TMPL_SIZE__{tmpl_html}__END_HTML_TMPL_SIZE__")

# ── duplicate named template definitions ─────────────────────────────────────
define_re = re.compile(r'\{\{-?\s*define\s+"([^"]+)"\s*-?\}\}(.*?)\{\{-?\s*end\s*-?\}\}', re.DOTALL)
named_templates = defaultdict(list)
for fp, content, size, chart, is_sub in all_templates:
    for m in define_re.finditer(content):
        named_templates[m.group(1)].append((chart, fp))

dup_defines = {n: srcs for n, srcs in named_templates.items() if len(srcs) > 1}
print(f"\n  Duplicate named template definitions: {len(dup_defines)}")
dup_def_html = ""
for name, srcs in sorted(dup_defines.items()):
    src_str = ", ".join(f"{c}:{os.path.basename(f)}" for c,f in srcs)
    print(f"    {{{{ define \"{name}\" }}}}  in: {src_str}")
    badges = " ".join(f"<span class='badge muted'>{c}</span>" for c,f in srcs)
    dup_def_html += f"<tr data-status='warn'><td class='mono hi-yellow'>{{{{{{ define \"{name}\" }}}}}}</td><td>{badges}</td></tr>"
print(f"__HTML_DUP_DEF__{dup_def_html}__END_HTML_DUP_DEF__")

# ── large inline data ─────────────────────────────────────────────────────────
inline_issues = []
for fp, content, size, chart, is_sub in all_templates:
    for m in re.finditer(r':\s*\|\s*\n((?:[ \t]+[^\n]+\n){10,})', content):
        inline_issues.append((m.group(1).count('\n'), chart, fp, "multiline block"))
    for m in re.finditer(r':\s*[A-Za-z0-9+/]{200,}={0,2}', content):
        inline_issues.append((len(m.group(0)), chart, fp, "base64 blob"))
inline_issues.sort(reverse=True)
print(f"\n  Inline data issues: {len(inline_issues)}")
inline_html = ""
for sz, chart, fp, reason in inline_issues[:20]:
    rel = os.path.relpath(fp)
    print(f"    {chart}  {rel}  {reason} ({sz} lines/chars)")
    inline_html += f"<tr data-status='warn'><td><span class='badge muted'>{chart}</span></td><td class='mono'>{os.path.basename(fp)}</td><td class='mono hi-yellow'>{reason}</td><td>{sz}</td></tr>"
print(f"__HTML_INLINE__{inline_html}__END_HTML_INLINE__")

# ── suggestions ───────────────────────────────────────────────────────────────
suggestions = []

# duplicate helper bodies
helper_bodies = defaultdict(list)
for fp, content, size, chart, is_sub in all_templates:
    for m in define_re.finditer(content):
        body = re.sub(r'\s+',' ', m.group(2).strip())[:200]
        helper_bodies[body].append((chart, os.path.basename(fp), m.group(1)))
for body, srcs in helper_bodies.items():
    if len(srcs) > 1:
        suggestions.append({"sev":"high","cat":"Consolidate helpers",
            "detail":f"Body duplicated across: {', '.join(n for _,_,n in srcs[:3])}. Move to umbrella _helpers.tpl.",
            "files":list({f for _,f,_ in srcs})})

# large files
for fp, content, size, chart, is_sub in all_templates:
    if size > 50*1024:
        suggestions.append({"sev":"high","cat":"Split large template",
            "detail":f"{os.path.basename(fp)} is {size/1024:.0f}KB — split into one file per resource type.",
            "files":[os.path.basename(fp)]})
    elif size > 20*1024:
        suggestions.append({"sev":"medium","cat":"Consider splitting",
            "detail":f"{os.path.basename(fp)} is {size/1024:.0f}KB — consider splitting by resource type.",
            "files":[os.path.basename(fp)]})

# excessive toYaml
for fp, content, size, chart, is_sub in all_templates:
    n = len(re.findall(r'toYaml\s+\.Values\.[^\s|]+', content))
    if n > 5:
        suggestions.append({"sev":"medium","cat":"Excessive toYaml",
            "detail":f"{os.path.basename(fp)} calls toYaml {n}x — large structs serialised at render inflate output.",
            "files":[os.path.basename(fp)]})

# many includes
for fp, content, size, chart, is_sub in all_templates:
    n = len(re.findall(r'\{\{-?\s*include\s+"[^"]+"\s*', content))
    if n > 15:
        suggestions.append({"sev":"medium","cat":"Many includes",
            "detail":f"{os.path.basename(fp)} has {n} include calls — each expands inline, review for unnecessary nesting.",
            "files":[os.path.basename(fp)]})

# whitespace trim ratio
for fp, content, size, chart, is_sub in all_templates:
    if size < 5*1024: continue
    no_trim = len(re.findall(r'\{\{[^-]', content))
    has_trim = len(re.findall(r'\{\{-', content))
    total = no_trim + has_trim
    if total > 0 and has_trim/total < 0.3 and size > 10*1024:
        suggestions.append({"sev":"low","cat":"Add whitespace trim",
            "detail":f"{os.path.basename(fp)}: only {has_trim/total*100:.0f}% of delimiters use {{{{- trim. Adding it reduces rendered output size.",
            "files":[os.path.basename(fp)]})

# commented-out blocks
for fp, content, size, chart, is_sub in all_templates:
    comments = re.findall(r'#[^\n]{40,}', content)
    if len(comments) > 10:
        suggestions.append({"sev":"low","cat":"Remove long comments",
            "detail":f"{os.path.basename(fp)} has {len(comments)} long comment lines — Helm includes them in rendered output.",
            "files":[os.path.basename(fp)]})

# deduplicate
seen = set()
unique = []
for s in suggestions:
    k = s["cat"] + s["detail"][:60]
    if k not in seen: seen.add(k); unique.append(s)

order = {"high":0,"medium":1,"low":2}
unique.sort(key=lambda x: order.get(x["sev"],3))

print(f"\n  Suggestions: {len(unique)}")
sugg_html = ""
for s in unique:
    css = "err" if s["sev"]=="high" else ("warn" if s["sev"]=="medium" else "muted")
    print(f"  [{s['sev'].upper():6}] {s['cat']}: {s['detail']}")
    sugg_html += f"<tr data-status='{css}'><td><span class='badge {css}'>{s['sev']}</span></td><td class='mono'>{s['cat']}</td><td>{s['detail']}</td><td class='mono muted'>{', '.join(s['files'][:3])}</td></tr>"
print(f"__HTML_SUGG__{sugg_html}__END_HTML_SUGG__")
PYEOF

TEMPLATE_ROWS=$(grep -oP '(?<=__HTML_TMPL_SIZE__).*(?=__END_HTML_TMPL_SIZE__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
DUP_DEF_ROWS=$(grep -oP '(?<=__HTML_DUP_DEF__).*(?=__END_HTML_DUP_DEF__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
INLINE_ROWS=$(grep -oP '(?<=__HTML_INLINE__).*(?=__END_HTML_INLINE__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)
SUGG_ROWS=$(grep -oP '(?<=__HTML_SUGG__).*(?=__END_HTML_SUGG__)' "$TMP_PY" | tr -d '\n' 2>/dev/null || true)

# =============================================================================
# SUMMARY
# =============================================================================
hdr "✓ Scan complete"
printf "  Chart    : %s\n" "$UMBRELLA_NAME"
printf "  Dir size : %s\n" "$(human_bytes "$UMB_TOTAL_SIZE")"
[[ "$RENDER_OK" == true ]] && printf "  Rendered : %s  (%d%% of 5MB)\n" "$RENDER_H" "$RENDER_PCT" || true
[[ "$EMIT_HTML" == true ]] && printf "  Report   : %s\n" "$HTML_OUT" || true

# =============================================================================
# HTML REPORT
# =============================================================================
if [[ "$EMIT_HTML" == true ]]; then

  RENDER_STATUS_BADGE="<span class='badge ok'>OK — ${RENDER_PCT}% of 5MB</span>"
  ((RENDER_PCT > WARN_PCT)) && RENDER_STATUS_BADGE="<span class='badge warn'>WARNING — ${RENDER_PCT}% of 5MB</span>" || true
  ((RENDER_BYTES > HELM_LIMIT)) && RENDER_STATUS_BADGE="<span class='badge err'>OVER LIMIT — ${RENDER_PCT}%</span>" || true

  RENDER_CLS="grn"
  ((RENDER_PCT > WARN_PCT)) && RENDER_CLS="yel" || true
  ((RENDER_BYTES > HELM_LIMIT)) && RENDER_CLS="red" || true
  SC_COUNT=${#SUBCHART_DIRS[@]}

  {
    cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Helm Umbrella Scan</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&family=JetBrains+Mono:wght@400;500&display=swap');
:root {
  --bg:#090c10;--s1:#0d1117;--s2:#161b22;--s3:#1c2128;
  --br:#30363d;--br2:#21262d;
  --tx:#e6edf3;--mu:#7d8590;--mu2:#484f58;
  --red:#f85149;--red-d:rgba(248,81,73,.13);
  --yel:#e3b341;--yel-d:rgba(227,179,65,.13);
  --grn:#3fb950;--grn-d:rgba(63,185,80,.13);
  --blu:#58a6ff;--blu-d:rgba(88,166,255,.1);
  --pur:#bc8cff;
  --nav:220px;--r:6px;
  --font:'Inter',system-ui,sans-serif;
  --mono:'JetBrains Mono','Fira Code',monospace;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font-family:var(--font);font-size:13px;line-height:1.6;display:flex;min-height:100vh}
nav{position:fixed;top:0;left:0;bottom:0;width:var(--nav);background:var(--s1);border-right:1px solid var(--br);display:flex;flex-direction:column;overflow-y:auto;z-index:100}
.nav-hd{padding:1.1rem 1rem .9rem;border-bottom:1px solid var(--br);position:sticky;top:0;background:var(--s1)}
.nav-hd .logo{font-size:1rem;font-weight:600;color:var(--blu)}
.nav-hd .repo{font-family:var(--mono);font-size:.65rem;color:var(--mu);margin-top:.2rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.nav-lbl{font-size:.62rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:var(--mu2);padding:.9rem 1rem .25rem}
nav a{display:flex;align-items:center;gap:.4rem;padding:.35rem 1rem;text-decoration:none;color:var(--mu);font-size:.78rem;border-left:2px solid transparent;transition:all .15s}
nav a:hover{color:var(--tx);background:var(--s2)}
nav a.active{color:var(--blu);border-left-color:var(--blu);background:var(--blu-d)}
main{margin-left:var(--nav);flex:1;padding:2rem 2.5rem;max-width:1080px}
.ph{margin-bottom:1.75rem}
.ph h1{font-size:1.3rem;font-weight:600;letter-spacing:-.02em}
.ph .meta{font-family:var(--mono);font-size:.68rem;color:var(--mu);margin-top:.3rem;display:flex;gap:1.25rem;flex-wrap:wrap}
.dash{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:.65rem;margin-bottom:2.25rem}
.card{background:var(--s1);border:1px solid var(--br);border-radius:var(--r);padding:.85rem}
.card .cl{font-size:.67rem;color:var(--mu);text-transform:uppercase;letter-spacing:.06em;font-weight:500}
.card .cv{font-size:1.75rem;font-weight:600;line-height:1.1;font-family:var(--mono)}
.card .cs{font-size:.67rem;color:var(--mu);margin-top:.1rem}
.card.red{border-color:var(--red);background:var(--red-d)}.card.red .cv{color:var(--red)}
.card.yel{border-color:var(--yel);background:var(--yel-d)}.card.yel .cv{color:var(--yel)}
.card.grn{border-color:var(--grn);background:var(--grn-d)}.card.grn .cv{color:var(--grn)}
.card.blu{border-color:var(--blu);background:var(--blu-d)}.card.blu .cv{color:var(--blu)}
section{margin-bottom:2.5rem;scroll-margin-top:1.5rem}
.sh{display:flex;align-items:center;gap:.65rem;margin-bottom:.75rem;cursor:pointer;user-select:none}
.sh h2{font-size:.9rem;font-weight:600;flex:1}
.sh .sn{font-family:var(--mono);font-size:.67rem;color:var(--mu);background:var(--s2);border:1px solid var(--br);padding:.12rem .45rem;border-radius:99px}
.sh .ci{font-size:.7rem;color:var(--mu);transition:transform .2s}
.sh .ci.open{transform:rotate(90deg)}
.sd{font-size:.75rem;color:var(--mu);margin-bottom:.75rem;padding:.55rem .8rem;background:var(--s2);border-left:3px solid var(--br);border-radius:0 var(--r) var(--r) 0;line-height:1.5}
.sd strong{color:var(--tx)}
.sb{overflow:hidden}
.tw{overflow-x:auto;border-radius:var(--r);border:1px solid var(--br)}
table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:.73rem}
thead{position:sticky;top:0;z-index:2}
th{background:var(--s2);color:var(--mu);padding:.45rem .8rem;text-align:left;border-bottom:1px solid var(--br);font-weight:500;font-size:.67rem;text-transform:uppercase;letter-spacing:.05em;cursor:pointer;white-space:nowrap;user-select:none}
th:hover{color:var(--tx)}
td{padding:.4rem .8rem;border-bottom:1px solid var(--br2);vertical-align:middle;color:var(--tx)}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--s2)}
tr[data-status=err] td:first-child{border-left:3px solid var(--red)}
tr[data-status=warn] td:first-child{border-left:3px solid var(--yel)}
tr[data-status=ok] td:first-child{border-left:3px solid var(--grn)}
.mono{font-family:var(--mono);font-size:.72rem}
.hi-yellow{color:var(--yel)}
.muted{color:var(--mu)}
.badge{display:inline-flex;align-items:center;padding:.12rem .45rem;border-radius:99px;font-size:.65rem;font-weight:500;font-family:var(--mono);white-space:nowrap}
.badge.err{background:var(--red-d);color:var(--red);border:1px solid var(--red)}
.badge.warn{background:var(--yel-d);color:var(--yel);border:1px solid var(--yel)}
.badge.ok{background:var(--grn-d);color:var(--grn);border:1px solid var(--grn)}
.badge.info{background:var(--blu-d);color:var(--blu);border:1px solid var(--blu)}
.badge.muted{background:var(--s3);color:var(--mu);border:1px solid var(--br)}
.bar-wrap{display:flex;align-items:center;gap:.5rem;min-width:120px}
.bar-track{flex:1;height:5px;background:var(--s3);border-radius:99px;overflow:hidden}
.bar-fill{height:100%;border-radius:99px}
.bar-fill.ok{background:var(--grn)}.bar-fill.warn{background:var(--yel)}.bar-fill.err{background:var(--red)}
.bar-label{font-size:.68rem;color:var(--mu);white-space:nowrap}
.fb{display:flex;gap:.45rem;margin-bottom:.65rem;flex-wrap:wrap;align-items:center}
.fb input[type=search]{background:var(--s2);border:1px solid var(--br);color:var(--tx);font-family:var(--mono);font-size:.73rem;padding:.3rem .65rem;border-radius:var(--r);outline:none;width:200px}
.fb input[type=search]:focus{border-color:var(--blu)}
.fb-btn{background:var(--s2);border:1px solid var(--br);color:var(--mu);font-size:.68rem;padding:.25rem .6rem;border-radius:var(--r);cursor:pointer;font-family:var(--font)}
.fb-btn:hover{color:var(--tx);border-color:var(--mu)}
.fb-btn.active{color:var(--blu);border-color:var(--blu);background:var(--blu-d)}
.rc{font-size:.67rem;color:var(--mu);margin-left:auto}
.tip{background:var(--s2);border:1px solid var(--br);border-radius:var(--r);padding:.75rem .9rem;margin-top:.75rem}
.tip .tt{font-size:.68rem;font-weight:600;color:var(--blu);text-transform:uppercase;letter-spacing:.06em;margin-bottom:.4rem}
.tip ul{padding-left:1.1rem}
.tip li{font-size:.74rem;color:var(--mu);line-height:1.7}
.tip li strong{color:var(--tx)}
.tip code{background:var(--s3);border:1px solid var(--br);border-radius:3px;padding:.08rem .3rem;font-family:var(--mono);font-size:.7rem;color:var(--pur)}
.empty{text-align:center;padding:1.5rem;color:var(--mu);font-size:.8rem}
::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-track{background:var(--s1)}::-webkit-scrollbar-thumb{background:var(--br);border-radius:3px}
</style>
</head>
<body>
HTML_HEAD

    cat <<NAVEOF
<nav>
  <div class="nav-hd">
    <div class="logo">⎈ Helm Scan</div>
    <div class="repo">$UMBRELLA_NAME</div>
  </div>
  <div class="nav-lbl">Overview</div>
  <a href="#dash">Dashboard</a>
  <div class="nav-lbl">Sections</div>
  <a href="#s1">1 · Overview</a>
  <a href="#s2">2 · Size Breakdown</a>
  <a href="#s3">3 · Rendered Resources</a>
  <a href="#s4">4 · Values Duplication</a>
  <a href="#s5">5 · Redundant Values</a>
  <a href="#s6">6 · Unused Values</a>
  <a href="#s7">7 · Template Sizes</a>
  <a href="#s8">8 · Duplicate Helpers</a>
  <a href="#s9">9 · Inline Data</a>
  <a href="#s10">10 · Suggestions</a>
</nav>
NAVEOF

    echo "<main>"

    cat <<PHEOF
<div class="ph">
  <h1>⎈ $UMBRELLA_NAME</h1>
  <div class="meta">
    <span>$(date -u '+%Y-%m-%d %H:%M UTC')</span>
    <span>$UMBRELLA</span>
    <span>v$UMBRELLA_VER</span>
    <span>$SC_COUNT sub-charts</span>
  </div>
</div>
<div id="dash" class="dash">
  <div class="card blu"><div class="cl">Sub-charts</div><div class="cv">$SC_COUNT</div><div class="cs">vendored</div></div>
  <div class="card $RENDER_CLS"><div class="cl">Rendered</div><div class="cv" style="font-size:1.2rem">$RENDER_H</div><div class="cs">${RENDER_PCT}% of 5MB limit</div></div>
  <div class="card"><div class="cl">Dir Size</div><div class="cv" style="font-size:1.2rem">$(human_bytes $UMB_TOTAL_SIZE)</div><div class="cs">umbrella root</div></div>
  <div class="card"><div class="cl">Templates</div><div class="cv">$UMB_NTMPLS</div><div class="cs">umbrella level</div></div>
</div>
PHEOF

    SC_TABLE=""
    for sc in "${SUBCHART_DIRS[@]}"; do
      scname=$(yq '.name' "$sc/Chart.yaml" 2>/dev/null || basename "$sc")
      scver=$(yq '.version' "$sc/Chart.yaml" 2>/dev/null || echo "—")
      sctype=$(yq '.type // "application"' "$sc/Chart.yaml" 2>/dev/null)
      scsz=$(human_bytes "$(dir_size "$sc")")
      SC_TABLE+="<tr><td>$scname</td><td class='mono muted'>$sc</td><td><span class='badge muted'>$sctype</span></td><td>$scver</td><td>$scsz</td></tr>"
    done

    cat <<SECEOF
<section id="s1">
  <div class="sh"><span class="sn">1</span><h2>Umbrella Overview</h2><span class="ci">▶</span></div>
  <div class="sd">Vendored sub-charts found under <code>charts/</code>.</div>
  <div class="sb"><div class="tw"><table>
    <thead><tr><th>Sub-chart</th><th>Path</th><th>Type</th><th>Version</th><th>Dir Size</th></tr></thead>
    <tbody>$SC_TABLE</tbody>
  </table></div></div>
</section>

<section id="s2">
  <div class="sh"><span class="sn">2</span><h2>Size Breakdown</h2><span class="ci">▶</span></div>
  <div class="sd">Directory size of the umbrella and each sub-chart. Template and values sizes shown separately so you can see where bytes are concentrated.</div>
  <div class="sb">
    <div class="tw"><table id="tbl2">
      <thead><tr><th data-col="0">Component</th><th data-col="1">Dir Size</th><th data-col="2">Templates</th><th data-col="3">Values</th><th data-col="4"># Tmpls</th><th data-col="5">Status</th></tr></thead>
      <tbody>$SIZE_ROWS</tbody>
    </table></div>
    <div class="tip"><div class="tt">💡 What to do</div><ul>
      <li><strong>Large sub-chart:</strong> check whether it belongs in this umbrella or should deploy independently.</li>
      <li><strong>Large values:</strong> remove keys equal to defaults (§5) and unreferenced keys (§6).</li>
    </ul></div>
  </div>
</section>

<section id="s3">
  <div class="sh"><span class="sn">3</span><h2>Rendered Resources</h2><span class="ci">▶</span></div>
  <div class="sd"><code>helm template</code> output: <strong>$RENDER_H</strong> total — $RENDER_STATUS_BADGE. Kubernetes rejects Secrets over <strong>1 MB</strong>.</div>
  <div class="sb">
    <div class="fb" data-table="tbl3">
      <input type="search" placeholder="Filter kind or name…">
      <button class="fb-btn active" data-status="all">All</button>
      <button class="fb-btn" data-status="err">Secret Issues</button>
      <button class="fb-btn" data-status="warn">Warnings</button>
      <span class="rc"></span>
    </div>
    <div class="tw"><table id="tbl3">
      <thead><tr><th data-col="0">Kind</th><th data-col="1">Name</th><th data-col="2">Size</th><th data-col="3">Flag</th></tr></thead>
      <tbody>$([ -n "$RESOURCE_ROWS" ] && echo "$RESOURCE_ROWS" || echo "<tr><td colspan='4' class='empty'>Render failed — no data</td></tr>")</tbody>
    </table></div>
  </div>
</section>

<section id="s4">
  <div class="sh"><span class="sn">4</span><h2>Duplicated Values Across Files</h2><span class="ci">▶</span></div>
  <div class="sd">Identical key=value pairs in more than one values file. Consolidate into the umbrella <code>values.yaml</code> or a shared global file.</div>
  <div class="sb">
    <div class="fb" data-table="tbl4"><input type="search" placeholder="Filter key…"><span class="rc"></span></div>
    <div class="tw"><table id="tbl4">
      <thead><tr><th data-col="0">Key</th><th data-col="1">Value</th><th data-col="2"># Files</th><th data-col="3">Found In</th></tr></thead>
      <tbody>$([ -n "$DUPE_ROWS" ] && echo "$DUPE_ROWS" || echo "<tr><td colspan='4' class='empty'>No duplicates found</td></tr>")</tbody>
    </table></div>
  </div>
</section>

<section id="s5">
  <div class="sh"><span class="sn">5</span><h2>Redundant Sub-chart Values</h2><span class="ci">▶</span></div>
  <div class="sd">Keys in sub-chart values files whose value is <strong>identical to the umbrella values.yaml</strong> — the umbrella already defines them.</div>
  <div class="sb">
    <div class="fb" data-table="tbl5"><input type="search" placeholder="Filter key…"><span class="rc"></span></div>
    <div class="tw"><table id="tbl5">
      <thead><tr><th data-col="0">Sub-chart File</th><th data-col="1">Key</th><th data-col="2">Value</th></tr></thead>
      <tbody>$([ -n "$REDUNDANT_ROWS" ] && echo "$REDUNDANT_ROWS" || echo "<tr><td colspan='3' class='empty'>No redundant keys found</td></tr>")</tbody>
    </table></div>
  </div>
</section>

<section id="s6">
  <div class="sh"><span class="sn">6</span><h2>Unused Values</h2><span class="ci">▶</span></div>
  <div class="sd">Keys defined in values files with no reference found in any template. <strong>Verify manually</strong> — some may be consumed by non-vendored dependencies.</div>
  <div class="sb">
    <div class="fb" data-table="tbl6"><input type="search" placeholder="Filter key…"><span class="rc"></span></div>
    <div class="tw"><table id="tbl6">
      <thead><tr><th data-col="0">File</th><th data-col="1">Key</th></tr></thead>
      <tbody>$([ -n "$UNUSED_ROWS" ] && echo "$UNUSED_ROWS" || echo "<tr><td colspan='2' class='empty'>No unused keys detected</td></tr>")</tbody>
    </table></div>
  </div>
</section>

<section id="s7">
  <div class="sh"><span class="sn">7</span><h2>Template Sizes</h2><span class="ci">▶</span></div>
  <div class="sd">All template files sorted by size. Files over <strong>50 KB</strong> likely contain multiple resource types and should be split.</div>
  <div class="sb">
    <div class="fb" data-table="tbl7">
      <input type="search" placeholder="Filter chart or file…">
      <button class="fb-btn active" data-status="all">All</button>
      <button class="fb-btn" data-status="err">Large</button>
      <button class="fb-btn" data-status="warn">Big</button>
      <span class="rc"></span>
    </div>
    <div class="tw"><table id="tbl7">
      <thead><tr><th data-col="0">Chart</th><th data-col="1">File</th><th data-col="2">Size</th><th data-col="3">Flag</th></tr></thead>
      <tbody>$([ -n "$TEMPLATE_ROWS" ] && echo "$TEMPLATE_ROWS" || echo "<tr><td colspan='4' class='empty'>No templates found</td></tr>")</tbody>
    </table></div>
  </div>
</section>

<section id="s8">
  <div class="sh"><span class="sn">8</span><h2>Duplicate Named Templates</h2><span class="ci">▶</span></div>
  <div class="sd"><code>{{- define "..." }}</code> blocks defined in more than one chart. Duplicates waste space and cause subtle override bugs — consolidate into the umbrella <code>_helpers.tpl</code>.</div>
  <div class="sb"><div class="tw"><table id="tbl8">
    <thead><tr><th>Template Name</th><th>Defined In</th></tr></thead>
    <tbody>$([ -n "$DUP_DEF_ROWS" ] && echo "$DUP_DEF_ROWS" || echo "<tr><td colspan='2' class='empty'>No duplicates found</td></tr>")</tbody>
  </table></div></div>
</section>

<section id="s9">
  <div class="sh"><span class="sn">9</span><h2>Large Inline Data</h2><span class="ci">▶</span></div>
  <div class="sd">Multiline YAML blocks and base64 blobs embedded in templates. Move to ConfigMaps loaded from files, or manage via an external secret store.</div>
  <div class="sb"><div class="tw"><table id="tbl9">
    <thead><tr><th>Chart</th><th>File</th><th>Issue</th><th>Size</th></tr></thead>
    <tbody>$([ -n "$INLINE_ROWS" ] && echo "$INLINE_ROWS" || echo "<tr><td colspan='4' class='empty'>No large inline data found</td></tr>")</tbody>
  </table></div></div>
</section>

<section id="s10">
  <div class="sh"><span class="sn">10</span><h2>Template Reduction Suggestions</h2><span class="ci">▶</span></div>
  <div class="sd">Actionable suggestions ordered by severity.</div>
  <div class="sb">
    <div class="fb" data-table="tbl10">
      <input type="search" placeholder="Filter…">
      <button class="fb-btn active" data-status="all">All</button>
      <button class="fb-btn" data-status="err">High</button>
      <button class="fb-btn" data-status="warn">Medium</button>
      <button class="fb-btn" data-status="muted">Low</button>
      <span class="rc"></span>
    </div>
    <div class="tw"><table id="tbl10">
      <thead><tr><th>Severity</th><th>Category</th><th>Detail</th><th>Files</th></tr></thead>
      <tbody>$([ -n "$SUGG_ROWS" ] && echo "$SUGG_ROWS" || echo "<tr><td colspan='4' class='empty'>No suggestions generated</td></tr>")</tbody>
    </table></div>
    <div class="tip"><div class="tt">💡 General techniques</div><ul>
      <li><strong>Use <code>{{- ... -}}</code> trim markers</strong> on every delimiter — eliminates blank lines, reduces output 10–20% on verbose templates.</li>
      <li><strong>Extract repeated blocks into <code>_helpers.tpl</code></strong> and use <code>include</code> rather than copy-pasting across sub-charts.</li>
      <li><strong>Avoid <code>toYaml</code> on large nested values</strong> — flatten the structure or split into smaller keys.</li>
      <li><strong>One file per resource type</strong> — large files with many <code>---</code> docs are harder to audit and often contain dead resources.</li>
      <li><strong>Strip commented-out blocks</strong> — Helm includes comments in rendered output; use <code>{{- /* comment */ -}}</code> for template-only comments.</li>
      <li><strong>Use <code>lookup</code> sparingly</strong> — each lookup call adds a live API call at render time and can return large objects into your template context.</li>
    </ul></div>
  </div>
</section>
SECEOF

    cat <<'FOOT'
</main>
<script>
// Active nav highlight
const allSecs = document.querySelectorAll('section[id]');
const allLinks = document.querySelectorAll('nav a[href^="#"]');
const io = new IntersectionObserver(es => {
  es.forEach(e => { if(e.isIntersecting) allLinks.forEach(a => a.classList.toggle('active', a.getAttribute('href')==='#'+e.target.id)); });
}, {rootMargin:'-20% 0px -70% 0px'});
allSecs.forEach(s => io.observe(s));

// Collapsible sections
document.querySelectorAll('.sh').forEach(h => {
  const ci = h.querySelector('.ci');
  const desc = h.nextElementSibling?.classList.contains('sd') ? h.nextElementSibling : null;
  const body = desc ? desc.nextElementSibling : h.nextElementSibling;
  if(!body) return;
  ci.classList.add('open');
  h.addEventListener('click', () => {
    const open = ci.classList.toggle('open');
    body.style.display = open ? '' : 'none';
    if(desc) desc.style.display = open ? '' : 'none';
  });
});

// Sortable tables
document.querySelectorAll('th[data-col]').forEach(th => {
  th.addEventListener('click', () => {
    const tbody = th.closest('table').querySelector('tbody');
    const col = parseInt(th.dataset.col);
    const asc = !th.classList.contains('_asc');
    th.closest('thead').querySelectorAll('th').forEach(t => t.classList.remove('_asc','_desc'));
    th.classList.add(asc ? '_asc' : '_desc');
    [...tbody.querySelectorAll('tr')].sort((a,b) => {
      const av = a.cells[col]?.dataset.val ?? a.cells[col]?.textContent ?? '';
      const bv = b.cells[col]?.dataset.val ?? b.cells[col]?.textContent ?? '';
      const an = parseFloat(av), bn = parseFloat(bv);
      return isNaN(an)||isNaN(bn) ? (asc?av.localeCompare(bv):bv.localeCompare(av)) : (asc?an-bn:bn-an);
    }).forEach(r => tbody.appendChild(r));
  });
});

// Filter bars
document.querySelectorAll('.fb').forEach(fb => {
  const tbody = document.querySelector('#' + fb.dataset.table + ' tbody');
  if(!tbody) return;
  const rc = fb.querySelector('.rc');
  const inp = fb.querySelector('input');
  const btns = fb.querySelectorAll('.fb-btn[data-status]');
  let active = 'all';
  function applyFilter() {
    const q = (inp?.value ?? '').toLowerCase();
    let n = 0;
    tbody.querySelectorAll('tr').forEach(r => {
      const show = (!q || r.textContent.toLowerCase().includes(q)) &&
                   (active==='all' || (r.dataset.status??'')=== active);
      r.style.display = show ? '' : 'none';
      if(show) n++;
    });
    if(rc) rc.textContent = n + ' row' + (n!==1?'s':'');
  }
  inp?.addEventListener('input', applyFilter);
  btns.forEach(b => b.addEventListener('click', () => {
    btns.forEach(x => x.classList.remove('active'));
    b.classList.add('active'); active = b.dataset.status; applyFilter();
  }));
  applyFilter();
});
</script>
</body></html>
FOOT

  } >"$HTML_OUT"
  echo "  → $HTML_OUT"

fi
