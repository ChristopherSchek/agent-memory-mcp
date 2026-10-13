#!/usr/bin/env bash
# ==============================================================================
# agent-memory installer (v1.0.0, schema 1.0)
# Per-user, Optane-backed persistent memory for AI agents (CLI + stdio MCP server).
#
#   ./install.sh                         Install on a host with a verified Intel Optane
#                                        volume at /mnt/optane/$USER.
#   ./install.sh --allow-non-optane      Explicit opt-in to run on ordinary storage
#                [--db /abs/path.db]     (default: /mnt/optane/$USER if it exists,
#                                        else ~/.local/share/agent-memory/memory.db).
#   ./install.sh --db /mnt/optane/$USER/custom/memory.db
#   ./install.sh --no-client-config      Install and self-test only; print client snippets.
#   ./install.sh --uninstall             Remove binary, skill and MCP registration (keeps data).
#
# Environment variables:
#   AGENT_MEMORY_BIN_DIR / BIN_DIR       Target directory for agent-memory binary
#   AGENT_MEMORY_MCP_DIR / MCP_DIR       Target directory for MCP instructions
#   AGENT_MEMORY_SKILL_DIR / SKILL_DIR   Target directory for agent-memory skill
#   AGENT_MEMORY_MCP_CONFIG / MCP_CONFIG Target path for client mcp_config.json
#   ALLOW_ROOT=1                         Override restriction against running as root
#
# Nothing is installed or registered until preflight, initialisation and self-test pass.
# ==============================================================================
set -euo pipefail
umask 022

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_BIN="${SCRIPT_DIR}/bin/agent-memory"

ALLOW_NON_OPTANE_FLAG=""
DB_OVERRIDE=""
UNINSTALL=0
CLIENT_CONFIG=1

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-non-optane) ALLOW_NON_OPTANE_FLAG=1 ;;
        --allow-non-optane=1|--allow-non-optane=true|--allow-non-optane=yes|--allow-non-optane=on) ALLOW_NON_OPTANE_FLAG=1 ;;
        --require-optane|--no-allow-non-optane|--allow-non-optane=0|--allow-non-optane=false|--allow-non-optane=no|--allow-non-optane=off) ALLOW_NON_OPTANE_FLAG=0 ;;
        --db) [ $# -ge 2 ] || { echo "Error: --db requires a path" >&2; exit 2; }; DB_OVERRIDE="$2"; shift ;;
        --db=*) DB_OVERRIDE="${1#--db=}" ;;
        --uninstall) UNINSTALL=1 ;;
        --no-client-config) CLIENT_CONFIG=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$(id -u)" -eq 0 ]; then
    case "${ALLOW_ROOT:-0}" in
        1|true|yes|on) ;;
        *)
            printf 'Error: Refusing to install as root. Run as the target user (e.g. without sudo). Set ALLOW_ROOT=1 to override.\n' >&2
            exit 1
            ;;
    esac
fi

TARGET_USER="$(id -un)"
HOME_DIR="${HOME:-}"
if [ -z "${HOME_DIR}" ]; then
    HOME_DIR="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
fi
BIN_DIR="${AGENT_MEMORY_BIN_DIR:-${BIN_DIR:-${HOME_DIR}/.local/bin}}"
BIN="${BIN_DIR}/agent-memory"
GEMINI_DIR="${HOME_DIR}/.gemini"
MCP_DIR="${AGENT_MEMORY_MCP_DIR:-${MCP_DIR:-${GEMINI_DIR}/antigravity-cli/mcp/agent-memory}}"
SKILL_DIR="${AGENT_MEMORY_SKILL_DIR:-${SKILL_DIR:-${GEMINI_DIR}/config/skills/agent-memory}}"
MCP_CONFIG="${AGENT_MEMORY_MCP_CONFIG:-${MCP_CONFIG:-${GEMINI_DIR}/config/mcp_config.json}}"

say()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# The interpreter is resolved once and pinned (as an absolute path) in the MCP registration, so the
# server does not depend on the client's PATH. The launcher path (e.g. /usr/bin/python3) is kept rather
# than its realpath (e.g. /usr/bin/python3.12) so a distribution Python upgrade does not break the
# registration; the binary itself refuses to run on Python < 3.10.
command -v python3 >/dev/null 2>&1 || die "python3 (3.10+) is required but was not found in PATH."
python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "Python 3.10+ is required (found $(python3 -V 2>&1))."
PY="$(python3 -I -c 'import os, sys; print(os.path.abspath(sys.executable))')"
[ -x "${PY}" ] || die "could not resolve the python3 interpreter path."

# Read or update the agent-memory entry in an MCP JSON config safely: abort on malformed JSON,
# keep the original as <config>.agent-memory.bak (written once), write atomically through
# symlinks, preserve other servers and any extra keys of an existing entry.
mcp_config_edit() {  # $1=check|get-db|add|remove  $2=config path  [$3=entry-json]
    "${PY}" -I - "$@" <<'PY'
import json, os, shutil, sys, tempfile
action, path = sys.argv[1], os.path.realpath(sys.argv[2])
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
    except Exception as e:
        sys.exit(f"Error: {path} is not valid JSON ({e}); fix it manually, nothing was changed.")
    if not isinstance(data, dict) or not isinstance(data.get("mcpServers", {}), dict):
        sys.exit(f"Error: {path} must be a JSON object whose 'mcpServers' is an object; nothing was changed.")
servers = data.setdefault("mcpServers", {})
if action == "check":
    sys.exit(0)
if action == "get-db":
    entry = servers.get("agent-memory")
    env = entry.get("env") if isinstance(entry, dict) else None
    print(env.get("AGENT_MEMORY_DB", "") if isinstance(env, dict) else "")
    sys.exit(0)
if action == "get-allow-non-optane":
    entry = servers.get("agent-memory")
    env = entry.get("env") if isinstance(entry, dict) else None
    val = str(env.get("ALLOW_NON_OPTANE", "")) if isinstance(env, dict) else ""
    print("1" if str(val).strip().lower() in ("1", "true", "yes", "on") else "")
    sys.exit(0)
if action == "add":
    new = json.loads(sys.argv[3])
    entry = servers.get("agent-memory") if isinstance(servers.get("agent-memory"), dict) else {}
    entry.update(command=new["command"], args=new["args"], env=new["env"])
    servers["agent-memory"] = entry
elif action == "remove":
    if "agent-memory" not in servers:
        sys.exit(0)
    del servers["agent-memory"]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
if os.path.exists(path) and not os.path.lexists(path + ".agent-memory.bak"):
    shutil.copy2(path, path + ".agent-memory.bak", follow_symlinks=False)
mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".mcp_config.")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, mode)
os.replace(tmp, path)
PY
}

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
if [ "${UNINSTALL}" -eq 1 ]; then
    DB_HINT=""
    if [ -f "${MCP_CONFIG}" ]; then
        mcp_config_edit check "${MCP_CONFIG}" || die "nothing was removed."
        DB_HINT="$(mcp_config_edit get-db "${MCP_CONFIG}")"
        mcp_config_edit remove "${MCP_CONFIG}"
        say "Removed agent-memory from ${MCP_CONFIG} (original kept as ${MCP_CONFIG}.agent-memory.bak)"
    fi
    if [ -z "${DB_HINT}" ] && [ -f "${BIN}" ]; then
        DB_HINT="$("${PY}" -I "${BIN}" doctor 2>/dev/null | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin).get("db_path",""))' 2>/dev/null || true)"
    fi
    rm -f "${SKILL_DIR}/SKILL.md"; rmdir "${SKILL_DIR}" 2>/dev/null || true
    rm -f "${MCP_DIR}/instructions.md" "${MCP_DIR}"/memory_*.json; rmdir "${MCP_DIR}" 2>/dev/null || true
    rm -f "${BIN}"
    say "Removed ${BIN}, skill and MCP instructions."
    say "Your memory database was kept${DB_HINT:+ at ${DB_HINT}}. Delete it manually if you no longer need it."
    exit 0
fi

echo "======================================================================"
echo "Installing agent-memory v${VERSION} for user ${TARGET_USER}"
echo "======================================================================"
say "Python $("${PY}" -I -c 'import platform; print(platform.python_version())') (${PY})"
[ -f "${BUNDLE_BIN}" ] || die "bundle is incomplete: bin/agent-memory not found next to install.sh."

# ------------------------------------------------------------------------------
# 1. Resolve the runtime environment. The MCP registration always carries an explicit
#    env block (ALLOW_NON_OPTANE and AGENT_MEMORY_DB), so inherited variables cannot change it.
# ------------------------------------------------------------------------------
for v in AGENT_MEMORY_DB OPTANE_BASE ALLOW_NON_OPTANE; do
    if [ -n "${!v:-}" ]; then
        warn "Ignoring ${v} from your shell; use --db / --allow-non-optane so the registered MCP server gets the same setting."
    fi
done
if [ -f "${MCP_CONFIG}" ]; then
    if [ -z "${DB_OVERRIDE}" ]; then
        EXISTING_DB="$(mcp_config_edit get-db "${MCP_CONFIG}" 2>/dev/null || true)"
        if [ -n "${EXISTING_DB}" ]; then
            DB_OVERRIDE="${EXISTING_DB}"
            say "Preserving registered database path from ${MCP_CONFIG}: ${DB_OVERRIDE}"
        fi
    fi
    if [ -z "${ALLOW_NON_OPTANE_FLAG:-}" ]; then
        EXISTING_ALLOW="$(mcp_config_edit get-allow-non-optane "${MCP_CONFIG}" 2>/dev/null || true)"
        if [ "${EXISTING_ALLOW}" = "1" ]; then
            ALLOW_NON_OPTANE_FLAG=1
            say "Preserving ALLOW_NON_OPTANE=1 from ${MCP_CONFIG}"
        fi
    fi
fi
ALLOW_NON_OPTANE_FLAG="${ALLOW_NON_OPTANE_FLAG:-0}"
if [ -n "${DB_OVERRIDE}" ]; then
    case "${DB_OVERRIDE}" in
        /*) ;;
        *) die "--db must be an absolute path (got '${DB_OVERRIDE}')." ;;
    esac
fi
ENV_BASE=(env -u AGENT_MEMORY_DB -u OPTANE_BASE -u ALLOW_NON_OPTANE "ALLOW_NON_OPTANE=${ALLOW_NON_OPTANE_FLAG}")
PRE_ENV=("${ENV_BASE[@]}")
[ -n "${DB_OVERRIDE}" ] && PRE_ENV+=("AGENT_MEMORY_DB=${DB_OVERRIDE}")

# ------------------------------------------------------------------------------
# 2. Preflight (read-only): SQLite features, storage gate, writability, existing database
# ------------------------------------------------------------------------------
TMP_BIN=""
DOCTOR_ERR="$(mktemp)"
trap 'rm -f "${DOCTOR_ERR}" ${TMP_BIN:+"${TMP_BIN}"}' EXIT
DOCTOR_RC=0
DOCTOR_OUT="$("${PRE_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" doctor 2>"${DOCTOR_ERR}")" || DOCTOR_RC=$?
if [ "${DOCTOR_RC}" -ne 0 ]; then
    echo "${DOCTOR_OUT}" >&2
    cat "${DOCTOR_ERR}" >&2
    GATE_FAILED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(0 if str(d.get("storage_gate", "")).startswith("ok") else 1)' 2>/dev/null || echo 0)"
    WRITABLE_FAILED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
print(0 if str(d.get("writable", "")).startswith("ok") else 1)' 2>/dev/null || echo 0)"
    echo >&2
    echo "Preflight failed: see the fields above that are not \"ok\". Nothing was changed." >&2
    if { [ "${GATE_FAILED}" = "1" ] || [ "${WRITABLE_FAILED}" = "1" ]; } && [ "${ALLOW_NON_OPTANE_FLAG}" -eq 0 ]; then
        cat >&2 <<EOF
agent-memory is designed for a per-user directory on an Intel Optane NVMe volume.
Ensure /mnt/optane is mounted on the Optane NVMe partition, then create your directory:
    sudo mkdir -p /mnt/optane/${TARGET_USER} && sudo chown ${TARGET_USER}: /mnt/optane/${TARGET_USER} && sudo chmod 700 /mnt/optane/${TARGET_USER}
To run on ordinary storage instead (slower, explicit opt-in):
    ./install.sh --allow-non-optane [--db /absolute/path/memory.db]
EOF
    fi
    exit 1
fi
DB_PATH_RESOLVED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin)["db_path"])')"
say "Preflight passed; database: ${DB_PATH_RESOLVED}"
[ "${ALLOW_NON_OPTANE_FLAG}" -eq 1 ] && warn "Non-Optane override is active (ALLOW_NON_OPTANE=1)."
RUN_ENV=("${ENV_BASE[@]}" "AGENT_MEMORY_DB=${DB_PATH_RESOLVED}")

# Antigravity is configured only when it is actually present (Gemini CLI also uses ~/.gemini).
DO_ANTIGRAVITY=0
if [ "${CLIENT_CONFIG}" -eq 1 ] && { [ -d "${GEMINI_DIR}/antigravity-cli" ] || [ -e "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ] || command -v agy >/dev/null 2>&1; }; then
    DO_ANTIGRAVITY=1
    mcp_config_edit check "${MCP_CONFIG}" || exit 1
fi

# ------------------------------------------------------------------------------
# 3. Initialise (or migrate, with an automatic backup) and self-test using the bundle
#    binary, before anything is installed or registered.
# ------------------------------------------------------------------------------
"${RUN_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" init

"${RUN_ENV[@]}" "${PY}" -I - "${PY}" "${BUNDLE_BIN}" <<'PY'
import json, subprocess, sys, uuid
cmd = [sys.argv[1], "-I", sys.argv[2]]
def run(*a, inp=None):
    p = subprocess.run([*cmd, *a], capture_output=True, text=True, input=inp, timeout=60)
    if p.returncode != 0:
        sys.exit(f"Self-test failed: agent-memory {' '.join(a)}: {p.stdout}{p.stderr}")
    return p.stdout
tok = "installprobe" + uuid.uuid4().hex[:12]
oid = json.loads(run("record", f"agent-memory install self-test {tok}", "--session", "install-selftest"))["observation_id"]
hits = json.loads(run("search", tok))
if not any(h.get("observation_id") == oid for h in hits):
    sys.exit(f"Self-test failed: probe not found by search: {hits}")
if json.loads(run("forget", "--observation", oid)).get("deleted_observations") != 1:
    sys.exit("Self-test failed: probe could not be deleted")
msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "installer", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "memory_search", "arguments": {"query": tok}}}]
out = run("--mcp", inp="\n".join(json.dumps(m) for m in msgs) + "\n")
resp = {r["id"]: r for r in map(json.loads, out.splitlines()) if "id" in r}
names = [t["name"] for t in resp[2]["result"]["tools"]]
if "memory_record" not in names or "memory_forget" not in names:
    sys.exit(f"Self-test failed: unexpected MCP tools {names}")
call = resp[3]["result"]
if call.get("isError") or json.loads(call["content"][0]["text"]) != []:
    sys.exit(f"Self-test failed: MCP tool call: {call}")
print(f"[+] Self-test passed: record -> search -> forget round trip, MCP handshake and tool call ({len(names)} tools); no data left behind")
PY

# ------------------------------------------------------------------------------
# 4. Install the binary (atomic replace)
# ------------------------------------------------------------------------------
mkdir -p "${BIN_DIR}"
TMP_BIN="$(mktemp "${BIN_DIR}/.agent-memory.XXXXXX")"
cp "${BUNDLE_BIN}" "${TMP_BIN}"
chmod 755 "${TMP_BIN}"
mv -f "${TMP_BIN}" "${BIN}"
"${RUN_ENV[@]}" "${PY}" -I "${BIN}" --version >/dev/null || die "installed binary does not run: ${BIN}"
say "Installed ${BIN}"

# ------------------------------------------------------------------------------
# 5. Client integration
# ------------------------------------------------------------------------------
ENTRY_JSON="$("${PY}" -I - "${PY}" "${BIN}" "${ALLOW_NON_OPTANE_FLAG}" "${DB_PATH_RESOLVED}" <<'PY'
import json, sys
py, b, allow, db = sys.argv[1:5]
print(json.dumps({"command": py, "args": ["-I", b, "--mcp"], "env": {"ALLOW_NON_OPTANE": allow, "AGENT_MEMORY_DB": db}}))
PY
)"
CLI_STR="$("${PY}" -I - "${ENTRY_JSON}" <<'PY'
import json, shlex, sys
e = json.loads(sys.argv[1])
py = e["command"]
b_args = [a for a in e["args"] if a != "--mcp"]
print("env " + " ".join([f"{k}={shlex.quote(v)}" for k, v in e["env"].items()] + [shlex.quote(py)] + [shlex.quote(a) for a in b_args]))
PY
)"
SNIPPET="$("${PY}" -I -c 'import json,sys; print(json.dumps({"mcpServers": {"agent-memory": json.loads(sys.argv[1])}}, indent=2))' "${ENTRY_JSON}")"

if [ "${DO_ANTIGRAVITY}" -eq 1 ]; then
    mcp_config_edit add "${MCP_CONFIG}" "${ENTRY_JSON}"
    say "Registered MCP server 'agent-memory' in ${MCP_CONFIG}"
    mkdir -p "${MCP_DIR}"
    rm -f "${MCP_DIR}"/memory_*.json "${MCP_DIR}/instructions.md"
    cp -f "${SCRIPT_DIR}/mcp/instructions.md" "${MCP_DIR}/instructions.md" 
    say "Installed MCP instructions to ${MCP_DIR}"
    if compgen -G "${SCRIPT_DIR}/mcp/memory_*.json" >/dev/null 2>&1; then
        cp -f "${SCRIPT_DIR}/mcp"/memory_*.json "${MCP_DIR}/"
        say "Installed MCP tool schemas to ${MCP_DIR}"
    fi
    mkdir -p "${SKILL_DIR}"
    "${PY}" -I - "${SCRIPT_DIR}/skill/SKILL.md.template" "${SKILL_DIR}/SKILL.md" "${DB_PATH_RESOLVED}" "${CLI_STR}" "${ALLOW_NON_OPTANE_FLAG}" <<'PY'
import os, sys, tempfile
src, dst, db, cli, allow = sys.argv[1:6]
storage_desc = "stored on local persistent storage" if allow == "1" else "stored on a dedicated fast volume"
text = open(src).read().replace("__DB__", db).replace("__CLI__", cli).replace("__STORAGE_DESC__", storage_desc)
dst_dir = os.path.dirname(dst) or "."
os.makedirs(dst_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".SKILL.md.")
with os.fdopen(fd, "w") as f:
    f.write(text)
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PY
    say "Installed skill to ${SKILL_DIR}/SKILL.md"
fi

echo "======================================================================"
echo "agent-memory v${VERSION} installed."
echo "Database : ${DB_PATH_RESOLVED}"
echo "Health   : ${CLI_STR} doctor"
if [ "${DO_ANTIGRAVITY}" -eq 1 ]; then
    echo "Antigravity: registered. Restart the agent client so it starts the MCP server."
fi
echo "Server definition for other MCP clients (see LLM_ONBOARDING.md for each client's config file):"
echo "${SNIPPET}"
echo "======================================================================"
