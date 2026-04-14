#!/bin/bash
# encode-pipeline.sh — Amygdala emotional encoding with LLM detection
#
# Pipeline:
# 1. Preprocess transcript → emotional-signals.jsonl
# 2. Rule-based emotional scoring
# 3. SkillBoss API Hub LLM semantic emotional detection
# 4. Apply detected emotions to emotional state
#
# Usage: ./encode-pipeline.sh [--no-spawn]
#
# Environment:
#   WORKSPACE         - OpenClaw workspace (default: ~/.openclaw/workspace)
#   SKILLBOSS_API_KEY - SkillBoss API Hub key (https://api.heybossai.com/v1/pilot)

set -e

WORKSPACE="${WORKSPACE:-$HOME/.openclaw/workspace}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGNALS_FILE="$WORKSPACE/memory/emotional-signals.jsonl"
STATE_FILE="$WORKSPACE/memory/emotional-state.json"
PENDING_FILE="$WORKSPACE/memory/pending-emotions.json"
NO_SPAWN="${1:-}"

echo "🎭 AMYGDALA ENCODING PIPELINE"
echo "============================="
echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1: Run preprocess
# ═══════════════════════════════════════════════════════════════
echo "📥 Step 1: Preprocessing emotional signals..."
"$SKILL_DIR/scripts/preprocess-emotions.sh"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 2: Check for signals
# ═══════════════════════════════════════════════════════════════
if [ ! -f "$SIGNALS_FILE" ] || [ ! -s "$SIGNALS_FILE" ]; then
    echo "✅ No emotional signals to process. Done."
    exit 0
fi

SIGNAL_COUNT=$(wc -l < "$SIGNALS_FILE" | tr -d ' ')
echo "📊 Step 2: Found $SIGNAL_COUNT emotional signals"

if [ "$SIGNAL_COUNT" -eq 0 ]; then
    echo "✅ No new signals. Done."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Rule-based emotional scoring + prepare for SkillBoss API
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🔄 Step 3: Scoring emotional signals..."

python3 << 'PYTHON'
import json
import os
import re
from datetime import datetime

WORKSPACE = os.environ.get('WORKSPACE', os.path.expanduser('~/.openclaw/workspace'))
SIGNALS_FILE = f"{WORKSPACE}/memory/emotional-signals.jsonl"
STATE_FILE = f"{WORKSPACE}/memory/emotional-state.json"
PENDING_FILE = f"{WORKSPACE}/memory/pending-emotions.json"

# Load signals
signals = []
with open(SIGNALS_FILE, 'r') as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                signals.append(json.loads(line))
            except:
                pass

# Emotional patterns for scoring
emotion_patterns = {
    'joy': ['happy', 'excit', 'joy', 'love', 'great', 'awesome', 'amazing', 'wonderful', 'fantastic', '🎉', '😊', '❤️'],
    'sadness': ['sad', 'disappoint', 'miss', 'lost', 'lonely', 'depressed', 'hurt', 'sorry', '😢', '💔'],
    'anger': ['angry', 'frustrat', 'annoy', 'furious', 'upset', 'hate', 'damn', 'ugh'],
    'fear': ['scared', 'afraid', 'worried', 'anxious', 'nervous', 'fear', 'terrif', 'panic'],
    'curiosity': ['curious', 'interest', 'wonder', 'fascin', 'intrigu', 'explore', 'learn', '🤔'],
    'connection': ['together', 'we ', 'us ', 'our ', 'bond', 'close', 'trust', 'friend', 'love you', 'thank you'],
    'accomplishment': ['done', 'complet', 'finish', 'success', 'works', 'fixed', 'solved', 'achieved', '✅'],
    'fatigue': ['tired', 'exhaust', 'drain', 'sleep', 'rest', 'overwhelm', 'burned out'],
}

def score_emotion(text):
    """Detect emotions in text"""
    text_lower = text.lower()
    detected = []
    
    for emotion, keywords in emotion_patterns.items():
        for kw in keywords:
            if kw in text_lower:
                detected.append(emotion)
                break
    
    return list(set(detected))

def estimate_intensity(text, emotions):
    """Estimate emotional intensity 0.0-1.0"""
    # More exclamation marks = higher intensity
    excl_count = text.count('!')
    caps_ratio = sum(1 for c in text if c.isupper()) / max(len(text), 1)
    
    base = 0.5
    if excl_count > 0:
        base += min(excl_count * 0.1, 0.3)
    if caps_ratio > 0.3:
        base += 0.2
    if len(emotions) > 1:
        base += 0.1
    
    return min(base, 1.0)

# Process signals
pending = []
skipped = 0
today = datetime.now().strftime('%Y-%m-%d')

for sig in signals:
    text = sig.get('text', '')
    role = sig.get('role', 'user')
    sig_id = sig.get('id', '')
    
    # Skip very short or system-like messages
    if len(text) < 20:
        skipped += 1
        continue
    
    # Detect emotions
    emotions = score_emotion(text)
    
    if not emotions:
        skipped += 1
        continue
    
    intensity = estimate_intensity(text, emotions)
    
    pending.append({
        "id": sig_id,
        "text": text[:500],
        "role": role,
        "detected_emotions": emotions,
        "estimated_intensity": round(intensity, 2),
        "timestamp": sig.get('timestamp', today)
    })

# Save pending for LLM analysis
with open(PENDING_FILE, 'w') as f:
    json.dump({"pending": pending, "created": today}, f, indent=2)

print(f"   Pending for LLM analysis: {len(pending)}")
print(f"   Skipped (no clear emotion): {skipped}")

# Show sample
if pending:
    print(f"\n   Sample detected:")
    for p in pending[:3]:
        print(f"      {p['detected_emotions']}: {p['text'][:60]}...")
PYTHON

# Check if we have pending emotions
PENDING_COUNT=$(python3 -c "import json; d=json.load(open('$PENDING_FILE')); print(len(d.get('pending',[])))" 2>/dev/null || echo "0")

if [ "$PENDING_COUNT" -eq 0 ]; then
    echo ""
    echo "✅ No emotional signals need LLM analysis. Updating watermark..."
    "$SKILL_DIR/scripts/update-watermark.sh" --from-signals
    # Regenerate dashboard
    "$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null || true
    exit 0
fi

echo ""
echo "📝 $PENDING_COUNT signals pending LLM emotional analysis"

if [ "$NO_SPAWN" = "--no-spawn" ]; then
    echo "⏭️  Skipping LLM analysis (--no-spawn flag)"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# STEP 4: SkillBoss API Hub — semantic LLM emotional detection
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🤖 Step 4: Calling SkillBoss API Hub for semantic emotional detection..."

python3 << 'PYTHON'
import json, os, re, sys
import requests

WORKSPACE = os.environ.get('WORKSPACE', os.path.expanduser('~/.openclaw/workspace'))
PENDING_FILE = f"{WORKSPACE}/memory/pending-emotions.json"
SKILLBOSS_API_KEY = os.environ.get("SKILLBOSS_API_KEY", "")

if not SKILLBOSS_API_KEY:
    print("   ⚠️  SKILLBOSS_API_KEY not set — skipping LLM analysis")
    sys.exit(0)

with open(PENDING_FILE) as f:
    data = json.load(f)

pending = data.get("pending", [])
if not pending:
    print("   No pending emotions.")
    sys.exit(0)

signals_text = "\n".join([
    f"[{p['role']}] {p['text'][:300]} (rule-detected: {', '.join(p['detected_emotions'])})"
    for p in pending[:10]
])

prompt = (
    "You are analyzing conversation excerpts for emotional content. "
    "For each excerpt, identify the primary emotion and intensity (0.0-1.0).\n\n"
    f"Excerpts:\n{signals_text}\n\n"
    "Respond with a JSON array only, no other text. Format:\n"
    '[{"emotion": "joy", "intensity": 0.8, "trigger": "brief description"}]\n'
    "Only include emotions with intensity >= 0.5."
)

r = requests.post(
    "https://api.heybossai.com/v1/pilot",
    headers={"Authorization": f"Bearer {SKILLBOSS_API_KEY}", "Content-Type": "application/json"},
    json={
        "type": "chat",
        "inputs": {"messages": [{"role": "user", "content": prompt}]},
        "prefer": "balanced"
    },
    timeout=60,
)
result = r.json()
text = result["result"]["choices"][0]["message"]["content"]

try:
    match = re.search(r'\[.*?\]', text, re.DOTALL)
    emotions = json.loads(match.group()) if match else []
except Exception as e:
    print(f"   LLM parse error: {e}")
    emotions = []

print(f"   LLM detected {len(emotions)} significant emotion(s):")
for e in emotions:
    print(f"      {e.get('emotion','?')} ({e.get('intensity', 0):.1f}): {e.get('trigger','')}")

with open(PENDING_FILE, 'w') as f:
    json.dump({"pending": pending, "llm_results": emotions, "created": data.get("created", "")}, f, indent=2)
PYTHON

# ═══════════════════════════════════════════════════════════════
# STEP 5: Apply LLM-detected emotions to emotional state
# ═══════════════════════════════════════════════════════════════
echo ""
echo "💾 Step 5: Updating emotional state from LLM detections..."

python3 << PYTHON2
import json, os, subprocess

WORKSPACE = os.environ.get('WORKSPACE', os.path.expanduser('~/.openclaw/workspace'))
PENDING_FILE = f"{WORKSPACE}/memory/pending-emotions.json"
update_script = "$SKILL_DIR/scripts/update-state.sh"

with open(PENDING_FILE) as f:
    data = json.load(f)

for e in data.get("llm_results", []):
    emotion = e.get("emotion", "")
    intensity = e.get("intensity", 0.5)
    trigger = e.get("trigger", "LLM detected")
    if emotion and intensity >= 0.5:
        subprocess.run(
            [update_script, "--emotion", emotion,
             "--intensity", str(round(intensity, 2)),
             "--trigger", trigger],
            check=False
        )
PYTHON2

"$SKILL_DIR/scripts/update-watermark.sh" --from-signals
"$SKILL_DIR/scripts/sync-state.sh" 2>/dev/null || true

echo ""
echo "✅ Encoding pipeline complete."
