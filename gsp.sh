#!/usr/bin/env bash
# gsp — SSH keys and git identities bound to project root folders.
#
# The idea: a root folder (say ~/work/mechta) is a profile. Every repository
# inside it automatically uses its own SSH key and its own user.name/user.email,
# and clone URLs stay untouched.
#
# The key is picked by ssh itself through `Match host ... exec ...` in
# ~/.ssh/config, so it works during `git clone` (when there is no repo yet)
# as well as on fetch/push inside a repository.

set -euo pipefail

GSP_VERSION="1.1.0"

SELF="${BASH_SOURCE[0]}"
if command -v realpath >/dev/null 2>&1; then
	SELF="$(realpath "$SELF")"
fi

CONFIG_DIR="$HOME/.config/gsp"
PROFILE_DIR="$CONFIG_DIR/profiles"
GITCONFIG_D="$CONFIG_DIR/gitconfig.d"
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
GITCONFIG="$HOME/.gitconfig"
BIN_DIR="$HOME/.local/bin"
FISH_COMPLETIONS="$HOME/.config/fish/completions"

BEGIN_MARK="# >>> gsp managed — do not edit by hand >>>"
END_MARK="# <<< gsp managed <<<"
RC_BEGIN="# >>> gsp >>>"
RC_END="# <<< gsp <<<"

DRY_RUN=0
declare -A BACKED_UP=()

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
	C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
	C_R=''; C_G=''; C_Y=''; C_C=''; C_B=''; C_D=''; C_0=''
fi

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*UTF-8*|*utf8*|*UTF8*)
		S_OK='✓'; S_BAD='✗'; S_WARN='!'; S_ARROW='→'; S_DOT='●'
		S_HR='─'; S_TL='┌'; S_BL='└'; S_VB='│' ;;
	*)
		S_OK='+'; S_BAD='x'; S_WARN='!'; S_ARROW='->'; S_DOT='*'
		S_HR='-'; S_TL='+'; S_BL='+'; S_VB='|' ;;
esac

# ── output ───────────────────────────────────────────────────────────────────

term_width() {
	local w=''
	w=${COLUMNS:-}
	if [ -z "$w" ] && command -v tput >/dev/null 2>&1; then
		w=$(tput cols 2>/dev/null || true)
	fi
	case "$w" in ''|*[!0-9]*) w=80 ;; esac
	[ "$w" -ge 40 ] || w=40
	[ "$w" -le 84 ] || w=84
	printf '%s\n' "$w"
}

repeat_char() { # char count
	local out
	out=$(printf '%*s' "$2" '')
	printf '%s' "${out// /$1}"
}

# Collapse $HOME to ~ — display only, never for anything written to disk.
short() { printf '%s' "${1/#$HOME/\~}"; }

say()  { printf '%s\n' "$*" >&2; }
note() { printf '%s%s%s\n' "$C_D" "$*" "$C_0" >&2; }
ok()   { printf '  %s%s%s %s\n' "$C_G" "$S_OK" "$C_0" "$*" >&2; }
bad()  { printf '  %s%s%s %s\n' "$C_R" "$S_BAD" "$C_0" "$*" >&2; }
warn() { printf '  %s%s%s %s\n' "$C_Y" "$S_WARN" "$C_0" "$*" >&2; }
step() { printf '  %s%s%s %s\n' "$C_C" "$S_ARROW" "$C_0" "$*" >&2; }
die()  { printf '\n  %s%s error%s %s\n\n' "$C_R$C_B" "$S_BAD" "$C_0" "$*" >&2; exit 1; }

title() { # section heading with a rule the width of the terminal
	local w text
	w=$(term_width)
	text=$*
	printf '\n%s%s%s\n' "$C_B$C_C" "$text" "$C_0" >&2
	printf '%s%s%s\n' "$C_D" "$(repeat_char "$S_HR" "$w")" "$C_0" >&2
}

field() { # label value — aligned key/value line
	printf '  %s%-11s%s %s\n' "$C_D" "$1" "$C_0" "$2" >&2
}

box_top() { # title
	local w text pad
	w=$(term_width)
	text=$1
	pad=$((w - ${#text} - 4))
	[ "$pad" -ge 0 ] || pad=0
	printf '\n%s%s%s %s%s%s %s%s%s\n' \
		"$C_C" "$S_TL$S_HR" "$C_0" \
		"$C_B" "$text" "$C_0" \
		"$C_C$C_D" "$(repeat_char "$S_HR" "$pad")" "$C_0" >&2
}

box_line() { printf '%s%s%s %s\n' "$C_C" "$S_VB" "$C_0" "$*" >&2; }

box_bottom() {
	local w
	w=$(term_width)
	printf '%s%s%s%s\n\n' "$C_C" "$S_BL" "$(repeat_char "$S_HR" $((w - 1)))" "$C_0" >&2
}

dry() { [ "$DRY_RUN" -eq 1 ]; }

# ── file helpers ─────────────────────────────────────────────────────────────

ensure_dir() { # path mode
	local d=$1 mode=${2:-755}
	if [ -d "$d" ]; then return 0; fi
	if dry; then note "[dry-run] mkdir -p $(short "$d") (mode $mode)"; return 0; fi
	mkdir -p "$d"
	chmod "$mode" "$d"
}

backup_once() { # file
	local f=$1 ts
	[ -f "$f" ] || return 0
	[ -z "${BACKED_UP[$f]:-}" ] || return 0
	ts=$(date +%Y%m%d-%H%M%S)
	if dry; then
		note "[dry-run] backup $(short "$f") → $(short "$f").gsp-bak.$ts"
	else
		cp -p "$f" "$f.gsp-bak.$ts"
		note "    backup: $(short "$f").gsp-bak.$ts"
	fi
	BACKED_UP[$f]=1
}

atomic_write() { # file mode  (content on stdin)
	local f=$1 mode=$2 tmp content
	content=$(cat)
	if dry; then
		title "$(short "$f")"
		printf '%s\n' "$content" >&2
		return 0
	fi
	# Nothing changed — leave the file alone and do not pile up backups.
	if [ -f "$f" ] && printf '%s\n' "$content" | cmp -s - "$f"; then
		chmod "$mode" "$f"
		return 0
	fi
	backup_once "$f"
	tmp=$(mktemp "$f.gsp-tmp.XXXXXX")
	printf '%s\n' "$content" >"$tmp"
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$f"
}

# Drops the managed section, keeps everything else untouched.
strip_block() { # file
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
		$0 == b { skip = 1; next }
		$0 == e { skip = 0; next }
		!skip   { print }
	' "$1"
}

# Trims leading and trailing blank lines, keeps the inner ones.
trim_blank_lines() {
	awk '
		/^[[:space:]]*$/ { if (seen) pending++; next }
		{ while (pending > 0) { print ""; pending-- } seen = 1; print }
	'
}

# Replaces the managed section of a file. The block comes in on stdin.
write_managed_block() { # file position(top|bottom) mode
	local file=$1 position=$2 mode=$3
	local block rest out
	block=$(cat)
	rest=""
	if [ -f "$file" ]; then
		rest=$(strip_block "$file" | trim_blank_lines)
	fi
	if [ "$position" = top ]; then
		out=$(
			printf '%s\n' "$block"
			if [ -n "$rest" ]; then printf '\n%s\n' "$rest"; fi
		)
	else
		out=$(
			if [ -n "$rest" ]; then printf '%s\n\n' "$rest"; fi
			printf '%s\n' "$block"
		)
	fi
	printf '%s\n' "$out" | atomic_write "$file" "$mode"
}

# ── profiles ─────────────────────────────────────────────────────────────────

profile_path() { printf '%s/%s.conf\n' "$PROFILE_DIR" "$1"; }

profile_exists() { [ -f "$(profile_path "$1")" ]; }

profile_names() {
	local f n
	[ -d "$PROFILE_DIR" ] || return 0
	for f in "$PROFILE_DIR"/*.conf; do
		[ -e "$f" ] || continue
		n=${f##*/}
		printf '%s\n' "${n%.conf}"
	done
}

# First value of a key. The file is only ever read, never executed.
profile_get() { # name key
	local f line
	f=$(profile_path "$1")
	[ -f "$f" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			"$2="*) printf '%s\n' "${line#"$2"=}"; return 0 ;;
		esac
	done <"$f"
	return 1
}

# Lines of "host<TAB>key-path"
profile_identities() { # name
	local f line
	f=$(profile_path "$1")
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			identity=*) printf '%s\n' "${line#identity=}" ;;
		esac
	done <"$f"
}

profile_hosts() { # name
	local host rest
	while IFS=$'\t' read -r host rest; do
		[ -n "$host" ] || continue
		printf '%s\n' "$host"
	done < <(profile_identities "$1")
}

identity_key() { # name host
	local host key
	while IFS=$'\t' read -r host key; do
		if [ "$host" = "$2" ]; then printf '%s\n' "$key"; return 0; fi
	done < <(profile_identities "$1")
	return 1
}

# Rewrites the conf file: header plus the identity lines given on stdin.
profile_write() { # name root user_name user_email
	local name=$1 root=$2 uname=$3 uemail=$4
	ensure_dir "$PROFILE_DIR" 700
	{
		printf '# gsp profile "%s" — change it with `gsp`, not by hand\n' "$name"
		printf 'root=%s\n' "$root"
		printf 'user_name=%s\n' "$uname"
		printf 'user_email=%s\n' "$uemail"
		local line
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			printf 'identity=%s\n' "$line"
		done
	} | atomic_write "$(profile_path "$name")" 600
}

# ── validation and small helpers ─────────────────────────────────────────────

valid_profile_name() {
	case "$1" in
		[a-z0-9]*[!a-z0-9_-]*) return 1 ;;
		[a-z0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

valid_host() {
	case "$1" in
		''|*[[:space:]]*|*/*|*:*) return 1 ;;
		*) return 0 ;;
	esac
}

host_slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/_/g'; }

key_path_for() { # profile host
	printf '%s/id_ed25519_%s_%s\n' "$SSH_DIR" "$1" "$(host_slug "$2")"
}

# Absolute path to gsp that goes into ~/.ssh/config.
gsp_bin() {
	if [ -x "$BIN_DIR/gsp" ]; then
		printf '%s\n' "$BIN_DIR/gsp"
	else
		printf '%s\n' "$SELF"
	fi
}

tty_available() {
	{ exec 3</dev/tty; } 2>/dev/null || return 1
	exec 3<&-
	return 0
}

ask() { # prompt [default] -> stdout
	local prompt=$1 def=${2:-} reply=''
	if ! tty_available; then
		[ -n "$def" ] || die "no terminal to ask \"$prompt\" — pass the value as a flag"
		printf '%s\n' "$def"
		return 0
	fi
	if [ -n "$def" ]; then
		read -r -p "$(printf '  %s%s%s %s %s[%s]%s ' \
			"$C_C" "$S_ARROW" "$C_0" "$prompt" "$C_D" "$def" "$C_0")" reply </dev/tty || true
	else
		read -r -p "$(printf '  %s%s%s %s: ' "$C_C" "$S_ARROW" "$C_0" "$prompt")" reply </dev/tty || true
	fi
	[ -n "$reply" ] || reply=$def
	printf '%s\n' "$reply"
}

confirm() { # prompt [default answer: y|n]
	local reply='' def=${2:-n} hint='[y/N]'
	[ "$def" != y ] || hint='[Y/n]'
	tty_available || return 1
	read -r -p "$(printf '  %s?%s %s %s%s%s ' \
		"$C_C" "$C_0" "$1" "$C_D" "$hint" "$C_0")" reply </dev/tty || true
	[ -n "$reply" ] || reply=$def
	case "$reply" in
		y|Y|yes|YES|Yes) return 0 ;;
		*) return 1 ;;
	esac
}

ensure_key() { # path comment
	local key=$1 comment=$2
	if [ -f "$key" ]; then
		note "    key already exists: $(short "$key")"
		return 0
	fi
	if dry; then
		note "[dry-run] ssh-keygen -t ed25519 -f $(short "$key")"
		return 0
	fi
	ensure_dir "$SSH_DIR" 700
	ssh-keygen -t ed25519 -N '' -C "$comment" -f "$key" >/dev/null
	chmod 600 "$key"
	chmod 644 "$key.pub"
	ok "key created: $(short "$key")"
}

key_url_hint() { # host
	case "$1" in
		github.com)    printf 'https://github.com/settings/keys\n' ;;
		gitlab.com)    printf 'https://gitlab.com/-/user_settings/ssh_keys\n' ;;
		bitbucket.org) printf 'https://bitbucket.org/account/settings/ssh-keys/\n' ;;
		*)             printf 'the SSH keys page of %s\n' "$1" ;;
	esac
}

# The profile a directory belongs to (empty if none).
profile_for_dir() { # dir
	local dir=$1 p root
	dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
	for p in $(profile_names); do
		root=$(profile_get "$p" root) || continue
		case "$dir/" in
			"$root"/*) printf '%s\n' "$p"; return 0 ;;
		esac
	done
	return 1
}

# ── config generation ────────────────────────────────────────────────────────

# Profile roots must not nest: includeIf would apply both files and the
# winner would depend on their order.
check_roots_not_nested() {
	local a b ra rb
	for a in $(profile_names); do
		ra=$(profile_get "$a" root) || continue
		for b in $(profile_names); do
			[ "$a" != "$b" ] || continue
			rb=$(profile_get "$b" root) || continue
			case "$ra/" in
				"$rb"/*) die "root of profile \"$a\" ($ra) sits inside root of profile \"$b\" ($rb). Move them apart." ;;
			esac
		done
	done
}

# ── shell integration ────────────────────────────────────────────────────────

# $SHELL is the login shell from /etc/passwd, not the shell the user is
# typing in, so look at the parent process first.
invoking_shell() {
	local comm
	comm=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null | tr -d '[:space:]') || return 1
	comm=${comm##*/}
	comm=${comm#-}
	case "$comm" in
		zsh|bash|fish) printf '%s\n' "$comm"; return 0 ;;
	esac
	return 1
}

user_shell() {
	local s
	if s=$(invoking_shell); then
		printf '%s\n' "$s"
		return 0
	fi
	s=${SHELL:-}
	s=${s##*/}
	case "$s" in
		fish|zsh|bash) printf '%s\n' "$s" ;;
		*) printf 'sh\n' ;;
	esac
}

installed_shells() {
	local s
	for s in zsh bash fish; do
		if command -v "$s" >/dev/null 2>&1; then printf '%s\n' "$s"; fi
	done
	return 0
}

# Every installed shell, current one first.
ordered_shells() {
	local cur s
	cur=$(user_shell)
	if command -v "$cur" >/dev/null 2>&1; then printf '%s\n' "$cur"; fi
	for s in $(installed_shells); do
		[ "$s" != "$cur" ] || continue
		printf '%s\n' "$s"
	done
}

shell_rc() { # shell
	case "$1" in
		zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
		bash) printf '%s\n' "$HOME/.bashrc" ;;
		fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
		*)    printf '\n' ;;
	esac
}

path_hint() { # shell
	case "$1" in
		fish) printf 'fish_add_path ~/.local/bin\n' ;;
		zsh)  printf 'echo %s >> ~/.zshrc\n' "'export PATH=\"\$HOME/.local/bin:\$PATH\"'" ;;
		bash) printf 'echo %s >> ~/.bashrc\n' "'export PATH=\"\$HOME/.local/bin:\$PATH\"'" ;;
		*)    printf 'add ~/.local/bin to PATH\n' ;;
	esac
}

rc_snippet() { # shell
	printf '\n%s\n' "$RC_BEGIN"
	case "$1" in
		fish)
			printf 'fish_add_path -g "$HOME/.local/bin"\n'
			;;
		zsh)
			printf 'export PATH="$HOME/.local/bin:$PATH"\n'
			printf '[ -f "$HOME/.config/gsp/gsp.zsh" ] && source "$HOME/.config/gsp/gsp.zsh"\n'
			;;
		*)
			printf 'export PATH="$HOME/.local/bin:$PATH"\n'
			;;
	esac
	printf '%s\n' "$RC_END"
}

# Appends the PATH line (and the zsh completion hook) to shell rc files.
# mode: auto — ask; force — no questions; skip — leave rc files alone.
ensure_shell_integration() {
	local mode=${1:-auto}
	shift || true
	local shells=("$@")
	[ "$mode" != skip ] || return 0
	[ ${#shells[@]} -gt 0 ] || shells=("$(user_shell)")

	local sh rc done_any=0 in_path=0
	local pending=()
	local asked=0
	for sh in "${shells[@]}"; do
		[ -n "$sh" ] || continue
		rc=$(shell_rc "$sh")
		if [ -z "$rc" ]; then
			warn "unknown rc file for shell \"$sh\" — add it yourself: $(path_hint "$sh")"
			continue
		fi
		if [ -f "$rc" ] && grep -qF "$RC_BEGIN" "$rc"; then
			note "    already set up in $(short "$rc")"
			continue
		fi
		if dry; then
			note "[dry-run] append to $(short "$rc"):"
			rc_snippet "$sh" >&2
			continue
		fi
		local label="$sh" def=n
		if [ "$sh" = "$(user_shell)" ]; then
			label="$sh (current)"
			def=y
		fi
		if [ "$mode" != force ] && [ "$asked" -eq 0 ] && tty_available; then
			title "Shell setup"
			asked=1
		fi
		if [ "$mode" = force ] || confirm "Set up gsp for $label — append to $(short "$rc")?" "$def"; then
			backup_once "$rc"
			ensure_dir "$(dirname "$rc")" 755
			rc_snippet "$sh" >>"$rc"
			ok "updated $(short "$rc")"
			done_any=1
		else
			pending+=("$sh")
		fi
	done

	case ":$PATH:" in
		*":$BIN_DIR:"*) in_path=1 ;;
	esac

	if [ ${#pending[@]} -gt 0 ]; then
		if [ "$done_any" -eq 1 ] || [ "$in_path" -eq 1 ]; then
			# Something already works — a one-liner is enough for the rest.
			for sh in "${pending[@]}"; do
				note "    skipped $sh — later, if you want: gsp install --setup-path --shell $sh"
			done
		else
			box_top "One more step — otherwise gsp will not be found"
			local first=1
			for sh in "${pending[@]}"; do
				[ "$first" -eq 1 ] || box_line ""
				first=0
				rc=$(shell_rc "$sh")
				box_line "${C_B}$sh${C_0} — let gsp do it:"
				box_line ""
				box_line "  ${C_C}$(short "$BIN_DIR")/gsp install --setup-path --shell $sh${C_0}"
				box_line ""
				box_line "or add this to $(short "$rc"):"
				rc_snippet "$sh" | grep -v '^$' | while IFS= read -r line; do box_line "  ${C_D}$line${C_0}"; done
			done
			box_bottom
			return 0
		fi
	fi
	if [ "$done_any" -eq 1 ] || [ "$in_path" -eq 0 ]; then
		box_top "Reload your shell"
		box_line "  ${C_C}exec $(user_shell)${C_0}   ${C_D}(or just open a new terminal)${C_0}"
		box_bottom
	fi
}

check_root_free() { # name root — the root must not overlap another profile
	local self=$1 root=$2 other rb
	for other in $(profile_names); do
		[ "$other" != "$self" ] || continue
		rb=$(profile_get "$other" root) || continue
		case "$root/" in
			"$rb"/*) die "$root sits inside the root of profile \"$other\" ($rb) — pick another folder" ;;
		esac
		case "$rb/" in
			"$root"/*) die "profile \"$other\" ($rb) would end up inside $root — pick another folder" ;;
		esac
	done
}

gen_git_block() {
	local p root
	printf '%s\n' "$BEGIN_MARK"
	printf '# gsp profiles: commit name/email per root folder.\n'
	for p in $(profile_names); do
		root=$(profile_get "$p" root) || continue
		printf '\n[includeIf "gitdir:%s/"]\n' "$root"
		printf '\tpath = %s/%s.gitconfig\n' "$GITCONFIG_D" "$p"
	done
	printf '%s\n' "$END_MARK"
}

gen_ssh_block() {
	local p root host key bin
	bin=$(gsp_bin)
	printf '%s\n' "$BEGIN_MARK"
	printf '# SSH key chosen by the current directory: `gsp ssh-match` exits 0\n'
	printf '# when the working directory is inside a profile root folder.\n'
	for p in $(profile_names); do
		root=$(profile_get "$p" root) || continue
		printf '\n# profile %s → %s\n' "$p" "$root"
		while IFS=$'\t' read -r host key; do
			[ -n "$host" ] || continue
			printf 'Match host %s exec "%s ssh-match %s"\n' "$host" "$bin" "$p"
			printf '    IdentityFile %s\n' "$key"
			printf '    IdentitiesOnly yes\n'
		done < <(profile_identities "$p")
	done
	printf '%s\n' "$END_MARK"
}

gen_profile_gitconfig() { # name
	local p=$1
	printf '# Generated by gsp — edits are overwritten on `gsp apply`.\n'
	printf '[user]\n'
	printf '\tname = %s\n' "$(profile_get "$p" user_name || true)"
	printf '\temail = %s\n' "$(profile_get "$p" user_email || true)"
}

prune_stale_gitconfigs() {
	local f n
	[ -d "$GITCONFIG_D" ] || return 0
	for f in "$GITCONFIG_D"/*.gitconfig; do
		[ -e "$f" ] || continue
		n=${f##*/}
		n=${n%.gitconfig}
		if ! profile_exists "$n"; then
			if dry; then note "[dry-run] rm $(short "$f")"; else rm -f "$f"; fi
		fi
	done
}

cmd_apply() {
	check_roots_not_nested

	ensure_dir "$CONFIG_DIR" 700
	ensure_dir "$PROFILE_DIR" 700
	ensure_dir "$GITCONFIG_D" 700
	ensure_dir "$SSH_DIR" 700

	local p bin
	for p in $(profile_names); do
		gen_profile_gitconfig "$p" | atomic_write "$GITCONFIG_D/$p.gitconfig" 644
	done
	prune_stale_gitconfigs

	if [ ! -f "$GITCONFIG" ] && ! dry; then
		: >"$GITCONFIG"
		chmod 644 "$GITCONFIG"
	fi
	gen_git_block | write_managed_block "$GITCONFIG" bottom 644
	gen_ssh_block | write_managed_block "$SSH_CONFIG" top 600

	bin=$(gsp_bin)
	case "$bin" in
		*[[:space:]]*) warn "the path to gsp contains spaces ($bin) — ssh may fail to run Match exec" ;;
	esac
	if [ ! -x "$BIN_DIR/gsp" ]; then
		warn "gsp is not installed in $(short "$BIN_DIR") — ~/.ssh/config points at $(short "$bin")"
		warn "run \"gsp install\", or the config breaks once this file moves"
	fi
	dry || ok "config applied  ${C_D}(~/.ssh/config, ~/.gitconfig)${C_0}"
}

# ── commands ─────────────────────────────────────────────────────────────────

cmd_add() {
	local name='' root='' uname='' uemail='' host='' key='' arg
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
			--root)  root=${2:?--root needs a value}; shift 2 ;;
			--name)  uname=${2:?--name needs a value}; shift 2 ;;
			--email) uemail=${2:?--email needs a value}; shift 2 ;;
			--host)  host=${2:?--host needs a value}; shift 2 ;;
			--key)   key=${2:?--key needs a value}; shift 2 ;;
			-*)      die "unknown flag: $arg" ;;
			*)       [ -n "$name" ] && die "unexpected argument: $arg"; name=$arg; shift ;;
		esac
	done

	local interactive=0
	[ -n "$name" ] && [ -n "$root" ] && [ -n "$uname" ] && [ -n "$uemail" ] && [ -n "$host" ] || interactive=1
	if [ "$interactive" -eq 1 ]; then
		title "New profile"
		note "  A profile is a root folder: every repo inside it gets its own key."
	fi

	[ -n "$name" ] || name=$(ask "Profile name (e.g. work or pet)")
	valid_profile_name "$name" || die "profile name must match [a-z0-9][a-z0-9_-]*: \"$name\""
	! profile_exists "$name" || die "profile \"$name\" already exists (see gsp list)"

	[ -n "$root" ] || root=$(ask "Root folder for repositories" "$(pwd -P)/$name")
	case "$root" in
		"~/"*) root="$HOME/${root#\~/}" ;;
	esac
	[ -n "$uname" ]  || uname=$(ask "git user.name for this folder")
	[ -n "$uemail" ] || uemail=$(ask "git user.email for this folder")
	[ -n "$host" ]   || host=$(ask "First host" "github.com")
	valid_host "$host" || die "invalid host: \"$host\""

	root=$(realpath -m "$root")
	check_root_free "$name" "$root"

	title "Creating profile \"$name\""
	if [ ! -d "$root" ]; then
		if dry; then
			note "[dry-run] mkdir -p $root"
		else
			ensure_dir "$root" 755
			ok "folder created: $(short "$root")"
		fi
	else
		ok "folder: $(short "$root")"
	fi
	if [ -d "$root" ]; then
		root=$(cd "$root" && pwd -P)
	fi

	if [ -n "$key" ]; then
		[ -f "$key" ] || die "key not found: $key"
		key=$(realpath "$key")
	else
		key=$(key_path_for "$name" "$host")
		ensure_key "$key" "$uemail ($name@$host)"
	fi

	printf '%s\t%s\n' "$host" "$key" | profile_write "$name" "$root" "$uname" "$uemail"
	cmd_apply

	ok "profile \"$name\" is ready"
	show_key "$name" "$host"
}

cmd_host() {
	local sub=${1:-}
	shift || true
	case "$sub" in
		add) host_add "$@" ;;
		rm|remove|del) host_rm "$@" ;;
		''|*) die "usage: gsp host add|rm <profile> <host>" ;;
	esac
}

host_add() {
	local name=${1:-} host=${2:-} key='' reuse='' arg
	shift 2 2>/dev/null || true
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
			--key)   key=${2:?--key needs a value}; shift 2 ;;
			--reuse) reuse=${2:?--reuse needs a value}; shift 2 ;;
			*)       die "unknown argument: $arg" ;;
		esac
	done

	[ -n "$name" ] || die "usage: gsp host add <profile> <host> [--key <path>|--reuse <host>]"
	profile_exists "$name" || die "no such profile: \"$name\""
	[ -n "$host" ] || host=$(ask "Host to add to profile $name")
	valid_host "$host" || die "invalid host: \"$host\""
	if identity_key "$name" "$host" >/dev/null 2>&1; then
		die "host \"$host\" is already bound to profile \"$name\""
	fi

	title "Adding $host to \"$name\""
	if [ -n "$reuse" ]; then
		key=$(identity_key "$name" "$reuse") || die "profile \"$name\" has no host \"$reuse\""
		step "reusing the key from $reuse: $(short "$key")"
	elif [ -n "$key" ]; then
		[ -f "$key" ] || die "key not found: $key"
		key=$(realpath "$key")
	else
		key=$(key_path_for "$name" "$host")
		ensure_key "$key" "$(profile_get "$name" user_email || true) ($name@$host)"
	fi

	{
		profile_identities "$name"
		printf '%s\t%s\n' "$host" "$key"
	} | profile_write "$name" \
		"$(profile_get "$name" root)" \
		"$(profile_get "$name" user_name || true)" \
		"$(profile_get "$name" user_email || true)"
	cmd_apply

	ok "host \"$host\" added to profile \"$name\""
	show_key "$name" "$host"
}

host_rm() {
	local name=${1:-} host=${2:-} key h k
	[ -n "$name" ] && [ -n "$host" ] || die "usage: gsp host rm <profile> <host>"
	profile_exists "$name" || die "no such profile: \"$name\""
	key=$(identity_key "$name" "$host") || die "profile \"$name\" has no host \"$host\""

	{
		while IFS=$'\t' read -r h k; do
			[ -n "$h" ] || continue
			[ "$h" = "$host" ] && continue
			printf '%s\t%s\n' "$h" "$k"
		done < <(profile_identities "$name")
	} | profile_write "$name" \
		"$(profile_get "$name" root)" \
		"$(profile_get "$name" user_name || true)" \
		"$(profile_get "$name" user_email || true)"
	cmd_apply
	ok "host \"$host\" unbound from profile \"$name\""

	if [ -f "$key" ] && ! grep -rqF "$key" "$PROFILE_DIR" 2>/dev/null; then
		if confirm "Key $(short "$key") is no longer used anywhere. Delete it?"; then
			dry || rm -f "$key" "$key.pub"
			ok "key deleted"
		else
			note "    key left in place: $(short "$key")"
		fi
	fi
}

cmd_remove() {
	local name=${1:-} host key root
	[ -n "$name" ] || die "usage: gsp remove <profile>"
	profile_exists "$name" || die "no such profile: \"$name\""
	root=$(profile_get "$name" root || echo "the profile root")

	local keys=()
	while IFS=$'\t' read -r host key; do
		[ -n "$key" ] && keys+=("$key")
	done < <(profile_identities "$name")

	title "Removing profile \"$name\""
	if [ -e /dev/tty ] && ! confirm "Remove profile \"$name\"? (your project folder stays)"; then
		note "    cancelled"
		return 0
	fi
	dry || rm -f "$(profile_path "$name")"
	cmd_apply
	ok "profile \"$name\" removed from the configs"
	note "    $(short "$root") was left untouched"

	local k
	for k in "${keys[@]:-}"; do
		[ -n "$k" ] && [ -f "$k" ] || continue
		grep -rqF "$k" "$PROFILE_DIR" 2>/dev/null && continue
		if confirm "Delete key $(short "$k")?"; then
			dry || rm -f "$k" "$k.pub"
			ok "key deleted: $(short "$k")"
		fi
	done
}

show_key() { # profile host
	local key w
	key=$(identity_key "$1" "$2") || return 0
	if [ ! -f "$key.pub" ]; then
		warn "no public key at $(short "$key").pub"
		return 0
	fi
	w=$(term_width)
	title "Public key — profile \"$1\", host $2"
	cat "$key.pub" >&2
	printf '%s%s%s\n' "$C_D" "$(repeat_char "$S_HR" "$w")" "$C_0" >&2
	step "add it here: $C_C$(key_url_hint "$2")$C_0"
}

cmd_key() {
	local name=${1:-} host=${2:-}
	[ -n "$name" ] || die "usage: gsp key <profile> [host]"
	profile_exists "$name" || die "no such profile: \"$name\""
	if [ -n "$host" ]; then
		show_key "$name" "$host"
	else
		local h
		for h in $(profile_hosts "$name"); do show_key "$name" "$h"; done
	fi
}

cmd_list() {
	if [ "${1:-}" = "--names" ]; then
		profile_names
		return 0
	fi
	local p root host key fp mark
	local found=0
	for p in $(profile_names); do
		found=1
		root=$(profile_get "$p" root || echo '?')
		printf '\n%s%s %s%s   %s%s%s\n' \
			"$C_C" "$S_DOT" "$C_B$p" "$C_0" "$C_D" "$(short "$root")" "$C_0" >&2
		field "identity" "$(profile_get "$p" user_name || true) <$(profile_get "$p" user_email || true)>"
		while IFS=$'\t' read -r host key; do
			[ -n "$host" ] || continue
			if [ -f "$key" ]; then
				fp=$(ssh-keygen -lf "$key.pub" 2>/dev/null | awk '{print $2}') || fp=''
				mark="$C_G$S_OK$C_0"
			else
				fp='key is missing'
				mark="$C_R$S_BAD$C_0"
			fi
			printf '  %b %-18s %s\n' "$mark" "$host" "$(short "$key")" >&2
			printf '    %s%s%s\n' "$C_D" "${fp:-—}" "$C_0" >&2
		done < <(profile_identities "$p")
	done
	if [ "$found" -eq 1 ]; then
		printf '\n' >&2
	else
		note "no profiles yet — create the first one: gsp add"
	fi
}

cmd_clone() {
	local prof='' url='' dest='' arg
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
			-p|--profile) prof=${2:?-p needs a value}; shift 2 ;;
			-*) die "unknown flag: $arg" ;;
			*)
				if [ -z "$url" ]; then url=$arg
				elif [ -z "$dest" ]; then dest=$arg
				else die "unexpected argument: $arg"; fi
				shift ;;
		esac
	done
	[ -n "$url" ] || die "usage: gsp clone <url> [dir] [-p profile]"

	local root
	if [ -n "$prof" ]; then
		profile_exists "$prof" || die "no such profile: \"$prof\""
		root=$(profile_get "$prof" root)
	else
		prof=$(profile_for_dir "$PWD") || die "the current directory belongs to no profile — pass -p <profile>"
		root=$PWD
	fi

	step "profile $prof $S_ARROW cloning into $(short "$root")"
	if dry; then
		note "[dry-run] cd $root && git clone $url ${dest:-}"
		return 0
	fi
	cd "$root"
	if [ -n "$dest" ]; then
		git clone "$url" "$dest"
	else
		git clone "$url"
	fi
}

cmd_ssh_match() {
	local name=${1:-} root pwd_real
	[ -n "$name" ] || exit 1
	root=$(profile_get "$name" root 2>/dev/null) || exit 1
	pwd_real=$(pwd -P 2>/dev/null) || exit 1
	case "$pwd_real/" in
		"$root"/*) exit 0 ;;
	esac
	exit 1
}

cmd_doctor() {
	local only=${1:-}
	local problems=0

	title "Installation"
	if [ -x "$BIN_DIR/gsp" ]; then
		ok "installed: $(short "$BIN_DIR")/gsp"
	else
		warn "not installed in $(short "$BIN_DIR") — run \"gsp install\""
		problems=$((problems + 1))
	fi
	case ":$PATH:" in
		*":$BIN_DIR:"*) ok "$(short "$BIN_DIR") is on PATH" ;;
		*) warn "$(short "$BIN_DIR") is not on PATH — run \"gsp install --setup-path\" or: $(path_hint "$(user_shell)")"
		   problems=$((problems + 1)) ;;
	esac
	local dsh drc rc_found=0
	for dsh in $(installed_shells); do
		drc=$(shell_rc "$dsh")
		if [ -n "$drc" ] && [ -f "$drc" ] && grep -qF "$RC_BEGIN" "$drc"; then
			ok "shell hook present in $(short "$drc") ($dsh)"
			rc_found=1
		fi
	done
	if [ "$rc_found" -eq 0 ]; then
		warn "no shell hook in any rc file — \"gsp install --setup-path --shell all\""
		problems=$((problems + 1))
	fi
	note "    current shell detected as: $(user_shell)"

	title "Files"
	local perm
	if [ -d "$SSH_DIR" ]; then
		perm=$(stat -c '%a' "$SSH_DIR")
		[ "$perm" = 700 ] && ok "$(short "$SSH_DIR") mode $perm" || { warn "$(short "$SSH_DIR") mode $perm (700 expected)"; problems=$((problems + 1)); }
	else
		warn "missing $(short "$SSH_DIR")"; problems=$((problems + 1))
	fi
	local f
	for f in "$SSH_CONFIG" "$GITCONFIG"; do
		if [ -f "$f" ] && grep -qF "$BEGIN_MARK" "$f"; then
			ok "gsp section present in $(short "$f")"
		else
			warn "no gsp section in $(short "$f") — run \"gsp apply\""
			problems=$((problems + 1))
		fi
	done

	local p root host key fp actual expected count
	for p in $(profile_names); do
		[ -z "$only" ] || [ "$only" = "$p" ] || continue
		title "Profile \"$p\""
		root=$(profile_get "$p" root || echo '')
		if [ -z "$root" ]; then
			warn "the profile has no root"; problems=$((problems + 1)); continue
		fi
		if [ -d "$root" ]; then
			ok "folder: $(short "$root")"
		else
			warn "folder is missing: $(short "$root")"; problems=$((problems + 1))
		fi
		if [ -L "$root" ]; then
			warn "$(short "$root") is a symlink; git resolves symlinks in gitdir:, so includeIf may not fire"
			problems=$((problems + 1))
		fi

		while IFS=$'\t' read -r host key; do
			[ -n "$host" ] || continue
			if [ ! -f "$key" ]; then
				warn "$host: key is missing — $(short "$key")"; problems=$((problems + 1)); continue
			fi
			perm=$(stat -c '%a' "$key")
			[ "$perm" = 600 ] || { warn "$host: key mode $perm (600 expected) — $(short "$key")"; problems=$((problems + 1)); }
			fp=$(ssh-keygen -lf "$key.pub" 2>/dev/null | awk '{print $2}' || true)

			if [ -d "$root" ]; then
				actual=$( (cd "$root" && ssh -F "$SSH_CONFIG" -G "git@$host" 2>/dev/null) | awk '/^identityfile /{print $2}' || true)
				count=$(printf '%s\n' "$actual" | grep -c . || true)
				expected=$key
				if printf '%s\n' "$actual" | grep -qxF "$expected"; then
					if [ "$count" -gt 1 ]; then
						warn "$host: the right key wins, but ssh still knows $count of them — check the order in $(short "$SSH_CONFIG")"
						problems=$((problems + 1))
					else
						ok "$host $S_ARROW $(basename "$key")  ${C_D}${fp:-}${C_0}"
					fi
				else
					warn "$host: from $(short "$root") ssh picks the wrong key"
					printf '      %sexpected:%s %s\n' "$C_D" "$C_0" "$(short "$expected")" >&2
					printf '      %sgot:%s      %s\n' "$C_D" "$C_0" "${actual:-<nothing>}" >&2
					problems=$((problems + 1))
				fi
			fi
		done < <(profile_identities "$p")

		if [ -d "$root" ]; then
			local probe
			probe=$(mktemp -d "$root/.gsp-doctor-XXXXXX")
			git -C "$probe" init -q 2>/dev/null || true
			local email
			email=$(git -C "$probe" config --get user.email 2>/dev/null || true)
			if [ "$email" = "$(profile_get "$p" user_email || true)" ] && [ -n "$email" ]; then
				ok "git inside the folder commits as $email"
			else
				warn "git inside the folder reports user.email=\"${email:-<empty>}\", expected \"$(profile_get "$p" user_email || true)\""
				problems=$((problems + 1))
			fi
			rm -rf "$probe"
		fi
	done

	title "Current directory"
	local cur
	if cur=$(profile_for_dir "$PWD"); then
		ok "$(short "$PWD") $S_ARROW profile \"$cur\""
	else
		note "    $(short "$PWD") belongs to no profile — gsp keys do not apply here"
	fi

	title "Summary"
	if [ "$problems" -eq 0 ]; then
		ok "${C_G}everything checks out${C_0}"
		printf '\n' >&2
	else
		if [ "$problems" -eq 1 ]; then bad "1 problem found"; else bad "$problems problems found"; fi
		printf '\n' >&2
		return 1
	fi
}

cmd_install() {
	local dest="$BIN_DIR/gsp" mode=auto arg shell_arg=''
	local shells=()
	while [ $# -gt 0 ]; do
		arg=$1
		case "$arg" in
			--setup-path)    mode=force; shift ;;
			--no-setup-path) mode=skip;  shift ;;
			--shell)         shell_arg=${2:?--shell needs a value (zsh,bash,fish or all)}; shift 2 ;;
			*) die "unknown install argument: $arg" ;;
		esac
	done
	if [ -n "$shell_arg" ] && [ "$shell_arg" != all ]; then
		IFS=',' read -r -a shells <<<"$shell_arg"
	else
		# By default walk every installed shell, current one first.
		while IFS= read -r arg; do shells+=("$arg"); done < <(ordered_shells)
	fi

	title "Installing gsp $GSP_VERSION"
	ensure_dir "$BIN_DIR" 755
	if dry; then
		note "[dry-run] cp $SELF $dest"
	else
		cp "$SELF" "$dest"
		chmod 755 "$dest"
		ok "binary: $(short "$dest")"
	fi

	ensure_dir "$CONFIG_DIR" 700
	cmd_completions zsh | atomic_write "$CONFIG_DIR/gsp.zsh" 644
	dry || ok "zsh completions: $(short "$CONFIG_DIR")/gsp.zsh"

	if command -v fish >/dev/null 2>&1 || [ -d "$FISH_COMPLETIONS" ]; then
		ensure_dir "$FISH_COMPLETIONS" 755
		cmd_completions fish | atomic_write "$FISH_COMPLETIONS/gsp.fish" 644
		dry || ok "fish completions: $(short "$FISH_COMPLETIONS")/gsp.fish"
	fi

	cmd_apply
	if [ ${#shells[@]} -gt 0 ]; then
		ensure_shell_integration "$mode" "${shells[@]}"
	else
		ensure_shell_integration "$mode"
	fi

	if [ -z "$(profile_names)" ]; then
		first_profile_hint
	else
		title "Profiles"
		cmd_list
	fi
}

first_profile_hint() {
	box_top "Ready — now create your first profile"
	box_line "A profile is a root folder: every repository inside it"
	box_line "gets its own SSH key and its own commit identity."
	box_line ""
	box_line "  ${C_C}cd ~/work${C_0}"
	box_line "  ${C_C}gsp add mechta${C_0}"
	box_line ""
	box_line "${C_D}The default root folder is <current folder>/<profile name>.${C_0}"
	box_bottom
}

completions_zsh() {
	cat <<'ZSHEOF'
# gsp completions for zsh. Hook it up from ~/.zshrc with:
#   [ -f "$HOME/.config/gsp/gsp.zsh" ] && source "$HOME/.config/gsp/gsp.zsh"
_gsp() {
	local -a cmds profiles hosts
	cmds=(
		'add:Create a profile (root folder)'
		'host:Add or remove a host in a profile'
		'list:Show profiles'
		'key:Show a public key'
		'apply:Regenerate the configs'
		'remove:Delete a profile'
		'clone:Clone into a profile folder'
		'doctor:Diagnose the setup'
		'install:Install into ~/.local/bin'
		'help:Show help'
	)
	if (( CURRENT == 2 )); then
		_describe 'command' cmds
		return
	fi
	case ${words[2]} in
		key|remove|doctor)
			(( CURRENT == 3 )) || return
			profiles=(${(f)"$(gsp list --names 2>/dev/null)"})
			_describe 'profile' profiles ;;
		host)
			if (( CURRENT == 3 )); then
				_values 'action' add rm
			elif (( CURRENT == 4 )); then
				profiles=(${(f)"$(gsp list --names 2>/dev/null)"})
				_describe 'profile' profiles
			fi ;;
		clone)
			_files ;;
	esac
}
(( $+functions[compdef] )) && compdef _gsp gsp
ZSHEOF
}

cmd_completions() {
	case "${1:-fish}" in
		zsh) completions_zsh; return 0 ;;
	esac
	cat <<'FISHEOF'
# gsp completions for fish. Installed by `gsp install`.
set -l gsp_cmds add host list key apply remove clone doctor install completions help version

complete -c gsp -f
complete -c gsp -l dry-run -d "Show the changes without writing anything"

complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a add     -d "Create a profile (root folder)"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a host    -d "Add or remove a host in a profile"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a list    -d "Show profiles"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a key     -d "Show a public key"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a apply   -d "Regenerate the configs"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a remove  -d "Delete a profile"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a clone   -d "Clone into a profile folder"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a doctor  -d "Diagnose the setup"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a install -d "Install into ~/.local/bin"
complete -c gsp -n "not __fish_seen_subcommand_from $gsp_cmds" -a help    -d "Show help"

complete -c gsp -n "__fish_seen_subcommand_from host" -a "add rm" -d "Action"
complete -c gsp -n "__fish_seen_subcommand_from key remove doctor host" -a "(gsp list --names 2>/dev/null)" -d "Profile"
complete -c gsp -n "__fish_seen_subcommand_from clone" -s p -d "Profile" -a "(gsp list --names 2>/dev/null)"
FISHEOF
}

cmd_help() {
	local b='' c='' d='' z=''
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
		b=$'\033[1m'; c=$'\033[36m'; d=$'\033[2m'; z=$'\033[0m'
	fi
	cat <<HELPEOF
${b}gsp${z} ${d}$GSP_VERSION${z} — SSH keys and git identities per project root folder.

Every root folder (a profile) gets its own SSH keys and its own
user.name/user.email. Clone URLs stay untouched: ssh picks the key
by the current directory.

${b}Commands${z}
  ${c}gsp install${z} [--setup-path] [--shell zsh,fish]
                                    install into ~/.local/bin + completions,
                                    prepare ~/.ssh and ~/.gitconfig, and ask
                                    about PATH per installed shell;
                                    --setup-path skips the questions
  ${c}gsp add${z} [name] [--root D] [--name N] [--email E] [--host H]
                                    create a profile (folder + key + identity);
                                    default root is ${d}<current folder>/<name>${z}
  ${c}gsp host add${z} <profile> <host> [--key <path>|--reuse <host>]
                                    add a host (gitlab.com, …) to a profile
  ${c}gsp host rm${z}  <profile> <host>     unbind a host
  ${c}gsp list${z} [--names]                show profiles
  ${c}gsp key${z} <profile> [host]          public key to paste into the service
  ${c}gsp clone${z} <url> [dir] [-p prof]   clone inside the profile folder
  ${c}gsp apply${z}                         regenerate ~/.ssh/config and ~/.gitconfig
  ${c}gsp remove${z} <profile>              delete a profile (your code stays)
  ${c}gsp doctor${z} [profile]              check keys, modes and the real key choice
  ${c}gsp completions${z} [zsh|fish]        print a completion file
  ${c}gsp help${z} | ${c}version${z}

${b}Global flag${z}
  --dry-run                         print what would be written, change nothing

${b}How it works${z}
  ~/.ssh/config   → Match host <host> exec "gsp ssh-match <profile>" + IdentityFile
  ~/.gitconfig    → includeIf gitdir:<folder>/ → user.name / user.email

${d}The key is chosen by the current directory: clone while inside the profile
folder (or use \`gsp clone\`), otherwise ssh cannot tell which key to use.${z}
HELPEOF
}

# ── entry point ──────────────────────────────────────────────────────────────

main() {
	local args=() a
	for a in "$@"; do
		case "$a" in
			--dry-run) DRY_RUN=1 ;;
			*) args+=("$a") ;;
		esac
	done
	set -- "${args[@]:-}"
	[ $# -gt 0 ] || set -- help

	local cmd=$1
	shift || true
	case "$cmd" in
		add)         cmd_add "$@" ;;
		host)        cmd_host "$@" ;;
		list|ls)     cmd_list "$@" ;;
		key)         cmd_key "$@" ;;
		apply)       cmd_apply "$@" ;;
		remove|rm)   cmd_remove "$@" ;;
		clone)       cmd_clone "$@" ;;
		doctor)      cmd_doctor "$@" ;;
		install)     cmd_install "$@" ;;
		ssh-match)   cmd_ssh_match "$@" ;;
		completions) cmd_completions "$@" ;;
		help|-h|--help) cmd_help ;;
		version|--version) printf 'gsp %s\n' "$GSP_VERSION" ;;
		'')          cmd_help ;;
		*)           die "unknown command: $cmd (see gsp help)" ;;
	esac
}

main "$@"
