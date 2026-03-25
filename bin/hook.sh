#!/bin/bash
# claude-vibe-check hook for Claude Code
# Runs on the "Stop" event — after Claude finishes responding
# Captures a webcam photo and analyzes the user's reaction
#
# Modes:
#   online  — sends photo to Claude for analysis (default)
#   offline — uses local CV model (FER/HSEmotion) for emotion detection
#
# Set mode via VIBE_CHECK_MODE env var or ~/.config/claude-vibe-check/config

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
PHOTO_PATH="/tmp/claude-vibe-check-$(date +%s).jpg"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-vibe-check"
CONFIG_FILE="$CONFIG_DIR/config"

# Read hook input from stdin (contains session info)
INPUT=$(cat)

# Prevent infinite loops — if this stop was triggered by a previous vibe check, skip
STOP_ACTIVE=$(echo "$INPUT" | grep -o '"stop_hook_active"[[:space:]]*:[[:space:]]*true' | head -1)
if [ -n "$STOP_ACTIVE" ]; then
	exit 0
fi

# Extract fields from hook input
HOOK_CWD=$(echo "$INPUT" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"cwd"[[:space:]]*:[[:space:]]*"//;s/"$//')
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//;s/"$//')
if [ -z "$HOOK_CWD" ]; then
	HOOK_CWD="unknown"
fi

# History log file
HISTORY_FILE="$CONFIG_DIR/history.jsonl"

log_vibe() {
	local emotion="$1"
	local confidence="$2"
	local vibe_mode="$3"
	mkdir -p "$CONFIG_DIR"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local hour
	hour=$(date +"%-H")
	local project
	project=$(basename "$HOOK_CWD")
	printf '{"ts":"%s","hour":%d,"emotion":"%s","confidence":"%s","mode":"%s","project":"%s","cwd":"%s","session":"%s"}\n' \
		"$ts" "$hour" "$emotion" "$confidence" "$vibe_mode" "$project" "$HOOK_CWD" "$SESSION_ID" >>"$HISTORY_FILE"
}

# Determine Python binary — prefer project venv if it exists
if [ -f "$PROJECT_DIR/.venv/bin/python3" ]; then
	PYTHON="$PROJECT_DIR/.venv/bin/python3"
else
	PYTHON="python3"
fi

# Load config (file first, then env vars override)
MODE="online"
COOLDOWN="60"
if [ -f "$CONFIG_FILE" ]; then
	while IFS='=' read -r key value; do
		case "$key" in
		\#* | "") continue ;;
		esac
		key=$(echo "$key" | tr -d '[:space:]')
		case "$key" in
		VIBE_CHECK_MODE) MODE="$value" ;;
		VIBE_CHECK_COOLDOWN) COOLDOWN="$value" ;;
		esac
	done <"$CONFIG_FILE"
fi
# Env vars take precedence over config file
[ -n "$VIBE_CHECK_MODE" ] && MODE="$VIBE_CHECK_MODE"
[ -n "$VIBE_CHECK_COOLDOWN" ] && COOLDOWN="$VIBE_CHECK_COOLDOWN"
# Validate cooldown is a number
case "$COOLDOWN" in
'' | *[!0-9]*) COOLDOWN=60 ;;
esac

# Check cooldown — don't claude-vibe-check too often
COOLDOWN_FILE="/tmp/claude-vibe-check-cooldown"
if [ -f "$COOLDOWN_FILE" ]; then
	LAST_RUN=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
	NOW=$(date +%s)
	ELAPSED=$((NOW - LAST_RUN))
	if [ "$ELAPSED" -lt "$COOLDOWN" ]; then
		exit 0
	fi
fi

# Capture the photo
CAPTURED=$("$SCRIPT_DIR/capture.sh" "$PHOTO_PATH" 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$CAPTURED" ] || [ ! -f "$CAPTURED" ]; then
	# Silently skip if capture fails — don't break the flow
	exit 0
fi

# Update cooldown
date +%s >"$COOLDOWN_FILE"

if [ "$MODE" = "offline" ]; then
	# Offline mode: run local emotion detection
	EMOTION_JSON=$("$PYTHON" "$LIB_DIR/emotion_detect.py" "$CAPTURED" 2>/dev/null)

	if [ $? -ne 0 ] || [ -z "$EMOTION_JSON" ]; then
		# Offline detection failed — do NOT fall back to online (privacy)
		rm -f "$CAPTURED" 2>/dev/null
		exit 0
	else
		# Check for errors in the JSON output
		HAS_ERROR=$(echo "$EMOTION_JSON" | "$PYTHON" -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'error' in d else 'no')" 2>/dev/null)
		if [ "$HAS_ERROR" = "yes" ]; then
			rm -f "$CAPTURED" 2>/dev/null
			exit 0
		fi
	fi
fi

if [ "$MODE" = "offline" ]; then
	# Parse the dominant emotion from local CV analysis
	DOMINANT=$(echo "$EMOTION_JSON" | "$PYTHON" -c "
import sys, json
d = json.load(sys.stdin)
if 'faces' in d and len(d['faces']) > 0:
    print(d['faces'][0]['dominant_emotion'].lower())
else:
    print('unknown')
" 2>/dev/null)

	CONFIDENCE=$(echo "$EMOTION_JSON" | "$PYTHON" -c "
import sys, json, math
d = json.load(sys.stdin)
if 'faces' in d and len(d['faces']) > 0:
    f = d['faces'][0]
    if 'confidence' in f:
        print(f'{f[\"confidence\"]:.0%}')
    elif 'all_emotions' in f:
        scores = list(f['all_emotions'].values())
        exp_scores = [math.exp(s) for s in scores]
        total = sum(exp_scores)
        dominant = f.get('dominant_emotion', '').lower()
        for name, exp_s in zip(f['all_emotions'].keys(), exp_scores):
            if name.lower() == dominant:
                print(f'{exp_s/total:.0%}')
                break
        else:
            print(f'{max(exp_scores)/total:.0%}')
    else:
        print('N/A')
else:
    print('N/A')
" 2>/dev/null)

	# Build the response based on detected emotion
	case "$DOMINANT" in
	angry | anger | frustrated)
		REACTION="The local emotion detector identified the user as looking angry/frustrated (confidence: ${CONFIDENCE}). Ask what went wrong and offer to fix or redo the changes. Be empathetic and constructive."
		;;
	sad | sadness)
		REACTION="The local emotion detector identified the user as looking sad or disappointed (confidence: ${CONFIDENCE}). Gently ask if something is off and offer to adjust the approach."
		;;
	fear | scared)
		REACTION="The local emotion detector identified the user as looking worried or fearful (confidence: ${CONFIDENCE}). Reassure them about the safety of your changes and explain the reasoning."
		;;
	disgust | contempt)
		REACTION="The local emotion detector identified the user as looking displeased (confidence: ${CONFIDENCE}). Ask directly what they dislike and offer alternatives."
		;;
	happy | happiness)
		REACTION="The local emotion detector identified the user as looking happy (confidence: ${CONFIDENCE}). Briefly note the good vibe and continue normally."
		;;
	surprise | surprised)
		REACTION="The local emotion detector identified the user as looking surprised (confidence: ${CONFIDENCE}). They might not have expected this approach. Briefly explain what you did and why."
		;;
	neutral)
		REACTION="The local emotion detector identified the user as looking neutral (confidence: ${CONFIDENCE}). Continue normally."
		;;
	*)
		REACTION="The local emotion detector could not clearly identify the emotion. Continue normally."
		;;
	esac

	# Log the vibe
	log_vibe "$DOMINANT" "$CONFIDENCE" "offline"

	# Clean up the photo since we already analyzed it
	rm -f "$CAPTURED" 2>/dev/null

	cat <<EOF
{
  "decision": "block",
  "reason": "Vibe Check (offline mode): ${REACTION} Keep your reaction brief and natural — one or two sentences max."
}
EOF

else
	# Online mode: send photo to Claude for visual analysis
	log_vibe "pending" "N/A" "online"

	# Clean up old photos and schedule this one for deletion
	find /tmp -maxdepth 1 -name 'claude-vibe-check-*.jpg' -mmin +5 -delete 2>/dev/null
	(sleep 120 && rm -f "$CAPTURED") &>/dev/null &
	disown

	cat <<EOF
{
  "decision": "block",
  "reason": "Vibe Check! A photo of the user was just captured at ${CAPTURED}. Please read this image file and analyze the user's facial expression, body language, and overall emotional state. Based on what you observe, do one of the following: (1) If the user looks confused, frustrated, or unhappy — ask what went wrong, explain your changes more clearly, or offer to fix/redo something. (2) If the user looks skeptical or uncertain — briefly explain your reasoning and ask if they want changes. (3) If the user looks happy, satisfied, or neutral — just note the positive vibe and continue normally. Keep your claude-vibe-check response brief and natural. Start with a short observation about their expression, then act on it."
}
EOF

fi
