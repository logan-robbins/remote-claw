#!/usr/bin/env bash
# Example: prune a fixated task from an OpenClaw agent's lossless-context memory.
#
# Intended to run ON the target VM (not on the Mac). Stage it there via:
#   scp example-trim-memory.sh azureuser@<IP>:/tmp/trim.sh
#   ssh azureuser@<IP> 'bash /tmp/trim.sh <cutoff_seq>'
#
# where <cutoff_seq> is the messages.seq value of the FIRST message belonging to
# the poisoned task (everything at/after this seq will be deleted). Find it by
# grepping the content column for the poison keyword, e.g.:
#
#   python3 -c "
# import sqlite3
# c = sqlite3.connect('/home/azureuser/.openclaw/lcm.db')
# for r in c.execute(\"SELECT seq, role, substr(content,1,80) FROM messages WHERE content LIKE '%tailnet%' ORDER BY seq LIMIT 5\"):
#     print(r)
# "

set -euo pipefail

CUTOFF_SEQ="${1:?usage: $0 <cutoff_seq>}"
LCM=/home/azureuser/.openclaw/lcm.db
SVC=openclaw-gateway
STAMP=$(date +%Y%m%d-%H%M%S)

# 0. Halt the DB writer (agent is a plugin inside this service; no separate pid to kill)
echo "=== stopping $SVC ==="
sudo systemctl stop "$SVC"
sleep 2
pgrep -af openclaw || echo "(no openclaw procs)"

# 1. Checkpoint WAL + back up
python3 - <<PY
import sqlite3
c = sqlite3.connect("$LCM")
c.execute("PRAGMA wal_checkpoint(TRUNCATE);")
c.close()
PY
cp -v "$LCM" "${LCM}.bak.pretrim.${STAMP}"
[[ -f "${LCM}-wal" ]] && cp -v "${LCM}-wal" "${LCM}-wal.bak.pretrim.${STAMP}" || true
[[ -f "${LCM}-shm" ]] && cp -v "${LCM}-shm" "${LCM}-shm.bak.pretrim.${STAMP}" || true

# 2. Trim + (optional) inject replacement user turn, all in one transaction
python3 - "$CUTOFF_SEQ" <<'PY'
import sqlite3, sys, hashlib, datetime

CUTOFF = int(sys.argv[1])
DB = "/home/azureuser/.openclaw/lcm.db"

# Edit this to your situation. Be specific about current state and forbidden actions.
STOP_BODY = (
    "Gateway configuration task is COMPLETE. Current state: gateway.mode=\"local\", "
    "gateway.bind=\"loopback\", gateway.tailscale.mode=\"serve\", gateway.auth.mode=\"token\". "
    "Telegram is working (you are reading this via Telegram). "
    "DO NOT modify /mnt/claw-data/openclaw/openclaw.json. "
    "DO NOT change gateway.bind, gateway.mode, or gateway.tailscale. "
    "DO NOT restart the gateway. Acknowledge and stand by."
)

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row

def cols(t):
    return [r[1] for r in con.execute(f'PRAGMA table_info("{t}")')]

# Sample a recent real user message to mirror the message_parts shape
sample_part = con.execute("""
    SELECT mp.* FROM message_parts mp
    JOIN messages m ON m.message_id = mp.message_id
    WHERE m.role='user' AND m.seq < ?
    ORDER BY m.seq DESC LIMIT 1
""", (CUTOFF,)).fetchone()

pre = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
tail = con.execute("SELECT COUNT(*) FROM messages WHERE seq >= ?", (CUTOFF,)).fetchone()[0]
print(f"messages: {pre}  (will trim {tail} from seq>={CUTOFF})")

con.execute("BEGIN IMMEDIATE")
try:
    mids = [r[0] for r in con.execute(
        "SELECT message_id FROM messages WHERE seq >= ?", (CUTOFF,)
    )]
    if mids:
        ph = ",".join("?" * len(mids))
        con.execute(f"DELETE FROM message_parts   WHERE message_id IN ({ph})", mids)
        con.execute(f"DELETE FROM summary_messages WHERE message_id IN ({ph})", mids)
        con.execute(f"DELETE FROM messages        WHERE message_id IN ({ph})", mids)

    # Rebuild FTS so rowids stay consistent with remaining rows
    con.execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")

    # Inject replacement user message at the cutoff seq
    now = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M:%S")
    ident = hashlib.sha256(STOP_BODY.encode()).hexdigest()
    approx_tokens = max(1, len(STOP_BODY) // 4)
    msg_cols = cols("messages")
    values = {
        "conversation_id": 1, "seq": CUTOFF, "role": "user",
        "content": STOP_BODY, "token_count": approx_tokens,
        "identity_hash": ident, "created_at": now,
    }
    use = [c for c in msg_cols if c in values]
    cur = con.execute(
        f'INSERT INTO messages ({",".join(f"\"{c}\"" for c in use)}) VALUES ({",".join("?" for _ in use)})',
        [values[c] for c in use],
    )
    new_id = cur.lastrowid

    # Mirror into message_parts (copy shape from the sample, swap ids + text)
    if sample_part:
        sp = dict(sample_part)
        sp["message_id"] = new_id
        for textcol in ("text_content", "content", "text", "data", "body", "value"):
            if textcol in sp and isinstance(sp[textcol], str):
                sp[textcol] = STOP_BODY
        for pk in ("part_id", "id", "rowid"):
            sp.pop(pk, None)
        mp_cols = cols("message_parts")
        use = [c for c in sp if c in mp_cols]
        con.execute(
            f'INSERT INTO message_parts ({",".join(f"\"{c}\"" for c in use)}) VALUES ({",".join("?" for _ in use)})',
            [sp[c] for c in use],
        )

    con.execute("COMMIT")
except Exception:
    con.execute("ROLLBACK")
    raise

post = con.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
print(f"after: messages={post}")
for r in con.execute(
    "SELECT seq, role, substr(content,1,100) FROM messages ORDER BY seq DESC LIMIT 3"
):
    print(" ", dict(r) if hasattr(r, "keys") else tuple(r))
con.close()
PY

# 3. Bring the service back
echo "=== starting $SVC ==="
sudo systemctl reset-failed "$SVC" || true
sudo systemctl start "$SVC"
sleep 12
systemctl is-active "$SVC"
sudo journalctl -u "$SVC" -n 10 --no-pager
