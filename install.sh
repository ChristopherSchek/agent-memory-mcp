#!/usr/bin/env bash
# Copyright (c) 2026 Christopher Schek
# SPDX-License-Identifier: GPL-3.0-only
# ==============================================================================
# agent-memory installer (v1.0.0, schema 1.0)
# Per-user, Optane-backed persistent memory for AI agents (CLI + stdio MCP server).
#
#   ./install.sh                         Install on a host with a verified Intel Optane
#                                        volume at /mnt/optane/$USER.
#   ./install.sh --allow-non-optane      Explicit opt-in to run on ordinary storage
#                [--db /abs/path.db]     (default: /mnt/optane/$USER if owned by $USER,
#                                        else ~/.local/share/agent-memory/memory.db).
#   ./install.sh --require-optane        Require verified Intel Optane storage (also
#                                        --no-allow-non-optane or --allow-non-optane=0).
#   ./install.sh --db /mnt/optane/$USER/custom/memory.db
#   ./install.sh --no-client-config      Install and self-test only, then print client snippets.
#   ./install.sh --dry-run               Run preflight checks without modifying files.
#   ./install.sh --log-dir /abs/dir      Write Tri-Stream telemetry (results.json, debug.log).
#   ./install.sh --uninstall             Remove binary, skill and MCP registration (keeps data).
#
# Environment variables:
#   AGENT_MEMORY_BIN_DIR / BIN_DIR       Target directory for agent-memory binary
#   AGENT_MEMORY_MCP_DIR / MCP_DIR       Target directory for MCP instructions
#   AGENT_MEMORY_SKILL_DIR / SKILL_DIR   Target directory for agent-memory skill
#   AGENT_MEMORY_MCP_CONFIG / MCP_CONFIG Target path for client mcp_config.json
#   ALLOW_ROOT=1                         Override restriction against running as root
#   (Shell AGENT_MEMORY_DB, OPTANE_BASE, and ALLOW_NON_OPTANE are ignored during install
#    so the registered MCP entry matches explicit --db / --allow-non-optane flags.)
#
# Nothing is installed or registered until preflight, initialisation and self-test pass.
# ==============================================================================
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_BIN="${SCRIPT_DIR}/bin/agent-memory"

ALLOW_NON_OPTANE_FLAG=""
DB_OVERRIDE=""
UNINSTALL=0
CLIENT_CONFIG=1
DRY_RUN=0
LOG_DIR=""
RESULTS_WRITTEN=0
DB_PATH_RESOLVED=""
TMP_BIN=""
DOCTOR_ERR=""

usage() { sed -n '4,31p' "$0" | sed 's/^# \{0,1\}//'; }

# Pre-scan arguments for --log-dir so early argument/validation failures are logged
_prev_is_log_dir=0
for _arg in "$@"; do
    if [ "${_prev_is_log_dir}" -eq 1 ]; then
        if [ -n "${_arg}" ] && [[ "${_arg}" != -* ]]; then
            LOG_DIR="${_arg}"
        fi
        _prev_is_log_dir=0
        continue
    fi
    case "${_arg}" in
        --log-dir) _prev_is_log_dir=1 ;;
        --log-dir=*) LOG_DIR="${_arg#--log-dir=}" ;;
    esac
done

expand_tilde_path() {
    local p="$1"
    local h="${HOME:-}"
    if [ -z "${h}" ] && command -v python3 >/dev/null 2>&1; then
        h="$(python3 -I -c 'import os; print(os.path.expanduser("~"))' 2>/dev/null || true)"
    fi
    local tilde='~'
    case "${p}" in
        "${tilde}") printf '%s\n' "${h}" ;;
        "${tilde}/"*) printf '%s/%s\n' "${h%/}" "${p#"${tilde}/"}" ;;
        *) printf '%s\n' "${p}" ;;
    esac
}

if [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" != -* ]]; then
    LOG_DIR="$(expand_tilde_path "${LOG_DIR}")"
    case "${LOG_DIR}" in
        /*)
            mkdir -p "${LOG_DIR}" 2>/dev/null || true
            chmod 700 "${LOG_DIR}" 2>/dev/null || true
            : > "${LOG_DIR}/debug.log" 2>/dev/null || true
            chmod 600 "${LOG_DIR}/debug.log" 2>/dev/null || true
            ;;
        *)
            LOG_DIR=""
            ;;
    esac
fi

log_debug() {
    if [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" == /* ]] && [ -d "${LOG_DIR}" ]; then
        printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_DIR}/debug.log"
        chmod 600 "${LOG_DIR}/debug.log" 2>/dev/null || true
    fi
}

write_results_json() {
    local status="$1"
    local detail="$2"
    if [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" == /* ]] && [ -d "${LOG_DIR}" ] && command -v python3 >/dev/null 2>&1; then
        python3 -I - "${LOG_DIR}/results.json" "${status}" "${detail}" "${DB_PATH_RESOLVED:-}" "${DRY_RUN}" "${UNINSTALL}" <<'PY'
import json, os, sys, tempfile, time
dst, status, detail, db_path, dry_run, uninstall = sys.argv[1:7]
payload = {
    "status": status,
    "detail": detail,
    "db_path": db_path,
    "dry_run": dry_run == "1",
    "uninstall": uninstall == "1",
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
dst_dir = os.path.dirname(dst) or "."
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".results.json.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, dst)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
        RESULTS_WRITTEN=1
    fi
}

cleanup() {
    local rc=$?
    [ -n "${DOCTOR_ERR:-}" ] && rm -f "${DOCTOR_ERR}"
    [ -n "${TMP_BIN:-}" ] && rm -f "${TMP_BIN}"
    if [ "${rc}" -ne 0 ] && [ "${RESULTS_WRITTEN:-0}" -eq 0 ]; then
        log_debug "ERROR: installer aborted (exit ${rc})"
        write_results_json "error" "aborted (exit ${rc})" || true
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

arg_die() {
    printf 'Error: %s\n' "$1" >&2
    log_debug "ERROR: $1"
    write_results_json "error" "$1" || true
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --allow-non-optane) ALLOW_NON_OPTANE_FLAG=1 ;;
        --allow-non-optane=1|--allow-non-optane=true|--allow-non-optane=yes|--allow-non-optane=on) ALLOW_NON_OPTANE_FLAG=1 ;;
        --require-optane|--no-allow-non-optane|--allow-non-optane=0|--allow-non-optane=false|--allow-non-optane=no|--allow-non-optane=off) ALLOW_NON_OPTANE_FLAG=0 ;;
        --db) [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || arg_die "--db requires a non-empty path"; DB_OVERRIDE="$2"; shift ;;
        --db=*) DB_OVERRIDE="${1#--db=}"; [ -n "${DB_OVERRIDE}" ] && [[ "${DB_OVERRIDE}" != -* ]] || arg_die "--db requires a non-empty path" ;;
        --log-dir) [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] || arg_die "--log-dir requires a non-empty directory path"; LOG_DIR="$2"; shift ;;
        --log-dir=*) LOG_DIR="${1#--log-dir=}"; [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" != -* ]] || arg_die "--log-dir requires a non-empty directory path" ;;
        --dry-run) DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-client-config) CLIENT_CONFIG=0 ;;
        -h|--help) usage; exit 0 ;;
        *) printf "Error: unknown option '%s'\n" "$1" >&2; usage >&2; log_debug "ERROR: unknown option '$1'"; write_results_json "error" "unknown option '$1'" || true; exit 2 ;;
    esac
    shift
done

say()  { printf '[+] %s\n' "$*"; log_debug "INFO: $*"; }
warn() { printf '[!] %s\n' "$*" >&2; log_debug "WARN: $*"; }
die()  { printf 'Error: %s\n' "$*" >&2; log_debug "ERROR: $*"; write_results_json "error" "$*"; exit 1; }

if [ -n "${LOG_DIR}" ]; then
    LOG_DIR="$(expand_tilde_path "${LOG_DIR}")"
    case "${LOG_DIR}" in
        /*) ;;
        *) die "--log-dir must be an absolute path (got '${LOG_DIR}')." ;;
    esac
    mkdir -p "${LOG_DIR}"
    chmod 700 "${LOG_DIR}"
    [ -f "${LOG_DIR}/debug.log" ] || : > "${LOG_DIR}/debug.log"
    chmod 600 "${LOG_DIR}/debug.log"
fi

if [ "$(id -u)" -eq 0 ]; then
    case "${ALLOW_ROOT:-0}" in
        1|true|yes|on) ;;
        *)
            die "Refusing to install as root. Run as the target user (e.g. without sudo). Set ALLOW_ROOT=1 to override."
            ;;
    esac
fi

TARGET_USER="$(id -un)"
HOME_DIR="${HOME:-}"
if [ -z "${HOME_DIR}" ]; then
    if command -v getent >/dev/null 2>&1; then
        HOME_DIR="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    fi
    if [ -z "${HOME_DIR}" ] && command -v python3 >/dev/null 2>&1; then
        HOME_DIR="$(python3 -I -c 'import os; print(os.path.expanduser("~"))')"
    fi
fi

BIN_DIR="$(expand_tilde_path "${AGENT_MEMORY_BIN_DIR:-${BIN_DIR:-${HOME_DIR}/.local/bin}}")"
BIN="${BIN_DIR}/agent-memory"
GEMINI_DIR="${HOME_DIR}/.gemini"
MCP_DIR="$(expand_tilde_path "${AGENT_MEMORY_MCP_DIR:-${MCP_DIR:-${GEMINI_DIR}/antigravity-cli/mcp/agent-memory}}")"
SKILL_DIR="$(expand_tilde_path "${AGENT_MEMORY_SKILL_DIR:-${SKILL_DIR:-${GEMINI_DIR}/config/skills/agent-memory}}")"
MCP_CONFIG="$(expand_tilde_path "${AGENT_MEMORY_MCP_CONFIG:-${MCP_CONFIG:-${GEMINI_DIR}/config/mcp_config.json}}")"
[ -n "${DB_OVERRIDE}" ] && DB_OVERRIDE="$(expand_tilde_path "${DB_OVERRIDE}")"

# The interpreter is resolved once and pinned (as an absolute path) in the MCP registration, so the
# server does not depend on the client's PATH. The launcher path (e.g. /usr/bin/python3) is kept rather
# than its realpath (e.g. /usr/bin/python3.12) so a distribution Python upgrade does not break the
# registration, and the binary itself refuses to run on Python < 3.10.
command -v python3 >/dev/null 2>&1 || die "python3 (3.10+) is required but was not found in PATH."
python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "Python 3.10+ is required (found $(python3 -V 2>&1))."
PY="$(python3 -I -c 'import os, sys; print(os.path.abspath(sys.executable))')"
[ -x "${PY}" ] || die "could not resolve the python3 interpreter path."

validate_install_paths() {
    "${PY}" -I - "${BUNDLE_BIN}" "${LOG_DIR}" "${BIN_DIR}" "${MCP_DIR}" "${SKILL_DIR}" "${MCP_CONFIG}" "${DB_OVERRIDE}" <<'PY'
import importlib.machinery, importlib.util, os, sys
bundle_bin, log_dir, bin_dir, mcp_dir, skill_dir, mcp_cfg, db_over = sys.argv[1:8]
for label, val in (
    ("LOG_DIR", log_dir),
    ("BIN_DIR", bin_dir),
    ("MCP_DIR", mcp_dir),
    ("SKILL_DIR", skill_dir),
    ("MCP_CONFIG", mcp_cfg),
    ("DB_OVERRIDE", db_over),
):
    if not val:
        continue
    if not os.path.isabs(val):
        sys.exit(f"{label} must be an absolute path (got '{val}').")
if os.path.isfile(bundle_bin):
    env_Copy = os.environ.copy()
    os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
    os.environ["ALLOW_NON_OPTANE"] = "1"
    loader = importlib.machinery.SourceFileLoader("am_path_guard", bundle_bin)
    spec = importlib.util.spec_from_loader("am_path_guard", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    for label, val in (
        ("LOG_DIR", log_dir),
        ("BIN_DIR", bin_dir),
        ("MCP_DIR", mcp_dir),
        ("SKILL_DIR", skill_dir),
        ("DB_OVERRIDE", db_over),
    ):
        if val:
            try:
                mod._check_not_guarded_path(val, label)
            except RuntimeError as exc:
                sys.exit(str(exc))
            for cand in (os.path.abspath(val), os.path.realpath(val)):
                if cand in ("/", "/bin", "/usr", "/usr/bin", "/etc", "/var", mod.AUTH_HOME, os.path.realpath(mod.AUTH_HOME)):
                    if label in ("MCP_DIR", "SKILL_DIR"):
                        sys.exit(f"Refusing unsafe top-level directory for {label}: '{val}'.")
PY
}
VALIDATE_ERR="$(validate_install_paths 2>&1)" || die "${VALIDATE_ERR}"

install_file_atomic() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local dst_dir
    dst_dir="$(dirname "${dst}")"
    mkdir -p "${dst_dir}"
    local tmp
    tmp="$(mktemp "${dst_dir}/.$(basename "${dst}").XXXXXX")"
    cp "${src}" "${tmp}"
    chmod "${mode}" "${tmp}"
    mv -f "${tmp}" "${dst}"
}

# Read or update the agent-memory entry in an MCP JSON config safely: abort on malformed JSON,
# keep the original as <config>.agent-memory.bak (written once), write atomically through
# symlinks, preserve other servers and any extra keys of an existing entry.
mcp_config_edit() {  # $1=check|get-db|get-allow-non-optane|add|remove  $2=config path  [$3=entry-json]
    "${PY}" -I - "$@" <<'PY'
import json, os, shutil, stat, sys, tempfile
action = sys.argv[1]
orig_path = os.path.abspath(os.path.expanduser(sys.argv[2]))
euid = os.geteuid()
if os.path.lexists(orig_path):
    st_l = os.lstat(orig_path)
    if st_l.st_uid != euid:
        sys.exit(f"Error: {orig_path} is owned by uid {st_l.st_uid}, not current user ({euid}).")
path = os.path.realpath(orig_path)
data = {}
orig_mode = 0o600
orig_existed = os.path.exists(path)
if orig_existed:
    try:
        st_existing = os.stat(path)
        if st_existing.st_uid != euid:
            sys.exit(f"Error: {path} is owned by uid {st_existing.st_uid}, not current user ({euid}).")
        if (st_existing.st_mode & 0o022) != 0:
            sys.exit(f"Error: {path} is group/world-writable (mode {oct(st_existing.st_mode & 0o777)}).")
        if (st_existing.st_mode & 0o077) == 0:
            orig_mode = st_existing.st_mode & 0o777
        with open(path, encoding="utf-8") as f:
            text = f.read()
        data = json.loads(text) if text.strip() else {}
    except (OSError, ValueError, TypeError) as e:
        sys.exit(f"Error: {path} is not valid JSON ({e}). Fix it manually (nothing was changed).")
    if not isinstance(data, dict) or not isinstance(data.get("mcpServers", {}), dict):
        sys.exit(f"Error: {path} must be a JSON object whose 'mcpServers' is an object (nothing was changed).")
servers = data.setdefault("mcpServers", {})
if action == "check":
    sys.exit(0)
def _is_placeholder(s: str) -> bool:
    v = s.strip()
    return not v or "$" in v or "<user>" in v.lower() or ("__" in v and v.count("__") >= 2)
if action == "get-db":
    entry = servers.get("agent-memory")
    env = entry.get("env") if isinstance(entry, dict) else None
    raw_val = env.get("AGENT_MEMORY_DB") if isinstance(env, dict) else None
    val = raw_val.strip() if isinstance(raw_val, str) else ""
    print(val if val and not _is_placeholder(val) and os.path.isabs(val) else "")
    sys.exit(0)
if action == "get-allow-non-optane":
    entry = servers.get("agent-memory")
    env = entry.get("env") if isinstance(entry, dict) else None
    raw_val = env.get("ALLOW_NON_OPTANE") if isinstance(env, dict) else None
    if isinstance(raw_val, (str, int, bool)):
        val = str(raw_val).strip().lower()
        if not _is_placeholder(val):
            if val in ("1", "true", "yes", "on"):
                print("1")
                sys.exit(0)
            if val in ("0", "false", "no", "off"):
                print("0")
                sys.exit(0)
    print("")
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
os.makedirs(os.path.dirname(orig_path) or ".", exist_ok=True)
bak_path = orig_path + ".agent-memory.bak"
if action == "add" and orig_existed and not os.path.lexists(bak_path):
    shutil.copy2(path, bak_path)
    try:
        os.chmod(bak_path, 0o600)
    except OSError:
        pass
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".mcp_config.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, orig_mode)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

# ------------------------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------------------------
if [ "${UNINSTALL}" -eq 1 ]; then
    DB_HINT=""
    if [ -f "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ]; then
        MCP_CHK_ERR="$(mcp_config_edit check "${MCP_CONFIG}" 2>&1)" || die "${MCP_CHK_ERR} (nothing was removed)."
        DB_HINT="$(mcp_config_edit get-db "${MCP_CONFIG}")"
        if [ "${DRY_RUN}" -eq 0 ]; then
            mcp_config_edit remove "${MCP_CONFIG}"
            if [ -f "${MCP_CONFIG}.agent-memory.bak" ] || [ -L "${MCP_CONFIG}.agent-memory.bak" ]; then
                say "Removed agent-memory from ${MCP_CONFIG} (original kept as ${MCP_CONFIG}.agent-memory.bak)"
            else
                say "Removed agent-memory from ${MCP_CONFIG}"
            fi
        else
            say "[dry-run] Would remove agent-memory from ${MCP_CONFIG}"
        fi
    fi
    if [ -z "${DB_HINT}" ] && [ -f "${BIN}" ]; then
        DB_HINT="$("${PY}" -I "${BIN}" doctor 2>/dev/null | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin).get("db_path",""))' 2>/dev/null || true)"
    fi
    DB_PATH_RESOLVED="${DB_HINT}"
    if [ "${DRY_RUN}" -eq 0 ]; then
        rm -f "${SKILL_DIR}/SKILL.md" "${SKILL_DIR}/references/agent-memory-mcp.md"
        rmdir "${SKILL_DIR}/references" "${SKILL_DIR}" 2>/dev/null || true
        rm -f "${MCP_DIR}/instructions.md" "${MCP_DIR}"/memory_*.json; rmdir "${MCP_DIR}" 2>/dev/null || true
        rm -f "${BIN}"
        say "Removed ${BIN}, skill and MCP instructions."
    else
        say "[dry-run] Would remove ${BIN}, ${SKILL_DIR}, and ${MCP_DIR}."
    fi
    say "Your memory database was kept${DB_HINT:+ at ${DB_HINT}}. Delete it manually if you no longer need it."
    write_results_json "ok" "uninstall completed"
    exit 0
fi

echo "======================================================================"
echo "Installing agent-memory v${VERSION} for user ${TARGET_USER}"
echo "======================================================================"
say "Python $("${PY}" -I -c 'import platform; print(platform.python_version())') (${PY})"
[ -f "${BUNDLE_BIN}" ] || die "bundle is incomplete: bin/agent-memory not found next to install.sh."
[ -f "${SCRIPT_DIR}/mcp/instructions.md" ] || die "bundle is incomplete: mcp/instructions.md not found next to install.sh."
[ -f "${SCRIPT_DIR}/skill/SKILL.md.template" ] || die "bundle is incomplete: skill/SKILL.md.template not found next to install.sh."
[ -f "${SCRIPT_DIR}/skill/references/agent-memory-mcp.md" ] || die "bundle is incomplete: skill/references/agent-memory-mcp.md not found next to install.sh."
for _schema in memory_record.json memory_search.json memory_recall.json memory_relate.json memory_forget.json; do
    [ -f "${SCRIPT_DIR}/mcp/${_schema}" ] || die "bundle is incomplete: mcp/${_schema} not found next to install.sh."
done

# ------------------------------------------------------------------------------
# 1. Resolve the runtime environment. The MCP registration always carries an explicit
#    env block (ALLOW_NON_OPTANE and AGENT_MEMORY_DB), so inherited variables cannot change it.
# ------------------------------------------------------------------------------
for v in AGENT_MEMORY_DB OPTANE_BASE ALLOW_NON_OPTANE; do
    if [ -n "${!v:-}" ]; then
        warn "Ignoring ${v} from your shell. Use --db / --allow-non-optane so the registered MCP server gets the same setting."
    fi
done
if [ "${CLIENT_CONFIG}" -eq 1 ] && { [ -f "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ]; }; then
    MCP_CHK_ERR="$(mcp_config_edit check "${MCP_CONFIG}" 2>&1)" || die "${MCP_CHK_ERR}"
    EXISTING_ALLOW="$(mcp_config_edit get-allow-non-optane "${MCP_CONFIG}")"
    if [ -z "${ALLOW_NON_OPTANE_FLAG:-}" ] && [ -n "${EXISTING_ALLOW}" ]; then
        ALLOW_NON_OPTANE_FLAG="${EXISTING_ALLOW}"
        say "Preserving ALLOW_NON_OPTANE=${EXISTING_ALLOW} from ${MCP_CONFIG}"
    fi
    if [ -z "${DB_OVERRIDE}" ]; then
        EXISTING_DB="$(mcp_config_edit get-db "${MCP_CONFIG}")"
        if [ -n "${EXISTING_DB}" ]; then
            if [ "${ALLOW_NON_OPTANE_FLAG:-0}" = "0" ] && [ "${EXISTING_ALLOW}" = "1" ] && [[ "${EXISTING_DB}" != /mnt/optane/* ]]; then
                say "Ignoring non-Optane database path from ${MCP_CONFIG} (${EXISTING_DB}) because Optane mode is required"
            else
                DB_OVERRIDE="${EXISTING_DB}"
                say "Preserving registered database path from ${MCP_CONFIG}: ${DB_OVERRIDE}"
            fi
        fi
    fi
fi
ALLOW_NON_OPTANE_FLAG="${ALLOW_NON_OPTANE_FLAG:-0}"
if [ -n "${DB_OVERRIDE}" ]; then
    case "${DB_OVERRIDE}" in
        /*) ;;
        *) die "--db must be an absolute path (got '${DB_OVERRIDE}')." ;;
    esac
    VALIDATE_DB_ERR="$(validate_install_paths 2>&1)" || die "${VALIDATE_DB_ERR}"
fi
ENV_BASE=(env -u AGENT_MEMORY_DB -u OPTANE_BASE -u ALLOW_NON_OPTANE "AGENT_MEMORY_NO_CFG_FALLBACK=1" "ALLOW_NON_OPTANE=${ALLOW_NON_OPTANE_FLAG}")
PRE_ENV=("${ENV_BASE[@]}")
[ -n "${DB_OVERRIDE}" ] && PRE_ENV+=("AGENT_MEMORY_DB=${DB_OVERRIDE}")

# ------------------------------------------------------------------------------
# 2. Preflight (read-only): SQLite features, storage gate, writability, existing database
# ------------------------------------------------------------------------------
DOCTOR_ERR="$(mktemp)"
DOCTOR_OUT="$("${PRE_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" doctor 2>"${DOCTOR_ERR}")" || true
PREFLIGHT_OK="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys
try: d = json.load(sys.stdin)
except (ValueError, TypeError): print("0"); raise SystemExit
if d.get("healthy") is True:
    print("1"); raise SystemExit
gate_ok = str(d.get("storage_gate", "")).startswith("ok")
feat_ok = str(d.get("sqlite_features", "")).startswith("ok")
writ_ok = str(d.get("writable", "")).startswith("ok")
perm_ok = str(d.get("permissions", "")).startswith("ok") and not d.get("permissions_warning")
db_err = d.get("db_error")
integ = d.get("integrity", "ok")
integ_ok = (integ == "ok") or bool(d.get("needs_init"))
fk_ok = str(d.get("foreign_keys", "ok")) == "ok"
print("1" if (gate_ok and feat_ok and writ_ok and perm_ok and not db_err and integ_ok and fk_ok) else "0")
' 2>/dev/null || echo "0")"

if [ "${PREFLIGHT_OK}" != "1" ]; then
    echo "${DOCTOR_OUT}" >&2
    cat "${DOCTOR_ERR}" >&2
    log_debug "ERROR: preflight failed: ${DOCTOR_OUT} $(cat "${DOCTOR_ERR}" 2>/dev/null || true)"
    GATE_FAILED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys
try: d = json.load(sys.stdin)
except (ValueError, TypeError): print(1); raise SystemExit
print(0 if str(d.get("storage_gate", "")).startswith("ok") else 1)' 2>/dev/null || echo 1)"
    WRITABLE_FAILED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys
try: d = json.load(sys.stdin)
except (ValueError, TypeError): print(1); raise SystemExit
print(0 if str(d.get("writable", "")).startswith("ok") else 1)' 2>/dev/null || echo 1)"
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
    write_results_json "error" "preflight failed"
    exit 1
fi
DB_PATH_RESOLVED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin).get("db_path", ""))' 2>/dev/null || true)"
[ -n "${DB_PATH_RESOLVED}" ] || die "preflight doctor did not return a valid db_path."
say "Preflight passed (database: ${DB_PATH_RESOLVED})"
[ "${ALLOW_NON_OPTANE_FLAG}" -eq 1 ] && warn "Non-Optane override is active (ALLOW_NON_OPTANE=1)."
RUN_ENV=("${ENV_BASE[@]}" "AGENT_MEMORY_DB=${DB_PATH_RESOLVED}")

# Antigravity is configured only when it is actually present (Gemini CLI also uses ~/.gemini).
DO_ANTIGRAVITY=0
if [ "${CLIENT_CONFIG}" -eq 1 ] && { [ -d "${GEMINI_DIR}/antigravity-cli" ] || [ -e "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ] || command -v agy >/dev/null 2>&1; }; then
    DO_ANTIGRAVITY=1
    MCP_CHK_ERR="$(mcp_config_edit check "${MCP_CONFIG}" 2>&1)" || die "${MCP_CHK_ERR}"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    say "[dry-run] Preflight passed. Would initialize ${DB_PATH_RESOLVED} and install ${BIN}."
    write_results_json "ok" "dry-run preflight passed"
    exit 0
fi

# ------------------------------------------------------------------------------
# 3. Initialise (or migrate, with an automatic backup) and self-test using the bundle
#    binary, before anything is installed or registered.
# ------------------------------------------------------------------------------
INIT_OUT="$("${RUN_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" init 2>&1)" || die "database init failed: ${INIT_OUT}"
say "${INIT_OUT}"
POST_DOCTOR_OUT="$("${RUN_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" doctor 2>&1)" || {
    printf '%s\n' "${POST_DOCTOR_OUT}" >&2
    die "post-init doctor check failed."
}

SELFTEST_OUT="$("${RUN_ENV[@]}" "${PY}" -I - "${PY}" "${BUNDLE_BIN}" 2>&1 <<'PY'
import json, subprocess, sys, uuid
cmd = [sys.argv[1], "-I", sys.argv[2]]
def run(*a, inp=None):
    p = subprocess.run([*cmd, *a], capture_output=True, text=True, input=inp, timeout=60)
    if p.returncode != 0:
        sys.exit(f"Self-test failed: agent-memory {' '.join(a)}: {p.stdout}{p.stderr}")
    return p.stdout
tok = "installprobe" + uuid.uuid4().hex[:12]
oid = json.loads(run("record", f"agent-memory install self-test {tok}", "--session", "install-selftest"))["observation_id"]
deleted = False
try:
    hits = json.loads(run("search", tok))
    if not any(h.get("observation_id") == oid for h in hits):
        sys.exit(f"Self-test failed: probe not found by search: {hits}")
    if json.loads(run("forget", "--observation", oid)).get("deleted_observations") != 1:
        sys.exit("Self-test failed: probe could not be deleted")
    deleted = True
finally:
    if not deleted:
        subprocess.run([*cmd, "forget", "--observation", oid], capture_output=True, text=True, timeout=30)
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
print(f"Self-test passed: record -> search -> forget round trip, MCP handshake and tool call ({len(names)} tools), with no data left behind")
PY
)" || die "${SELFTEST_OUT}"
say "${SELFTEST_OUT}"

# ------------------------------------------------------------------------------
# 4. Install the binary (atomic replace)
# ------------------------------------------------------------------------------
if [ ! -d "${BIN_DIR}" ]; then
    mkdir -p "${BIN_DIR}"
    chmod 755 "${BIN_DIR}" 2>/dev/null || true
fi
TMP_BIN="$(mktemp "${BIN_DIR}/.agent-memory.XXXXXX")"
cp "${BUNDLE_BIN}" "${TMP_BIN}"
chmod 755 "${TMP_BIN}"
mv -f "${TMP_BIN}" "${BIN}"
TMP_BIN=""
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
    chmod 755 "${MCP_DIR}" 2>/dev/null || true
    install_file_atomic "${SCRIPT_DIR}/mcp/instructions.md" "${MCP_DIR}/instructions.md" 644
    say "Installed MCP instructions to ${MCP_DIR}"
    for _schema in memory_record.json memory_search.json memory_recall.json memory_relate.json memory_forget.json; do
        install_file_atomic "${SCRIPT_DIR}/mcp/${_schema}" "${MCP_DIR}/${_schema}" 644
    done
    say "Installed MCP tool schemas to ${MCP_DIR}"
    mkdir -p "${SKILL_DIR}/references"
    chmod 755 "${SKILL_DIR}" "${SKILL_DIR}/references" 2>/dev/null || true
    install_file_atomic "${SCRIPT_DIR}/skill/references/agent-memory-mcp.md" "${SKILL_DIR}/references/agent-memory-mcp.md" 644
    SKILL_DB_DISPLAY="/mnt/optane/\${USER}/agent_memory/memory.db"
    SKILL_CLI_DISPLAY="env ALLOW_NON_OPTANE=0 AGENT_MEMORY_DB=\"/mnt/optane/\${USER}/agent_memory/memory.db\" ${PY} -I \"\${HOME}/.local/bin/agent-memory\""
    "${PY}" -I - "${SCRIPT_DIR}/skill/SKILL.md.template" "${SKILL_DIR}/SKILL.md" "${SKILL_DB_DISPLAY}" "${SKILL_CLI_DISPLAY}" <<'PY'
import os, sys, tempfile
src, dst, db, cli = sys.argv[1:5]
with open(src, encoding="utf-8") as sf:
    text = sf.read().replace("__DB__", db).replace("__CLI__", cli).replace("__STORAGE_DESC__", "stored on a dedicated fast volume")
dst_dir = os.path.dirname(dst) or "."
os.makedirs(dst_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".SKILL.md.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, dst)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    say "Installed skill and reference to ${SKILL_DIR}"
fi

write_results_json "ok" "installation completed"

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
