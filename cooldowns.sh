#!/usr/bin/env bash
# cooldowns.sh — configure dependency "cooldowns" (minimum release age) for package installers.
#
# Based on https://cooldowns.dev/  — a cooldown makes an installer refuse package versions
# published less than N days ago, which blocks most supply-chain attacks (they are usually
# pulled within hours/days).
#
# Usage:  cooldowns.sh            interactive (asks global / local)
#         cooldowns.sh global     configure user-wide settings for every supported installer
#         cooldowns.sh local      configure the project in the current directory
#         cooldowns.sh --add-zshrc   add  alias cooldowns=~/scripts/cooldowns.sh  to ~/.zshrc
#         cooldowns.sh --rust-nightly   switch the Rust project in the current dir to nightly cargo
#                                       (rust-toolchain.toml) and enable cargo's native cooldown
#         cooldowns.sh -h         help
#
# Every installer is asked separately: 1 / 2 / 3 days, turn OFF (explicit 0), or skip.

set -u

ENV_FILE="$HOME/.cooldowns.env"
ZSHRC="$HOME/.zshrc"

# ------------------------------------------------------------------ colors / output
if [ -t 1 ]; then
  RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' CYAN=$'\033[36m'
  DIM=$'\033[2m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' DIM='' BOLD='' RESET=''
fi

tilde() { local s="$*" t='~'; printf '%s' "${s//$HOME/$t}"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$(tilde "$*")"; SUMMARY="${SUMMARY}  ✔ $(tilde "$*")"$'\n'; }
off()  { printf '  %s✔ OFF%s %s\n' "$RED" "$RESET" "$(tilde "$*")"; SUMMARY="${SUMMARY}  ✔ OFF $(tilde "$*")"$'\n'; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$(tilde "$*")"; }
skip() { printf '  %s– %s%s\n' "$DIM" "$*" "$RESET"; }
hint() { printf '    %s%s%s\n' "$DIM" "$(tilde "$*")" "$RESET"; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

SUMMARY=""
DAYS=""
CONFIGURED=" "   # space separated ids already handled in this run

has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------ generic file editing
# All helpers create the file (and parent dir) if missing and keep permissions.

_tmp_for() { printf '%s' "$1.cooldowns.$$"; }
_prep() { mkdir -p "$(dirname "$1")"; [ -f "$1" ] || : > "$1"; cp -p "$1" "$(_tmp_for "$1")"; }

# set_line FILE REGEX LINE — replace first line matching REGEX with LINE, or append LINE.
set_line() {
  local f="$1" re="$2" line="$3" tmp
  _prep "$f"; tmp="$(_tmp_for "$f")"
  awk -v re="$re" -v line="$line" '
    $0 ~ re && !done { print line; done = 1; next }
    { print }
    END { if (!done) print line }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# del_line FILE REGEX — delete every line matching REGEX.
del_line() {
  local f="$1" re="$2" tmp
  [ -f "$f" ] || return 0
  _prep "$f"; tmp="$(_tmp_for "$f")"
  awk -v re="$re" '$0 ~ re { next } { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

kv_set()   { set_line "$1" "^[[:space:]]*$2[[:space:]]*=" "$2=$3"; }          # key=value   (.npmrc)
yaml_set() { set_line "$1" "^$2[[:space:]]*:" "$2: $3"; }                     # key: value  (top-level yaml)
env_set()  { set_line "$ENV_FILE" "^export $1=" "export $1=\"$2\""; ensure_env_sourced; }
env_del()  { del_line "$ENV_FILE" "^export $1="; }

# toml_set FILE SECTION KEY VALUE — VALUE must already be TOML formatted ("str", 3, ...).
# SECTION "" means top level. Dotted sections like tool.uv are fine.
toml_set() {
  local f="$1" sec="$2" key="$3" val="$4" tmp
  _prep "$f"; tmp="$(_tmp_for "$f")"
  awk -v sec="$sec" -v key="$key" -v val="$val" '
    function hdr(l) { sub(/^[[:space:]]*\[+/, "", l); sub(/\]+.*$/, "", l); gsub(/[[:space:]"]/, "", l); return l }
    function flush() { while (nb > 0) { print ""; nb-- } }
    BEGIN { insec = (sec == ""); seen = (sec == ""); done = 0; nb = 0; kre = "^[[:space:]]*" key "[[:space:]]*=" }
    /^[[:space:]]*\[/ {
      if (insec && !done) { print key " = " val; done = 1 }
      flush()
      insec = (hdr($0) == sec); if (insec) seen = 1
      print; next
    }
    insec && !done && /^[[:space:]]*$/ { nb++; next }     # hold blank lines so the key lands before them
    { flush() }
    insec && !done && $0 ~ kre { print key " = " val; done = 1; next }
    { print }
    END {
      if (!done) {
        if (seen) print key " = " val
        else { if (NR > 0) print ""; print "[" sec "]"; print key " = " val }
      }
      flush()
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# toml_del FILE SECTION KEY
toml_del() {
  local f="$1" sec="$2" key="$3" tmp
  [ -f "$f" ] || return 0
  _prep "$f"; tmp="$(_tmp_for "$f")"
  awk -v sec="$sec" -v key="$key" '
    function hdr(l) { sub(/^[[:space:]]*\[+/, "", l); sub(/\]+.*$/, "", l); gsub(/[[:space:]"]/, "", l); return l }
    BEGIN { insec = (sec == ""); kre = "^[[:space:]]*" key "[[:space:]]*=" }
    /^[[:space:]]*\[/ { insec = (hdr($0) == sec); print; next }
    insec && $0 ~ kre { next }
    { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# json_set FILE JQ_FILTER [jq args...] — returns 1 if jq cannot parse (comments, jsonc).
json_set() {
  local f="$1" filter="$2" tmp; shift 2
  has jq || return 1
  _prep "$f"; tmp="$(_tmp_for "$f")"
  if jq --indent 2 "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

ensure_env_sourced() {
  grep -qF '.cooldowns.env' "$ZSHRC" 2>/dev/null && return 0
  printf '\n# dependency cooldowns (managed by cooldowns.sh)\n[ -f "$HOME/.cooldowns.env" ] && source "$HOME/.cooldowns.env"\n' >> "$ZSHRC"
  hint "added 'source ~/.cooldowns.env' to ~/.zshrc (open a new shell or run: source ~/.zshrc)"
}

pip_bin() { if has pip3; then echo pip3; elif has pip; then echo pip; fi; }
pip_user_conf() { "$1" config debug 2>/dev/null | awk '/^user:/ { u = 1; next } /^[a-z_]+:/ { u = 0 } u && /exists: True/ { sub(/,$/, "", $1); print $1; exit }'; }
major_of() { "$1" --version 2>/dev/null | grep -oE '[0-9]+' | head -1; }

# ------------------------------------------------------------------ version checks
UPGRADES=""

# minimum version that supports the cooldown setting (from cooldowns.dev)
tool_minver() {
  case "$1" in
    npm) echo 11.10.0;; pnpm) echo 10.16.0;; yarn) echo 4.10.0;; bun) echo 1.3.0;; deno) echo 2.6.0;;
    uv) echo 0.9.17;; pip) echo 26.1.0;; pipenv) echo 2026.6.2;; poetry) echo 2.4.0;; pdm) echo 2.26.9;;
    pixi) echo 0.67.0;; bundler) echo 4.0.13;; hex) echo 2.5.0;; mise) echo 2026.6.2;;
    *) echo "";;
  esac
}

# installed version (x.y.z) of a tool, empty if not installed
tool_version() {
  local out
  case "$1" in
    hex) out="$(mix hex --version 2>/dev/null)";;
    bundler) out="$(bundle --version 2>/dev/null)";;
    pip) out="$("$(pip_bin)" --version 2>/dev/null)";;
    *) out="$("$(tool_bin "$1")" --version 2>/dev/null)";;
  esac
  printf '%s' "$out" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

is_brew() { case "$(command -v "$1" 2>/dev/null)" in /opt/homebrew/*|/usr/local/Cellar/*|/home/linuxbrew/*) return 0;; *) return 1;; esac; }

# upgrade command for a tool, preferring the way it was installed
tool_upgrade() {
  case "$1" in
    npm)    echo "npm install -g npm@latest";;
    pnpm)   if is_brew pnpm; then echo "brew upgrade pnpm"; else echo "npm install -g pnpm@latest   (or: corepack prepare pnpm@latest --activate)"; fi;;
    yarn)   echo "corepack enable && cd <project> && yarn set version stable   (Yarn 4 is per project; global yarn 1 can stay)";;
    bun)    echo "bun upgrade";;
    deno)   if is_brew deno; then echo "brew upgrade deno"; else echo "deno upgrade"; fi;;
    uv)     if is_brew uv; then echo "brew upgrade uv"; else echo "uv self update"; fi;;
    pip)    if is_brew "$(pip_bin)"; then echo "brew upgrade python   (or: python3 -m pip install --upgrade pip)"; else echo "python3 -m pip install --upgrade pip"; fi;;
    pipenv) if is_brew pipenv; then echo "brew upgrade pipenv"; else echo "pip install --upgrade pipenv"; fi;;
    poetry) if is_brew poetry; then echo "brew upgrade poetry"; else echo "poetry self update"; fi;;
    pdm)    if is_brew pdm; then echo "brew upgrade pdm"; else echo "pdm self update"; fi;;
    pixi)   echo "pixi self-update";;
    bundler) echo "gem update bundler   (or: gem install bundler)";;
    hex)    echo "mix local.hex --force";;
    mise)   if is_brew mise; then echo "brew upgrade mise"; else echo "mise self-update"; fi;;
  esac
}

# version_ge A B → 0 if A >= B (dotted numeric versions)
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".");
    for (i = 1; i <= (n > m ? n : m); i++) { p = (i <= n ? x[i] : 0) + 0; q = (i <= m ? y[i] : 0) + 0;
      if (p > q) exit 0; if (p < q) exit 1 }
    exit 0 }'
}

# check_version ID — warns if the installed tool is too old and records an upgrade hint
check_version() {
  local t="$1" min have
  min="$(tool_minver "$t")"; [ -n "$min" ] || return 0
  have="$(tool_version "$t")"; [ -n "$have" ] || return 0
  version_ge "$have" "$min" && return 0
  warn "installed $(tool_bin "$t") is $have, cooldown needs ≥ $min – the setting is written but ignored until you upgrade"
  UPGRADES="${UPGRADES}  $(tool_label "$t"): installed $have, needs ≥ $min"$'\n'"      $(tool_upgrade "$t")"$'\n'
}

# ver_badge ID — "0.12.5 ✔ (needs ≥ 0.9.17)" / "1.22.22 ✗ needs ≥ 4.10.0" / "(not installed, needs ≥ …)"
ver_badge() {
  local t="$1" min have bin
  min="$(tool_minver "$t")"; bin="$(tool_bin "$t")"
  [ -n "$bin" ] || return 0
  if [ "$t" = cargo ]; then
    if ! has cargo; then printf '%s(cargo not installed)%s' "$DIM" "$RESET"; return; fi
    have="$(tool_version cargo)"
    if cargo_native_ok; then printf '%scargo %s ✔ native%s' "$GREEN" "$(cargo --version 2>/dev/null | grep -q nightly && echo nightly || echo "$have")" "$RESET"
    else printf '%scargo %s (native needs ≥ 1.100 or nightly)%s' "$DIM" "$have" "$RESET"; fi
    if cargo cooldown --version >/dev/null 2>&1; then printf ' · %scargo-cooldown %s ✔%s' "$GREEN" "$(cargo cooldown --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)" "$RESET"
    else printf ' · %scargo-cooldown ✗ not installed%s' "$RED" "$RESET"; fi
    return
  fi
  if ! has "$bin"; then printf '%s(not installed%s)%s' "$DIM" "${min:+, needs ≥ $min}" "$RESET"; return; fi
  have="$(tool_version "$t")"
  [ -n "$have" ] || { printf '%s(version unknown%s)%s' "$YELLOW" "${min:+, needs ≥ $min}" "$RESET"; return; }
  [ -n "$min" ] || { printf '%s%s%s' "$DIM" "$have" "$RESET"; return; }
  if version_ge "$have" "$min"; then printf '%s%s ✔%s %s(needs ≥ %s)%s' "$GREEN" "$have" "$RESET" "$DIM" "$min" "$RESET"
  else printf '%s%s ✗ needs ≥ %s%s' "$RED" "$have" "$min" "$RESET"; fi
}

# ------------------------------------------------------------------ the prompt
# ask_days → DAYS = 1|2|3|0(off) ; returns 1 on skip
ask_days() {
  local ans
  while :; do
    printf '  1) 1 day   2) 2 days   3) 3 days   %s0) turn OFF%s   s) skip   [3]: ' "$RED" "$RESET"
    read -r ans || ans=s
    case "$ans" in
      ""|3) DAYS=3; return 0 ;;
      1|2)  DAYS=$ans; return 0 ;;
      0|o|O|off) DAYS=0; return 0 ;;
      s|S|q|Q|n|N) DAYS=""; return 1 ;;
    esac
  done
}

# ------------------------------------------------------------------ tool metadata
tool_label() {
  case "$1" in
    npm) echo "npm";;            pnpm) echo "pnpm";;        yarn) echo "Yarn (Berry)";;
    bun) echo "Bun";;            deno) echo "Deno";;        uv) echo "uv";;
    pip) echo "pip";;            pipenv) echo "pipenv";;    poetry) echo "Poetry";;
    pdm) echo "PDM";;            pixi) echo "pixi";;        cargo) echo "Cargo";;
    bundler) echo "Bundler (Ruby)";; hex) echo "Hex (Elixir mix)";; mise) echo "mise";;
    vscode) echo "VS Code extensions auto-update";;
    dependabot) echo "Dependabot";; renovate) echo "Renovate";;
  esac
}

# binary name whose absence should be shown as "(not installed)"
tool_bin() {
  case "$1" in
    npm) echo npm;; pnpm) echo pnpm;; yarn) echo yarn;; bun) echo bun;; deno) echo deno;;
    uv) echo uv;; pip) pip_bin;; pipenv) echo pipenv;; poetry) echo poetry;; pdm) echo pdm;;
    pixi) echo pixi;; cargo) echo cargo;; bundler) echo bundle;; hex) echo mix;; mise) echo mise;;
    *) echo "";;
  esac
}

pnpm_global_file() {
  case "$(uname -s)" in Darwin) echo "$HOME/Library/Preferences/pnpm/config.yaml";; *) echo "${XDG_CONFIG_HOME:-$HOME/.config}/pnpm/config.yaml";; esac
}
vscode_settings() {
  case "$(uname -s)" in Darwin) echo "$HOME/Library/Application Support/Code/User/settings.json";; *) echo "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json";; esac
}
renovate_file() {
  local f; for f in renovate.json .renovaterc .renovaterc.json .github/renovate.json .gitlab/renovate.json; do [ -f "$f" ] && { echo "$f"; return; }; done
}
dependabot_file() {
  [ -f .github/dependabot.yaml ] && { echo .github/dependabot.yaml; return; }; echo .github/dependabot.yml
}
mise_file() { [ -f .mise.toml ] && echo .mise.toml || echo mise.toml; }

# where the setting will be written (shown in the prompt)
tool_target() {
  local t="$1" scope="$2"
  if [ "$scope" = global ]; then
    case "$t" in
      npm) echo "~/.npmrc";;  pnpm) echo "$(pnpm_global_file | sed "s|^$HOME|~|")";;
      yarn) echo "~/.yarnrc.yml";;  bun) echo "~/.bunfig.toml";;
      uv) echo "~/.config/uv/uv.toml";;  pip) echo "pip config --user (install.uploaded-prior-to)";;
      pipenv) echo "~/.cooldowns.env (PIP_UPLOADED_PRIOR_TO)";;  poetry) echo "poetry config solver.min-release-age";;
      pdm) echo "pdm config strategy.exclude-newer";;  cargo) echo "${CARGO_HOME:-~/.cargo}/config.toml + cooldown.toml";;
      bundler) echo "bundle config --global cooldown";;  hex) echo "mix hex.config cooldown";;
      mise) echo "~/.config/mise/config.toml";;  vscode) echo "$(vscode_settings | sed "s|^$HOME|~|")";;
    esac
  else
    case "$t" in
      npm) echo ".npmrc";;
      pnpm) if [ -f pnpm-workspace.yaml ] || [ "$(major_of pnpm)" -ge 11 ] 2>/dev/null; then echo "pnpm-workspace.yaml"; else echo ".npmrc"; fi;;
      yarn) echo ".yarnrc.yml";;  bun) echo "bunfig.toml";;
      deno) if [ -f deno.jsonc ] && [ ! -f deno.json ]; then echo "deno.jsonc"; else echo "deno.json"; fi;;
      uv) if [ -f uv.toml ]; then echo "uv.toml"; elif [ -f pyproject.toml ]; then echo "pyproject.toml [tool.uv]"; else echo "uv.toml"; fi;;
      pip) echo "no project-level config (use global)";;
      pipenv) echo "Pipfile [pipenv]";;  poetry) echo "poetry.toml [solver]";;
      pdm) echo "pyproject.toml [tool.pdm.resolution]";;
      pixi) if [ -f pixi.toml ] || [ ! -f pyproject.toml ]; then echo "pixi.toml [workspace]"; else echo "pyproject.toml [tool.pixi.workspace]"; fi;;
      cargo) echo ".cargo/config.toml + cooldown.toml";;  bundler) echo ".bundle/config";;  hex) echo "mix.exs";;
      mise) echo "$(mise_file) [settings]";;
      dependabot) echo "$(dependabot_file)";;  renovate) echo "$(renovate_file)";;
    esac
  fi
}

# native cargo min-publish-age: nightly since 2026-06-21 (-Zmin-publish-age), stable from Rust 1.100
cargo_native_ok() {
  has cargo || return 1
  cargo --version 2>/dev/null | grep -q nightly && return 0
  version_ge "$(tool_version cargo)" 1.100.0
}

# cargo-cooldown pulls ~245 crates when compiled; prefer the prebuilt release binary.
cargo_cooldown_install_hint() {
  local asset
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) asset="cargo-cooldown-aarch64-apple-darwin-<ver>.tgz";;
    Darwin-x86_64) asset="cargo-cooldown-x86_64-apple-darwin-<ver>.tgz";;
    Linux-aarch64) asset="cargo-cooldown-aarch64-unknown-linux-gnu-<ver>.tgz";;
    Linux-x86_64) asset="cargo-cooldown-x86_64-unknown-linux-gnu-<ver>.tgz";;
    *) asset="";;
  esac
  printf 'prebuilt binary (no compiling): https://github.com/dertin/cargo-cooldown/releases%s\n' "${asset:+  → $asset, verify SHA256SUMS, unpack into ~/.cargo/bin}"
  printf 'or compile with pinned deps (~245 crates): cargo install --locked cargo-cooldown\n'
  printf 'then use:  cargo cooldown build | check | update'
}

# ------------------------------------------------------------------ per-tool apply: do_<tool> SCOPE DAYS
do_npm() {
  local f=".npmrc"; [ "$1" = global ] && f="$HOME/.npmrc"
  kv_set "$f" min-release-age "$2"
  if [ "$2" = 0 ]; then off "npm: min-release-age=0 → $f"; else ok "npm: min-release-age=$2 (days) → $f"; fi
  hint "exceptions: min-release-age-exclude[]=<pkg>  (also read by Deno ≥ 2.6)"
}

do_pnpm() {
  local m=$(( $2 * 1440 )) f
  if [ "$1" = global ]; then
    f="$(pnpm_global_file)"
    if has pnpm && PATH="$HOME/Library/pnpm/bin:$PATH" pnpm config set -g minimumReleaseAge "$m" >/dev/null 2>&1; then :; else yaml_set "$f" minimumReleaseAge "$m"; fi
  else
    if [ -f pnpm-workspace.yaml ] || [ "$(major_of pnpm)" -ge 11 ] 2>/dev/null; then f=pnpm-workspace.yaml; yaml_set "$f" minimumReleaseAge "$m"
    else f=.npmrc; kv_set "$f" minimum-release-age "$m"; fi
  fi
  if [ "$2" = 0 ]; then off "pnpm: minimumReleaseAge=0 → $f"; else ok "pnpm: minimumReleaseAge=$m (minutes = $2 days) → $f"; fi
  hint "pnpm 11 defaults to 1 day · exceptions: minimumReleaseAgeExclude: [pkg]"
}

do_yarn() {
  local m=$(( $2 * 1440 )) f=".yarnrc.yml"; [ "$1" = global ] && f="$HOME/.yarnrc.yml"
  yaml_set "$f" npmMinimalAgeGate "$m"
  if [ "$2" = 0 ]; then off "Yarn: npmMinimalAgeGate: 0 → $f"; else ok "Yarn: npmMinimalAgeGate: $m (minutes = $2 days) → $f"; fi
  hint "Yarn 1 'classic' ignores it; Yarn 4.15 defaults to 1 day · exceptions: npmPreapprovedPackages: [pkg]"
}

do_bun() {
  local s=$(( $2 * 86400 )) f="bunfig.toml"; [ "$1" = global ] && f="$HOME/.bunfig.toml"
  toml_set "$f" install minimumReleaseAge "$s"
  if [ "$2" = 0 ]; then off "Bun: [install] minimumReleaseAge = 0 → $f"; else ok "Bun: [install] minimumReleaseAge = $s (seconds = $2 days) → $f"; fi
  hint "exceptions: minimumReleaseAgeExcludes = [\"pkg\"]"
}

do_deno() {
  local f v
  if [ "$1" = global ]; then skip "Deno: no user-level config (default is 24h since 2.9). Set it per project, or via npm's ~/.npmrc min-release-age."; return; fi
  if [ -f deno.json ]; then f=deno.json; elif [ -f deno.jsonc ]; then f=deno.jsonc; else f=deno.json; printf '{}\n' > "$f"; fi
  if [ "$2" = 0 ]; then v='0'; else v="\"P${2}D\""; fi
  if json_set "$f" 'if (.minimumDependencyAge|type) == "object" then .minimumDependencyAge.age = $v else .minimumDependencyAge = $v end' --argjson v "$v"; then
    if [ "$2" = 0 ]; then off "Deno: minimumDependencyAge: 0 → $f"; else ok "Deno: minimumDependencyAge: $v → $f"; fi
  else
    warn "Deno: could not edit $f (jq missing or file has comments). Add manually:  \"minimumDependencyAge\": $v"
  fi
  hint "Deno 2.9 defaults to 24h · exceptions: {\"age\": \"P3D\", \"exclude\": [\"npm:pkg\"]}"
}

do_uv() {
  local f sec=""
  if [ "$1" = global ]; then f="${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv.toml"
  elif [ -f uv.toml ]; then f=uv.toml
  elif [ -f pyproject.toml ]; then f=pyproject.toml; sec="tool.uv"
  else f=uv.toml; fi
  if [ "$2" = 0 ]; then toml_del "$f" "$sec" exclude-newer; off "uv: exclude-newer removed (no default) → $f"
  else toml_set "$f" "$sec" exclude-newer "\"$2 days\""; ok "uv: exclude-newer = \"$2 days\" → $f${sec:+ [$sec]}"; fi
  hint "env UV_EXCLUDE_NEWER overrides · exceptions: exclude-newer-package = { pkg = false }"
}

do_pip() {
  local p; p="$(pip_bin)"
  if [ "$1" = local ]; then skip "pip: has no project-level config – configure it in global mode (or export PIP_UPLOADED_PRIOR_TO=P3D)."; return; fi
  if [ "$2" = 0 ]; then "$p" config --user unset install.uploaded-prior-to >/dev/null 2>&1; off "pip: install.uploaded-prior-to removed (no default)"
  else "$p" config --user set install.uploaded-prior-to "P${2}D" >/dev/null && ok "pip: install.uploaded-prior-to = P${2}D → $(pip_user_conf "$p")"; fi
  hint "bypass once: env -u PIP_UPLOADED_PRIOR_TO pip install pkg==x.y"
}

do_pipenv() {
  if [ "$1" = global ]; then
    if [ "$2" = 0 ]; then env_del PIP_UPLOADED_PRIOR_TO; off "pipenv: PIP_UPLOADED_PRIOR_TO removed from $ENV_FILE"
    else env_set PIP_UPLOADED_PRIOR_TO "P${2}D"; ok "pipenv: export PIP_UPLOADED_PRIOR_TO=P${2}D → $ENV_FILE (pipenv inherits pip's env var; also affects pip)"; fi
  else
    toml_set Pipfile pipenv cool-down-period "\"${2}d\""
    if [ "$2" = 0 ]; then off "pipenv: [pipenv] cool-down-period = \"0d\" → Pipfile"; else ok "pipenv: [pipenv] cool-down-period = \"${2}d\" → Pipfile"; fi
  fi
}

do_poetry() {
  if [ "$1" = global ]; then
    poetry config solver.min-release-age "$2" >/dev/null 2>&1 || { warn "poetry config failed"; return; }
    if [ "$2" = 0 ]; then off "Poetry: solver.min-release-age = 0 (poetry config)"; else ok "Poetry: solver.min-release-age = $2 (days, poetry config)"; fi
  else
    if has poetry && poetry config --local solver.min-release-age "$2" >/dev/null 2>&1; then :; else toml_set poetry.toml solver min-release-age "$2"; fi
    if [ "$2" = 0 ]; then off "Poetry: [solver] min-release-age = 0 → poetry.toml"; else ok "Poetry: [solver] min-release-age = $2 → poetry.toml"; fi
  fi
  hint "exceptions: poetry config solver.min-release-age-exclude \"pkg1,pkg2\""
}

do_pdm() {
  if [ "$1" = global ]; then
    if [ "$2" = 0 ]; then pdm config --delete strategy.exclude-newer >/dev/null 2>&1; off "PDM: strategy.exclude-newer removed (no default)"
    else pdm config strategy.exclude-newer "${2}d" >/dev/null 2>&1 && ok "PDM: strategy.exclude-newer = ${2}d (pdm config)" || warn "pdm config failed"; fi
  else
    if [ "$2" = 0 ]; then toml_del pyproject.toml tool.pdm.resolution exclude-newer; off "PDM: exclude-newer removed → pyproject.toml [tool.pdm.resolution]"
    else toml_set pyproject.toml tool.pdm.resolution exclude-newer "\"${2}d\""; ok "PDM: exclude-newer = \"${2}d\" → pyproject.toml [tool.pdm.resolution]"; fi
  fi
}

do_pixi() {
  local f sec
  if [ "$1" = global ]; then skip "pixi: no user-level exclude-newer setting – set it per project (local mode)."; return; fi
  if [ -f pixi.toml ] || [ ! -f pyproject.toml ]; then f=pixi.toml; sec=workspace; else f=pyproject.toml; sec=tool.pixi.workspace; fi
  [ -f "$f" ] || { warn "pixi: no $f manifest here (run 'pixi init' first)"; return; }
  if [ "$2" = 0 ]; then toml_del "$f" "$sec" exclude-newer; off "pixi: exclude-newer removed → $f [$sec]"
  else toml_set "$f" "$sec" exclude-newer "\"${2}d\""; ok "pixi: exclude-newer = \"${2}d\" → $f [$sec]"; fi
  hint "exceptions: [pypi-exclude-newer] pkg = \"0d\""
}

do_cargo() {
  local f="cooldown.toml" c=".cargo/config.toml" v
  if [ "$1" = global ]; then f="${CARGO_HOME:-$HOME/.cargo}/cooldown.toml"; c="${CARGO_HOME:-$HOME/.cargo}/config.toml"; fi
  if [ "$2" = 0 ]; then v='"0"'; else v="\"$2 days\""; fi
  # native cargo (nightly -Z now, stable ≥ 1.100); stable < 1.100 ignores both tables silently
  toml_set "$c" registry global-min-publish-age "$v"
  toml_set "$c" unstable min-publish-age true
  # cargo-cooldown wrapper (works on any stable cargo today)
  toml_set "$f" registry global-min-publish-age "$v"
  if [ "$2" = 0 ]; then off "Cargo: [registry] global-min-publish-age = \"0\" → $c and $f"
  else ok "Cargo: [registry] global-min-publish-age = $v → $c (native) and $f (cargo-cooldown)"; fi
  if cargo_native_ok; then
    hint "native cargo supports it: plain  cargo build  applies the cooldown"
  else
    hint "native support needs Rust ≥ 1.100 (stable late Sept 2026) or nightly – switch a project:  cooldowns.sh --rust-nightly"
  fi
  if cargo cooldown --version >/dev/null 2>&1; then
    hint "until then:  cargo cooldown build | check | test | update"
  else
    warn "cargo-cooldown is NOT installed – on stable < 1.100 the setting only works through it:"
    hint "$(cargo_cooldown_install_hint)"
    case "$UPGRADES" in *"Cargo:"*) ;; *) UPGRADES="${UPGRADES}  Cargo: no cooldown support in cargo $(tool_version cargo) and cargo-cooldown missing"$'\n'"      cooldowns.sh --rust-nightly   (in the project: nightly + native cooldown)  – or wait for Rust 1.100"$'\n'"      $(cargo_cooldown_install_hint | sed '2,$s/^/      /')"$'\n';; esac
  fi
  hint "bypass once: CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow cargo update -p <crate> · exceptions (cargo-cooldown): [[allow.package]] crate = \"x\" min-publish-age = \"0\""
}

do_bundler() {
  local f
  if [ "$1" = global ]; then
    f="$HOME/.bundle/config"
    if has bundle && bundle config set --global cooldown "$2" >/dev/null 2>&1; then :; else yaml_set "$f" BUNDLE_COOLDOWN "\"$2\""; fi
  else
    f=".bundle/config"
    if has bundle && bundle config set --local cooldown "$2" >/dev/null 2>&1; then :; else yaml_set "$f" BUNDLE_COOLDOWN "\"$2\""; fi
  fi
  if [ "$2" = 0 ]; then off "Bundler: cooldown 0 → $f"; else ok "Bundler: cooldown $2 (days) → $f"; fi
  hint "per source: source \"https://gems.internal\", cooldown: 0"
}

do_hex() {
  local v="\"${2}d\"" f=mix.exs
  if [ "$1" = global ]; then
    mix hex.config cooldown "${2}d" >/dev/null 2>&1 || { warn "mix hex.config failed (Hex installed? try: mix local.hex)"; return; }
    if [ "$2" = 0 ]; then off "Hex: cooldown \"0d\" (mix hex.config)"; else ok "Hex: cooldown \"${2}d\" (mix hex.config)"; fi
  else
    export HEXV="$v"
    if grep -qE 'cooldown:[[:space:]]*"[^"]*"' "$f"; then
      perl -pi -e 's/cooldown:\s*"[^"]*"/cooldown: $ENV{HEXV}/' "$f" || { warn "Hex: editing $f failed"; return; }
    elif grep -qE '^[[:space:]]*hex:[[:space:]]*\[' "$f"; then
      perl -pi -e 's/^(\s*hex:\s*\[)/$1cooldown: $ENV{HEXV}, /' "$f" || { warn "Hex: editing $f failed"; return; }
    elif grep -qE '^[[:space:]]*app:' "$f"; then
      perl -pi -e 'if (!$d && /^(\s*)app:/) { $_ .= "$1hex: [cooldown: $ENV{HEXV}],\n"; $d = 1 }' "$f" || { warn "Hex: editing $f failed"; return; }
    else
      warn "Hex: could not find the project keyword list in $f – add  hex: [cooldown: $v]  to project/0 manually"; return
    fi
    if [ "$2" = 0 ]; then off "Hex: hex: [cooldown: \"0d\"] → $f"; else ok "Hex: hex: [cooldown: $v] → $f"; fi
  fi
  hint "exceptions: mix hex.config cooldown_exclude_repos '[\"hexpm:myorg\"]'"
}

do_mise() {
  local f v
  if [ "$1" = global ]; then f="${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml"; else f="$(mise_file)"; fi
  if [ "$2" = 0 ]; then v='"0s"'; else v="\"${2}d\""; fi
  toml_set "$f" settings minimum_release_age "$v"
  if [ "$2" = 0 ]; then off "mise: [settings] minimum_release_age = \"0s\" → $f"; else ok "mise: [settings] minimum_release_age = $v → $f"; fi
  hint "mise defaults to 24h · exceptions: minimum_release_age_excludes = [\"trivy\", \"npm:*\"]"
}

do_vscode() {
  local f h=$(( $2 * 24 )); f="$(vscode_settings)"
  [ -f "$f" ] || { skip "VS Code: settings.json not found ($f)"; return; }
  if json_set "$f" '."extensions.autoUpdateDelay" = $h' --argjson h "$h"; then
    if [ "$2" = 0 ]; then off "VS Code: extensions.autoUpdateDelay = 0 → $f"; else ok "VS Code: extensions.autoUpdateDelay = $h (hours = $2 days) → $f"; fi
  else
    warn "VS Code: settings.json has comments/trailing commas – add manually:  \"extensions.autoUpdateDelay\": $h"
  fi
  hint "needs VS Code ≥ 1.125 · delays extension UPDATES only, not first installs"
}

do_dependabot() {
  local f d="$2" tmp; f="$(dependabot_file)"
  if [ -f "$f" ]; then
    _prep "$f"; tmp="$(_tmp_for "$f")"
    if grep -qE '^[[:space:]]*default-days:' "$f"; then
      awk -v d="$d" '/^[[:space:]]*default-days:/ { sub(/default-days:[[:space:]]*[0-9]+/, "default-days: " d) } { print }' "$f" > "$tmp"
    else
      awk -v d="$d" '
        /^[[:space:]]*-[[:space:]]*package-ecosystem:/ { print; match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH); print ind "  cooldown:"; print ind "    default-days: " d; next }
        { print }' "$f" > "$tmp"
    fi
    mv "$tmp" "$f"
  else
    mkdir -p .github
    {
      echo "version: 2"; echo "updates:"
      local eco ecos=""
      [ -f package.json ] && ecos="$ecos npm"
      { [ -f requirements.txt ] || [ -f pyproject.toml ] || [ -f Pipfile ]; } && ecos="$ecos pip"
      [ -f Cargo.toml ] && ecos="$ecos cargo"
      [ -f Gemfile ] && ecos="$ecos bundler"
      [ -f mix.exs ] && ecos="$ecos mix"
      [ -d .github/workflows ] && ecos="$ecos github-actions"
      [ -n "$ecos" ] || ecos="npm"
      for eco in $ecos; do
        printf '  - package-ecosystem: "%s"\n    directory: "/"\n    schedule:\n      interval: "weekly"\n    cooldown:\n      default-days: %s\n' "$eco" "$d"
      done
    } > "$f"
    hint "created $f with detected ecosystems:$ecos"
  fi
  if [ "$d" = 0 ]; then off "Dependabot: cooldown.default-days: 0 → $f"; else ok "Dependabot: cooldown.default-days: $d → $f"; fi
  hint "Dependabot defaults to 3 days since July 2026 · security updates are exempt"
}

do_renovate() {
  local f v; f="$(renovate_file)"
  [ -n "$f" ] || { f=renovate.json; printf '{\n  "$schema": "https://docs.renovatebot.com/renovate-schema.json"\n}\n' > "$f"; hint "created $f"; }
  v="$2 days"
  if json_set "$f" '.minimumReleaseAge = $v' --arg v "$v"; then
    if [ "$2" = 0 ]; then off "Renovate: minimumReleaseAge: \"0 days\" → $f"; else ok "Renovate: minimumReleaseAge: \"$v\" → $f"; fi
  else
    warn "Renovate: could not edit $f (jq missing or JSON5/comments) – add manually:  \"minimumReleaseAge\": \"$v\""
  fi
  hint "security updates are exempt by default · config:best-practices already sets 3 days for npm"
}

# ------------------------------------------------------------------ driver
# run_tool ID SCOPE — asks and applies one installer
run_tool() {
  local t="$1" scope="$2" label bin badge
  case "$CONFIGURED" in *" $t "*) return;; esac
  CONFIGURED="$CONFIGURED$t "
  label="$(tool_label "$t")"
  bin="$(tool_bin "$t")"
  badge="$(ver_badge "$t")"
  if [ -n "$bin" ] && ! has "$bin"; then
    case "$t" in
      pip|poetry|pdm|hex) printf '\n%s%s%s %s\n' "$BOLD" "$label" "$RESET" "$badge"; skip "'$bin' not installed – needs the tool to write its config, skipped"; return;;
    esac
  fi
  case "$t:$scope" in
    deno:global|pixi:global) printf '\n%s%s%s %s\n' "$BOLD" "$label" "$RESET" "$badge"; "do_$t" "$scope" 0; return;;
    pip:local) printf '\n%s%s%s %s\n' "$BOLD" "$label" "$RESET" "$badge"; do_pip local 0; return;;
    vscode:global) [ -f "$(vscode_settings)" ] || { printf '\n%s%s%s\n' "$BOLD" "$label" "$RESET"; skip "VS Code: no settings.json found, skipped"; return; };;
  esac
  printf '\n%s%s%s %s  %s→ %s%s\n' "$BOLD" "$label" "$RESET" "$badge" "$DIM" "$(tool_target "$t" "$scope")" "$RESET"
  check_version "$t"
  if ask_days; then
    "do_$t" "$scope" "$DAYS"
  else
    skip "skipped"
  fi
}

GLOBAL_TOOLS="npm pnpm yarn bun deno uv pip pipenv poetry pdm pixi cargo bundler hex mise vscode"
LOCAL_TOOLS="npm pnpm yarn bun deno uv pip pipenv poetry pdm pixi cargo bundler hex mise dependabot renovate"

detect_local() {
  local d="" js=""
  [ -f package-lock.json ] && { d="$d npm"; js=1; }
  { [ -f pnpm-lock.yaml ] || [ -f pnpm-workspace.yaml ]; } && { d="$d pnpm"; js=1; }
  { [ -f yarn.lock ] || [ -f .yarnrc.yml ]; } && { d="$d yarn"; js=1; }
  { [ -f bun.lock ] || [ -f bun.lockb ] || [ -f bunfig.toml ]; } && { d="$d bun"; js=1; }
  { [ -f deno.json ] || [ -f deno.jsonc ]; } && { d="$d deno"; js=1; }
  [ -f package.json ] && [ -z "$js" ] && d="$d npm"
  local py=""
  { [ -f uv.lock ] || [ -f uv.toml ] || grep -qE '^\[tool\.uv' pyproject.toml 2>/dev/null; } && { d="$d uv"; py=1; }
  [ -f Pipfile ] && { d="$d pipenv"; py=1; }
  { [ -f poetry.lock ] || grep -qE '^\[tool\.poetry' pyproject.toml 2>/dev/null; } && { d="$d poetry"; py=1; }
  { [ -f pdm.lock ] || grep -qE '^\[tool\.pdm' pyproject.toml 2>/dev/null; } && { d="$d pdm"; py=1; }
  { [ -f pixi.toml ] || grep -qE '^\[tool\.pixi' pyproject.toml 2>/dev/null; } && { d="$d pixi"; py=1; }
  [ -f requirements.txt ] && [ -z "$py" ] && d="$d pip"
  [ -f Cargo.toml ] && d="$d cargo"
  [ -f Gemfile ] && d="$d bundler"
  [ -f mix.exs ] && d="$d hex"
  { [ -f mise.toml ] || [ -f .mise.toml ]; } && d="$d mise"
  { [ -f .github/dependabot.yml ] || [ -f .github/dependabot.yaml ] || [ -d .github/workflows ]; } && d="$d dependabot"
  [ -n "$(renovate_file)" ] && d="$d renovate"
  echo "$d"
}

run_global() {
  printf '\n%s== GLOBAL cooldowns (user-wide) ==%s\n' "$CYAN" "$RESET"
  local t; for t in $GLOBAL_TOOLS; do run_tool "$t" global; done
}

run_local() {
  printf '\n%s== LOCAL cooldowns for %s ==%s\n' "$CYAN" "$PWD" "$RESET"
  local detected t ans i n choice remaining
  detected="$(detect_local)"
  if [ -n "$detected" ]; then
    printf 'Detected:%s%s%s\n' "$BOLD" "$detected" "$RESET"
    for t in $detected; do run_tool "$t" local; done
  else
    warn "no known project files found in $PWD"
  fi
  while :; do
    remaining=""
    for t in $LOCAL_TOOLS; do case "$CONFIGURED" in *" $t "*) ;; *) remaining="$remaining $t";; esac; done
    [ -n "$remaining" ] || break
    printf '\n%sSetup more?%s [y/N]: ' "$BOLD" "$RESET"
    read -r ans || ans=n
    case "$ans" in y|Y|yes) ;; *) break;; esac
    i=0
    for t in $remaining; do i=$((i + 1)); printf '  %2d) %s\n' "$i" "$(tool_label "$t")"; done
    printf '  choose number (Enter = done): '
    read -r choice || choice=""
    [ -n "$choice" ] || break
    i=0
    for t in $remaining; do i=$((i + 1)); [ "$i" = "$choice" ] && run_tool "$t" local; done
  done
}

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Explain why `cargo` is not nightly although rust-toolchain.toml says so.
cargo_bypass_diagnosis() {
  local v="$1" onpath proxydir
  onpath="$(command -v cargo)"
  if [ -n "${RUSTUP_TOOLCHAIN:-}" ]; then
    warn "active cargo is '$v': RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN overrides rust-toolchain.toml – unset it"
    return
  fi
  if ! rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
    warn "active cargo is still '$v' – nightly is not installed yet; the next cargo call installs it"
    return
  fi
  # nightly is installed and rustup honours the file, so the cargo on PATH must bypass rustup
  case "$onpath" in
    */toolchains/*)
      warn "active cargo is '$v' because PATH points straight at a toolchain, bypassing rustup:"
      hint "  $onpath"
      hint "rustup itself resolves this directory to: $(rustup show active-toolchain 2>/dev/null)"
      proxydir=""
      if has brew && [ -x "$(brew --prefix rustup 2>/dev/null)/bin/cargo" ]; then proxydir="$(brew --prefix rustup)/bin"
      elif [ -x "$HOME/.cargo/bin/cargo" ]; then proxydir="$HOME/.cargo/bin"; fi
      if [ -n "$proxydir" ]; then
        hint "fix: put the rustup proxies first and drop the hardcoded toolchain dir from your shell config:"
        hint "  export PATH=\"$proxydir:\$PATH\"        # rustup proxies (cargo, rustc, …) read rust-toolchain.toml"
        grep -nF 'toolchains/' "$ZSHRC" 2>/dev/null | head -3 | while IFS= read -r l; do hint "  ~/.zshrc:$l"; done
      else
        hint "fix: put the directory with rustup's cargo/rustc proxies first in PATH (rustup-init: ~/.cargo/bin; Homebrew: \$(brew --prefix rustup)/bin)"
      fi;;
    *)
      warn "active cargo is '$v' although rustup resolves this directory to '$(rustup show active-toolchain 2>/dev/null)'"
      hint "cargo on PATH: $onpath · rustup would run: $(rustup which cargo 2>/dev/null)";;
  esac
}

# --rust-nightly: pin the current Rust project to nightly and enable cargo's native min-publish-age
rust_nightly() {
  local ans v c=".cargo/config.toml"
  has rustup || die "rustup not found – install it from https://rustup.rs"
  [ -f Cargo.toml ] || die "no Cargo.toml in $PWD – run this inside a Rust project"
  printf '%s== Rust nightly + native cargo cooldown for %s ==%s\n\n' "$CYAN" "$PWD" "$RESET"

  # 1. nightly toolchain
  if rustup toolchain list 2>/dev/null | grep -q '^nightly'; then
    ok "nightly toolchain present: $(rustup run nightly cargo --version 2>/dev/null)"
  else
    printf '%sInstall the nightly toolchain now?%s  (rustup toolchain install nightly, a few hundred MB)  [Y/n]: ' "$BOLD" "$RESET"
    read -r ans || ans=n
    case "$ans" in
      n|N|no) warn "not installed – rustup will fetch nightly automatically on the first cargo call in this project";;
      *) if rustup toolchain install nightly; then ok "nightly toolchain installed: $(rustup run nightly cargo --version 2>/dev/null)"
         else die "rustup toolchain install nightly failed"; fi;;
    esac
  fi

  # 2. pin the project
  toml_set rust-toolchain.toml toolchain channel '"nightly"'
  ok "rust-toolchain.toml: [toolchain] channel = \"nightly\"  (only this project uses nightly)"

  # 3. native cooldown
  printf '\n%sCargo native cooldown%s  %s→ %s%s\n' "$BOLD" "$RESET" "$DIM" "$c" "$RESET"
  if ask_days; then
    if [ "$DAYS" = 0 ]; then v='"0"'; else v="\"$DAYS days\""; fi
    toml_set "$c" unstable min-publish-age true
    toml_set "$c" registry global-min-publish-age "$v"
    if [ "$DAYS" = 0 ]; then off "Cargo: [registry] global-min-publish-age = \"0\" → $c"
    else ok "Cargo: [unstable] min-publish-age = true + [registry] global-min-publish-age = $v → $c"; fi
  else
    skip "cooldown value not changed"
  fi

  # 4. verify what cargo resolves to here now
  v="$(cargo --version 2>/dev/null)"
  case "$v" in
    *nightly*) ok "active cargo in this directory: $v";;
    "") warn "cargo not found on PATH";;
    *) cargo_bypass_diagnosis "$v";;
  esac
  hint "plain  cargo build / update  now applies the cooldown · bypass once: CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow cargo update -p <crate>"
  hint "back to stable: rm rust-toolchain.toml   (the config keys are ignored by stable < 1.100 and used natively from Rust 1.100 on)"
  printf '\n%s== Summary ==%s\n%s' "$CYAN" "$RESET" "${SUMMARY:-  nothing changed}"$'\n'
  exit 0
}

# --add-zshrc: create the "cooldowns" alias in ~/.zshrc (idempotent)
add_zshrc_alias() {
  local self line
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  self="${self/#$HOME/\$HOME}"
  line="alias cooldowns=\"$self\""
  if grep -qE '^alias cooldowns=' "$ZSHRC" 2>/dev/null; then
    if grep -qF "$line" "$ZSHRC"; then
      ok "alias already present in $ZSHRC: $line"
    else
      set_line "$ZSHRC" '^alias cooldowns=' "$line"
      ok "alias updated in $ZSHRC: $line"
    fi
  else
    printf '\n# dependency cooldowns (managed by cooldowns.sh)\n%s\n' "$line" >> "$ZSHRC"
    ok "alias added to $ZSHRC: $line"
  fi
  hint "open a new shell or run:  source ~/.zshrc   then type:  cooldowns"
  exit 0
}

main() {
  local scope="${1:-}" ans
  case "$scope" in
    -h|--help|help) usage;;
    --add-zshrc) add_zshrc_alias;;
    --rust-nightly) rust_nightly;;
    g|global) scope=global;;
    l|local) scope=local;;
    "")
      printf '%sDependency cooldowns%s  %s(https://cooldowns.dev)%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
      printf 'Scope?  1) global (user-wide, all installers)   2) local (project: %s)  [1]: ' "$PWD"
      read -r ans || ans=1
      case "$ans" in 2|l|local) scope=local;; *) scope=global;; esac;;
    *) die "unknown argument '$scope' (use global | local | --add-zshrc | --rust-nightly | -h)";;
  esac
  if [ "$scope" = global ]; then run_global; else run_local; fi
  printf '\n%s== Summary ==%s\n%s' "$CYAN" "$RESET" "${SUMMARY:-  nothing changed}"$'\n'
  if [ -n "$UPGRADES" ]; then
    printf '%s== Upgrade needed%s %s(installed version too old for cooldowns – settings are in place and take effect after upgrading)%s\n%s' \
      "$YELLOW" "$RESET" "$DIM" "$RESET" "$UPGRADES"
  fi
}

# Run only when executed, not when sourced (for testing). The explicit exit matters:
# bash reads scripts incrementally, so without it an edit to this file while a run is
# still at the prompts would make bash parse garbage after main returns.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
