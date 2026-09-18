#!/usr/bin/env bash
# SSH prompt bridge between ssh (SSH_ASKPASS) and the plugin popup.
#
#   askpass.sh run [--keyring USER@HOST] -- CMD...  plugin: run CMD in a private session
#   askpass.sh PROMPT                               ssh: ask the popup, print the answer
#   askpass.sh answer DIR ID                        plugin: stdin line -> waiting prompt
#   askpass.sh store USER@HOST | forget | has       plugin: keyring (secret on stdin)
#   askpass.sh store-key KEYFILE | forget-key | has-key
#                                                   plugin: a key's passphrase, kept
#                                                   only if it unlocks the key
#
# Secrets only travel over stdin/stdout and FIFOs inside a 0700 session
# directory in $XDG_RUNTIME_DIR; never argv, environment, files or logs.
# They are stored in the login keyring, which is encrypted with the login
# password; Omarchy's default keyring is a plain-text file.
#
# Control lines: askpass writes them into the session's event FIFO. The run
# wrapper validates each line and forwards it to the plugin on stderr, prefixed
# with a random token that only the wrapper and the plugin know. The token is
# never exported, so neither rsync, ssh nor a remote host (e.g. via SendEnv)
# can learn it and fake a prompt.
set -u
umask 077

readonly MARK=$'\x1e'
readonly APP=omarchy-rsync
readonly COLLECTION=login
readonly TARGET_RE='^[A-Za-z0-9._%+-]{1,64}@[][A-Za-z0-9._:%-]{1,190}$'
# a private key file as ssh names it in its prompt (at most 100 characters)
readonly KEYFILE_RE=$'^/[^\'\n]{1,99}$'
readonly KEY_PROMPT_RE="^Enter passphrase for key '(/[^']{1,99})': ?\$"
readonly ID_RE='^[0-9a-f]{16}$'
# ask lines stay below PIPE_BUF (4096) so they reach the plugin in one write
readonly EVENT_RE='^(ask [0-9a-f]{16} (text|confirm) [A-Za-z0-9+/=]{0,3800}|timeout [0-9a-f]{16}|keyring password|keyring key [A-Za-z0-9+/=]{4,600})$'
runtime=${XDG_RUNTIME_DIR:-}

die() { printf '%s\n' "askpass: $1" >&2; exit "${2:-1}"; }

# A locked keyring asks for its password in a dialog: don't wait forever.
lookup() { timeout 60 secret-tool lookup app "$APP" "$@" 2>/dev/null; }

valid_dir() {
  local d=${1-}
  [[ -n $runtime && $d == "$runtime"/omarchy-rsync.* ]] || return 1
  [[ ${d#"$runtime"/omarchy-rsync.} =~ ^[A-Za-z0-9]{10}$ ]] || return 1
  [[ -d $d && ! -L $d && -O $d ]]
}

valid_target() { [[ ${1-} =~ $TARGET_RE ]]; }
valid_keyfile() { [[ ${1-} =~ $KEYFILE_RE ]]; }

# "user@host" an ssh password prompt is for, or "" (keyboard-interactive
# prompts carry it as "(user@host) Password:" since OpenSSH 8.4)
readonly PW_RE="^([^@[:space:]]+)@([^[:space:]]+)'s password: ?\$"
readonly KBD_RE='^[(]([^@[:space:]]+)@([^[:space:])]+)[)] [Pp]assword: ?$'
prompt_target() {
  if [[ $1 =~ $PW_RE || $1 =~ $KBD_RE ]]; then
    printf '%s@%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
}

# Writes into an existing FIFO only (never creates a file), with a timeout so a
# vanished reader can't block the caller.
write_fifo() {
  local fifo=$1
  [[ -p $fifo && -O $fifo ]] || return 1
  timeout 5 dd of="$fifo" conv=nocreat bs=65536 status=none
}

cmd_run() {
  local target=""
  if [[ ${1-} == --keyring ]]; then target=${2-}; shift 2; fi
  [[ ${1-} == -- ]] && shift
  (($#)) || die "nothing to run"
  [[ -n $runtime && -d $runtime && -O $runtime ]] || die "XDG_RUNTIME_DIR is not usable"
  valid_target "$target" || target=""

  local self
  self=$(realpath -- "${BASH_SOURCE[0]}") || die "cannot locate myself"
  [[ -x $self ]] || chmod u+x -- "$self" 2>/dev/null || die "$self must be executable for SSH_ASKPASS"

  local dir token
  dir=$(mktemp -d "$runtime/omarchy-rsync.XXXXXXXXXX") || die "cannot create session dir"
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ $token =~ ^[0-9a-f]{32}$ ]] || { rm -rf -- "$dir"; die "no random token"; }
  mkfifo -m 600 "$dir/events" || { rm -rf -- "$dir"; die "cannot create event channel"; }

  # First stderr line announces the session; nothing else runs yet, so it
  # can't be faked.
  printf '%s%s session %s\n' "$MARK" "$token" "$dir" >&2

  # Event reader: forwards only well-formed lines, adding the token.
  (
    exec 4<>"$dir/events"
    while IFS= read -r line <&4; do
      [[ $line == end ]] && exit 0
      if [[ $line =~ $EVENT_RE ]]; then
        printf '%s%s %s\n' "$MARK" "$token" "$line" >&2
      fi
    done
  ) &
  local reader=$!

  # The command gets its own process group so stopping reaches ssh,
  # ssh-copy-id and askpass children too.
  set -m
  OMARCHY_RSYNC_DIR=$dir OMARCHY_RSYNC_KEYRING=$target \
    SSH_ASKPASS=$self SSH_ASKPASS_REQUIRE=force \
    "$@" </dev/null &
  local child=$!
  set +m

  # Watchdog: if this wrapper is killed outright (e.g. the shell restarts),
  # stop the command and remove the session instead of leaving orphans.
  local me=$BASHPID
  (
    while kill -0 "$me" 2>/dev/null; do sleep 1; done
    kill -TERM -- "-$child" 2>/dev/null
    sleep 3
    kill -KILL -- "-$child" 2>/dev/null
    kill "$reader" 2>/dev/null
    rm -rf -- "$dir"
  ) </dev/null >/dev/null 2>&1 &
  local watchdog=$!

  # Queue an end marker behind any pending events and let the reader drain
  # the channel before the session directory disappears.
  cleanup() {
    kill "$watchdog" 2>/dev/null
    printf 'end\n' | write_fifo "$dir/events"
    for _ in $(seq 20); do kill -0 "$reader" 2>/dev/null || break; sleep 0.05; done
    kill "$reader" 2>/dev/null
    rm -rf -- "$dir"
  }
  stop() {
    kill -TERM -- "-$child" 2>/dev/null
    for _ in 1 2 3 4 5 6; do kill -0 "$child" 2>/dev/null || break; sleep 0.5; done
    kill -KILL -- "-$child" 2>/dev/null
  }
  trap cleanup EXIT
  trap 'stop; exit 20' TERM INT HUP

  wait "$child"
  exit $?
}

cmd_ask() {
  local prompt=${1-}
  local dir=${OMARCHY_RSYNC_DIR-} target=${OMARCHY_RSYNC_KEYRING-}
  valid_dir "$dir" || exit 1
  local events=$dir/events

  # A stored password is only ever sent to the exact user@host it was saved
  # for (never to a jump host), and only once per session: a second prompt
  # means it was rejected and the popup asks instead.
  local saved
  if valid_target "$target" && [[ $(prompt_target "$prompt") == "$target" ]] \
      && mkdir "$dir/keyring-used" 2>/dev/null; then
    if saved=$(lookup target "$target") && [[ -n $saved ]]; then
      printf 'keyring password\n' | write_fifo "$events"
      printf '%s\n' "$saved"
      exit 0
    fi
  fi

  # A key's passphrase, likewise once per key and session. The prompt can only
  # come from ssh on this computer (a server's questions always start with
  # "(user@host)"), and the passphrase only unlocks the key file here.
  if [[ $prompt =~ $KEY_PROMPT_RE ]]; then
    local keyfile=${BASH_REMATCH[1]}
    if mkdir "$dir/key.$(printf '%s' "$keyfile" | sha256sum | cut -c1-16)" 2>/dev/null \
        && saved=$(lookup keyfile "$keyfile") && [[ -n $saved ]]; then
      printf 'keyring key %s\n' "$(printf '%s' "$keyfile" | base64 -w0)" | write_fifo "$events"
      printf '%s\n' "$saved"
      exit 0
    fi
  fi

  local id fifo answer kind=text
  id=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ $id =~ $ID_RE ]] || exit 1
  fifo=$dir/answer-$id
  mkfifo -m 600 "$fifo" || exit 1
  exec 3<>"$fifo"
  [[ ${SSH_ASKPASS_PROMPT-} == confirm ]] && kind=confirm
  printf 'ask %s %s %s\n' "$id" "$kind" "$(printf '%s' "$prompt" | head -c 2800 | base64 -w0)" \
    | write_fifo "$events" || { rm -f -- "$fifo"; exit 1; }
  # ssh kills askpass when it no longer needs the answer (a FIDO key's "touch
  # your key" notice, for one): take the question back out of the popup.
  trap 'rm -f -- "$fifo"; printf "timeout %s\n" "$id" | write_fifo "$events"; exit 1' TERM HUP INT
  if IFS= read -r -t "${OMARCHY_RSYNC_ASK_TIMEOUT:-180}" answer <&3; then
    rm -f -- "$fifo"
    if [[ ${answer:0:1} == Y ]]; then
      printf '%s\n' "${answer:1}"
      exit 0
    fi
    exit 1
  fi
  rm -f -- "$fifo"
  printf 'timeout %s\n' "$id" | write_fifo "$events"
  exit 1
}

cmd_answer() {
  local dir=${1-} id=${2-} line
  valid_dir "$dir" || die "invalid session"
  [[ $id =~ $ID_RE ]] || die "invalid prompt id"
  IFS= read -r line || true
  printf '%s\n' "$line" | write_fifo "$dir/answer-$id" || die "prompt is gone"
}

cmd_store() {
  valid_target "${1-}" || die "invalid target"
  local secret
  IFS= read -r secret || true
  [[ -n $secret ]] || die "empty secret"
  printf '%s' "$secret" | secret-tool store --collection="$COLLECTION" --label="rsync (Omarchy): $1" app "$APP" target "$1"
}

cmd_forget() {
  valid_target "${1-}" || die "invalid target"
  secret-tool clear app "$APP" target "$1"
}

cmd_has() {
  valid_target "${1-}" || exit 1
  [[ -n $(lookup target "$1") ]]
}

# Exit 2: the passphrase doesn't unlock the key, nothing is stored.
cmd_store_key() {
  local keyfile=${1-} secret
  valid_keyfile "$keyfile" && [[ -f $keyfile && -O $keyfile ]] || die "invalid key file"
  IFS= read -r secret || true
  [[ -n $secret ]] || die "empty passphrase"
  # Without askpass and without a terminal, ssh-keygen reads it from stdin.
  printf '%s\n' "$secret" | env -u DISPLAY -u WAYLAND_DISPLAY -u SSH_ASKPASS SSH_ASKPASS_REQUIRE=never \
    setsid -w ssh-keygen -y -f "$keyfile" >/dev/null 2>&1 || die "wrong passphrase" 2
  printf '%s' "$secret" | secret-tool store --collection="$COLLECTION" --label="rsync (Omarchy): key $keyfile" \
    app "$APP" keyfile "$keyfile"
}

cmd_forget_key() {
  valid_keyfile "${1-}" || die "invalid key file"
  secret-tool clear app "$APP" keyfile "$1"
}

cmd_has_key() {
  valid_keyfile "${1-}" || exit 1
  [[ -n $(lookup keyfile "$1") ]]
}

# ssh passes the prompt as the only argument; the session directory in the
# environment tells the two roles apart.
if [[ -n ${OMARCHY_RSYNC_DIR-} ]]; then
  cmd_ask "${1-}"
fi

case ${1-} in
  run) shift; cmd_run "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  store) shift; cmd_store "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  has) shift; cmd_has "$@" ;;
  store-key) shift; cmd_store_key "$@" ;;
  forget-key) shift; cmd_forget_key "$@" ;;
  has-key) shift; cmd_has_key "$@" ;;
  *) die "unknown command" ;;
esac
