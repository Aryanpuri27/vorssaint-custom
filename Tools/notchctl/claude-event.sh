#!/bin/zsh
# Sends Hoo Notch a sample Claude Code hook event, as Claude Code would:
#   claude-event.sh ask | question | plan | done | waiting | step
# ask/question/plan wait for your answer in the notch (up to 25 s) and print
# the reply Claude Code would get.
set -euo pipefail
U=http://127.0.0.1:47615/vorssaint-hook
T=$(defaults read com.vorssaint.utils.dev claudeLiveToken)
P="$HOME/Projects/demo-app"
send() { curl -s -m 30 -X POST $U -H "X-Vorssaint-Token: $T" -H "X-Claude-Config: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}" -d "$1"; echo; }
case "${1:-}" in
  ask)      send '{"hook_event_name":"PermissionRequest","session_id":"sample","cwd":"'$P'","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules && npm install"}}' ;;
  question) send '{"hook_event_name":"PermissionRequest","session_id":"sample","cwd":"'$P'","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should the app use?","header":"Database","options":[{"label":"SQLite"},{"label":"Postgres"},{"label":"Supabase"}],"multiSelect":false}]}}' ;;
  plan)     send '{"hook_event_name":"PermissionRequest","session_id":"sample","cwd":"'$P'","tool_name":"ExitPlanMode","tool_input":{"plan":"## Add login\n1. Create **AuthService**\n2. Add a login screen\n3. Write tests"}}' ;;
  step)     send '{"hook_event_name":"UserPromptSubmit","session_id":"sample","cwd":"'$P'"}'
            send '{"hook_event_name":"PreToolUse","session_id":"sample","tool_name":"Edit","tool_input":{"file_path":"'$P'/App.swift"}}' ;;
  done)     send '{"hook_event_name":"Stop","session_id":"sample","last_assistant_message":"All tests pass."}' ;;
  waiting)  send '{"hook_event_name":"Notification","session_id":"sample","cwd":"'$P'","notification_type":"idle_prompt","message":"waiting"}' ;;
  end)      send '{"hook_event_name":"SessionEnd","session_id":"sample"}' ;;
  *) echo "usage: claude-event.sh ask|question|plan|step|done|waiting|end"; exit 1 ;;
esac
