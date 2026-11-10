#!/bin/zsh
emulate -L zsh

directory="$HOME/Library/Application Support/Whisper Dictation/claude-sessions"

record_state() {
  local state=$1 payload session_id cwd temporary thread_field= environment_id

  payload=$(/bin/cat)
  session_id=$(print -r -- "$payload" | /usr/bin/plutil -extract session_id raw -o - - 2>/dev/null) || return 0
  [[ $session_id =~ '^[A-Za-z0-9._-]+$' ]] || return 0

  if [[ $state == ended ]]; then
    /bin/rm -f "$directory/$session_id.json"
    return 0
  fi

  case $state in
    idle|working|unread|awaiting-approval|awaiting-response|error) ;;
    *) return 0 ;;
  esac

  cwd=$(print -r -- "$payload" | /usr/bin/plutil -extract cwd raw -o - - 2>/dev/null) || cwd=
  cwd=${cwd//[[:cntrl:]]/}
  cwd=${cwd//\\/\\\\}
  cwd=${cwd//\"/\\\"}

  if [[ $CLAUDE_CODE_ENTRYPOINT == t3-code && ${T3CODE_THREAD_ID:-} =~ '^[A-Za-z0-9._-]+$' ]]; then
    thread_field=",\"threadID\":\"$T3CODE_THREAD_ID\""
    environment_id=$(/bin/cat "${T3CODE_HOME:-$HOME/.t3}/userdata/environment-id" 2>/dev/null) || environment_id=
    if [[ $environment_id =~ '^[A-Za-z0-9._-]+$' ]]; then
      thread_field+=",\"environmentID\":\"$environment_id\""
    fi
  fi

  /bin/mkdir -p "$directory" || return 0
  temporary="$directory/.$session_id.tmp"
  printf '{"state":"%s","cwd":"%s","updatedAt":"%s","host":"%s"%s}\n' \
    "$state" "$cwd" "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$CLAUDE_CODE_ENTRYPOINT" "$thread_field" > "$temporary" || return 0
  /bin/mv -f "$temporary" "$directory/$session_id.json"
}

case ${CLAUDE_CODE_ENTRYPOINT:-} in
  claude-desktop|t3-code) ;;
  *) exit 0 ;;
esac
record_state "${1:-}" >/dev/null 2>&1
exit 0
