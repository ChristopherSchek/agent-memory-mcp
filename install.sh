#!/usr/bin/env bash
# Copyright (c) 2026 Christopher Schek
# SPDX-License-Identifier: GPL-3.0-only
# Installs, validates, or uninstalls the agent-memory binary, skill files, and MCP server registration so persistent memory operates safely, preventing unverified storage or broken client configs.
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
SCRIPT_DIR="$(CDPATH="" cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUNDLE_BIN="${SCRIPT_DIR}/bin/agent-memory"

ALLOW_NON_OPTANE_FLAG=""
DB_OVERRIDE=""
UNINSTALL=0
CLIENT_CONFIG=1
DRY_RUN=0
VALIDATE_ARGS=0
JSON_OUT=0
LOG_DIR=""
LOG_DIR_VALIDATED=0
VALIDATED_LOG_DIR=""
RESULTS_WRITTEN=0
DB_PATH_RESOLVED=""
TMP_BIN=""
TMP_ATOMIC=""
DOCTOR_ERR=""
START_EPOCH_MS="$(python3 -I -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 0)"

usage() {
    cat <<'EOF'
agent-memory installer (v1.0.0, schema 1.0)
Per-user, Optane-backed persistent memory for AI agents (CLI + stdio MCP server).

  ./install.sh                         Install on a host with a verified Intel Optane
                                       volume at /mnt/optane/$USER.
  ./install.sh --allow-non-optane      Explicit opt-in to run on ordinary storage
               [--db /abs/path.db]     (default: /mnt/optane/$USER if owned by $USER,
                                       else ~/.local/share/agent-memory/memory.db).
  ./install.sh --require-optane        Require verified Intel Optane storage (also
                                       --no-allow-non-optane or --allow-non-optane=0).
  ./install.sh --db /mnt/optane/$USER/custom/memory.db
  ./install.sh --no-client-config      Install and self-test only, then print client snippets.
  ./install.sh --dry-run               Run preflight checks without modifying files.
  ./install.sh --validate-args         Validate CLI arguments and target paths, then exit.
  ./install.sh --json                  Emit structured JSON summary to stdout.
  ./install.sh --version               Print installer version and exit.
  ./install.sh --log-dir /abs/dir      Write Tri-Stream telemetry (results.json, debug.log).
  ./install.sh --uninstall             Remove binary, skill and MCP registration (keeps data).

Environment variables:
  AGENT_MEMORY_BIN_DIR / BIN_DIR       Target directory for agent-memory binary
  AGENT_MEMORY_MCP_DIR / MCP_DIR       Target directory for MCP instructions
  AGENT_MEMORY_SKILL_DIR / SKILL_DIR   Target directory for agent-memory skill
  AGENT_MEMORY_MCP_CONFIG / MCP_CONFIG Target path for client mcp_config.json
  ALLOW_ROOT=1                         Override restriction against running as root
  (Shell AGENT_MEMORY_DB, OPTANE_BASE, and ALLOW_NON_OPTANE are ignored during install
   so the registered MCP entry matches explicit --db / --allow-non-optane flags.)

Nothing is installed or registered until preflight, initialisation and self-test pass.
EOF
}

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

redact_line() {
    local raw_str="$1"
    if command -v python3 >/dev/null 2>&1 && [ -f "${BUNDLE_BIN}" ]; then
        python3 -I - "${BUNDLE_BIN}" "${raw_str}" 2>/dev/null <<'PY' || printf '%s' "${raw_str}"
"""Redacts secret patterns and high-entropy credentials from a single log line using bin/agent-memory patterns so debug logs stay clean-room safe, preventing credential leaks in debug.log."""
import importlib.machinery, importlib.util, os, sys
bundle_bin, text = sys.argv[1:3]
os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
os.environ["ALLOW_NON_OPTANE"] = "1"
os.environ.pop("AGENT_MEMORY_DB", None)
os.environ.pop("OPTANE_BASE", None)
loader = importlib.machinery.SourceFileLoader("am_redact", bundle_bin)
spec = importlib.util.spec_from_loader("am_redact", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
out = text
for item in getattr(mod, "_SECRET_PATTERNS", ()):
    pat = item[0] if isinstance(item, tuple) else item
    out = pat.sub("[REDACTED]", out)
out = "".join(ch if (ch in "\n\t" or " " <= ch <= "~") else "?" for ch in out)
if getattr(mod, "_screen_for_secrets", lambda s: None)(out) is not None:
    out = "[REDACTED: potential secret]"
sys.stdout.write(out)
PY
    else
        printf '%s' "${raw_str}"
    fi
}

log_debug() {
    if [ "${LOG_DIR_VALIDATED}" -eq 1 ] && [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" == /* ]] && [ -d "${LOG_DIR}" ] && [ ! -L "${LOG_DIR}" ] && [ ! -L "${LOG_DIR}/debug.log" ]; then
        local safe_msg
        safe_msg="$(redact_line "$*")"
        printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${safe_msg}" >> "${LOG_DIR}/debug.log"
        chmod 600 "${LOG_DIR}/debug.log" 2>/dev/null || true
    fi
}

write_results_json() {
    local status="$1"
    local detail="$2"
    local exit_code="${3:-0}"
    if [ "${LOG_DIR_VALIDATED}" -eq 1 ] && [ -n "${LOG_DIR}" ] && [[ "${LOG_DIR}" == /* ]] && [ -d "${LOG_DIR}" ] && [ ! -L "${LOG_DIR}" ] && command -v python3 >/dev/null 2>&1; then
        python3 -I - "${LOG_DIR}/results.json" "${status}" "${detail}" "${DB_PATH_RESOLVED:-}" "${DRY_RUN}" "${UNINSTALL}" "${exit_code}" "${VERSION}" "${START_EPOCH_MS}" "${BUNDLE_BIN}" <<'PY'
"""Writes the canonical Tri-Stream results.json envelope atomically with secret redaction, 64 KiB cap, fsync, and 0600 permissions so installer status is recorded deterministically, preventing partial or schema-invalid telemetry files."""
import importlib.machinery, importlib.util, json, os, socket, stat, sys, tempfile, time
dst, raw_status, detail, db_path, dry_run, uninstall, raw_rc, ver, start_ms, bundle_bin = sys.argv[1:11]
MAX_BYTES = 65536
parsed_rc = int(raw_rc) if raw_rc.lstrip("-").isdigit() else (0 if raw_status in ("ok", "success") else 1)
rc = parsed_rc if 0 <= parsed_rc <= 255 else (1 if parsed_rc else 0)
status = "success" if rc == 0 else "error"
if os.path.lexists(dst):
    st = os.lstat(dst)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
        sys.exit(1)
mod = None
if os.path.isfile(bundle_bin):
    try:
        os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
        os.environ["ALLOW_NON_OPTANE"] = "1"
        os.environ.pop("AGENT_MEMORY_DB", None)
        os.environ.pop("OPTANE_BASE", None)
        loader = importlib.machinery.SourceFileLoader("am_res_redact", bundle_bin)
        spec = importlib.util.spec_from_loader("am_res_redact", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
    except Exception:
        mod = None
def _clean_str(val: str) -> str:
    """Scrubs secret patterns and high-entropy credentials from a string value so telemetry fields remain clean-room safe, preventing credential leaks in results.json."""
    out = val or ""
    if mod is not None:
        for item in getattr(mod, "_SECRET_PATTERNS", ()):
            pat = item[0] if isinstance(item, tuple) else item
            out = pat.sub("[REDACTED]", out)
        out = "".join(ch if (ch in "\n\t" or " " <= ch <= "~") else "?" for ch in out)
        if getattr(mod, "_screen_for_secrets", lambda s: None)(out) is not None:
            return "[REDACTED: potential secret]"
    return out
clean_detail = _clean_str(detail).strip()
fallback_msg = "installation completed" if status == "success" else "installation failed"
summary_str = (clean_detail or fallback_msg)[:4000]
clean_db = _clean_str(db_path).strip()
errors = [] if status == "success" else [{"code": "INSTALL_ARGS_ERROR" if rc == 2 else "INSTALL_ERROR", "message": summary_str[:2000]}]
try:
    dur_ms = round(max(0.0, time.time() * 1000.0 - float(start_ms)), 2) if float(start_ms) > 0 else 0.0
except ValueError:
    dur_ms = 0.0
payload = {
    "status": status,
    "exit_code": rc,
    "dry_run": dry_run == "1",
    "truncated": False,
    "summary": summary_str,
    "errors": errors,
    "data": {
        "detail": summary_str,
        "db_path": clean_db,
        "uninstall": uninstall == "1",
    },
    "metadata": {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "duration_ms": dur_ms,
        "host": socket.gethostname() or "localhost",
        "version": ver,
        "pid": os.getpid(),
        "tool_name": "install.sh",
    },
}
raw_bytes = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
if len(raw_bytes) > MAX_BYTES:
    payload["truncated"] = True
    payload["data"] = {"uninstall": uninstall == "1", "truncated": True}
    payload["summary"] = (summary_str[:256].strip() or fallback_msg)
    if status == "error":
        payload["errors"] = [{"code": errors[0]["code"], "message": (summary_str[:256].strip() or fallback_msg)}]
    raw_bytes = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
dst_dir = os.path.dirname(dst) or "."
fd, tmp = tempfile.mkstemp(dir=dst_dir, prefix=".results.json.")
try:
    with os.fdopen(fd, "wb") as f:
        f.write(raw_bytes)
        f.flush()
        os.fsync(f.fileno())
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
    set +eu
    trap '' INT TERM
    [ -n "${DOCTOR_ERR:-}" ] && rm -f "${DOCTOR_ERR}"
    [ -n "${TMP_BIN:-}" ] && rm -f "${TMP_BIN}"
    [ -n "${TMP_ATOMIC:-}" ] && rm -f "${TMP_ATOMIC}"
    if [ "${rc}" -ne 0 ] && [ "${RESULTS_WRITTEN:-0}" -eq 0 ]; then
        log_debug "ERROR: installer aborted (exit ${rc})"
        write_results_json "error" "aborted (exit ${rc})" "${rc}" || true
    fi
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pre_init_log_dir() {
    local raw_log=""
    local raw_db=""
    local prev_is_log=0
    local prev_is_db=0
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -h|--help|-v|--version) return 0 ;;
        esac
        if [ "${prev_is_log}" -eq 1 ]; then
            prev_is_log=0
            if [ -n "${arg}" ] && [[ "${arg}" != -* ]]; then
                raw_log="${arg}"
                continue
            fi
            raw_log=""
        fi
        if [ "${prev_is_db}" -eq 1 ]; then
            prev_is_db=0
            if [ -n "${arg}" ] && [[ "${arg}" != -* ]]; then
                raw_db="${arg}"
                continue
            fi
            raw_db=""
        fi
        case "${arg}" in
            --log-dir) raw_log=""; prev_is_log=1 ;;
            --log-dir=*) raw_log="${arg#--log-dir=}" ;;
            --db) raw_db=""; prev_is_db=1 ;;
            --db=*) raw_db="${arg#--db=}" ;;
        esac
    done
    [ "${prev_is_log}" -eq 0 ] || raw_log=""
    [ "${prev_is_db}" -eq 0 ] || raw_db=""
    [ -n "${raw_log}" ] || return 0
    raw_log="$(expand_tilde_path "${raw_log}")"
    [ -n "${raw_db}" ] && raw_db="$(expand_tilde_path "${raw_db}")"
    command -v python3 >/dev/null 2>&1 || return 0
    if python3 -I - "${BUNDLE_BIN}" "${raw_log}" "${raw_db}" 2>/dev/null <<'PY'; then
"""Validates --log-dir before CLI flag parsing so early exit code 2 argument errors still emit Tri-Stream telemetry when --log-dir is valid, preventing missing results.json on syntax errors."""
import importlib.machinery, importlib.util, os, stat, sys
bundle_bin, log_dir, raw_db = sys.argv[1:4]
if not os.path.isabs(log_dir) or not os.path.isfile(bundle_bin):
    sys.exit(1)
os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
os.environ["ALLOW_NON_OPTANE"] = "1"
env_db = os.environ.pop("AGENT_MEMORY_DB", "").strip()
env_opt = os.environ.pop("OPTANE_BASE", "").strip()
loader = importlib.machinery.SourceFileLoader("am_pre_log", bundle_bin)
spec = importlib.util.spec_from_loader("am_pre_log", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
unsafe_top = {"/", "/bin", "/usr", "/usr/bin", "/etc", "/var", os.path.join("/", "tmp"), os.path.join("/", "var", "tmp"), mod.AUTH_HOME, os.path.realpath(mod.AUTH_HOME)}
abs_log = os.path.abspath(log_dir)
real_log = os.path.realpath(abs_log)
if abs_log in unsafe_top or real_log in unsafe_top:
    sys.exit(1)
for p in (abs_log, real_log):
    if ".git" in [seg for seg in p.split("/") if seg]:
        sys.exit(1)
mod._check_not_guarded_path(abs_log, "LOG_DIR")
h_dir = mod.AUTH_HOME
bin_d = os.environ.get("AGENT_MEMORY_BIN_DIR") or os.environ.get("BIN_DIR") or os.path.join(h_dir, ".local", "bin")
mcp_d = os.environ.get("AGENT_MEMORY_MCP_DIR") or os.environ.get("MCP_DIR") or os.path.join(h_dir, ".gemini", "antigravity-cli", "mcp", "agent-memory")
skill_d = os.environ.get("AGENT_MEMORY_SKILL_DIR") or os.environ.get("SKILL_DIR") or os.path.join(h_dir, ".gemini", "config", "skills", "agent-memory")
mcp_c = os.environ.get("AGENT_MEMORY_MCP_CONFIG") or os.environ.get("MCP_CONFIG") or os.path.join(h_dir, ".gemini", "config", "mcp_config.json")
for t_val in (bin_d, mcp_d, skill_d, mcp_c):
    if t_val:
        at = os.path.abspath(os.path.expanduser(t_val))
        rt = os.path.realpath(at)
        if abs_log in (at, rt) or real_log in (at, rt) or abs_log.startswith(at.rstrip("/") + "/") or at.startswith(abs_log.rstrip("/") + "/") or real_log.startswith(rt.rstrip("/") + "/") or rt.startswith(real_log.rstrip("/") + "/"):
            sys.exit(1)
opt_db = os.path.join(getattr(mod, "_OPTANE_DEFAULT_DIR", os.path.join(getattr(mod, "OPTANE_BASE", f"/mnt/optane/{getattr(mod, 'AUTH_USER', '')}"), "agent_memory")), "memory.db")
env_opt_db = os.path.join(env_opt, "agent_memory", "memory.db") if env_opt else ""
non_opt_db = os.path.join(h_dir, ".local", "share", "agent-memory", "memory.db")
for cand_db in (raw_db, env_db, env_opt_db, opt_db, non_opt_db, getattr(mod, "DB_PATH", ""), getattr(mod, "_RAW_DB_PATH", "")):
    if not cand_db or not os.path.isabs(cand_db):
        continue
    abs_db = os.path.abspath(cand_db)
    real_db = os.path.realpath(abs_db)
    db_dir = os.path.dirname(abs_db)
    real_db_dir = os.path.dirname(real_db)
    if abs_log in (abs_db, db_dir) or real_log in (real_db, real_db_dir) or abs_db.startswith(abs_log.rstrip("/") + "/") or abs_log.startswith(abs_db.rstrip("/") + "/") or real_db.startswith(real_log.rstrip("/") + "/") or real_log.startswith(real_db.rstrip("/") + "/"):
        sys.exit(1)
    if (os.path.basename(db_dir) in ("agent_memory", "agent-memory") and abs_log.startswith(db_dir.rstrip("/") + "/")) or (os.path.basename(real_db_dir) in ("agent_memory", "agent-memory") and real_log.startswith(real_db_dir.rstrip("/") + "/")):
        sys.exit(1)
cur = abs_log
while True:
    if os.path.lexists(cur):
        st_c = os.lstat(cur)
        if stat.S_ISLNK(st_c.st_mode):
            sys.exit(1)
        if cur == abs_log and not stat.S_ISDIR(st_c.st_mode):
            sys.exit(1)
    parent = os.path.dirname(cur)
    if parent == cur:
        break
    cur = parent
for leaf in ("debug.log", "results.json"):
    lp = os.path.join(abs_log, leaf)
    if os.path.lexists(lp):
        st_l = os.lstat(lp)
        if stat.S_ISLNK(st_l.st_mode) or not stat.S_ISREG(st_l.st_mode) or st_l.st_nlink != 1:
            sys.exit(1)
PY
        LOG_DIR="${raw_log}"
        mkdir -p "${LOG_DIR}"
        chmod 700 "${LOG_DIR}"
        if [ ! -L "${LOG_DIR}" ] && [ ! -L "${LOG_DIR}/debug.log" ]; then
            [ -f "${LOG_DIR}/debug.log" ] || : > "${LOG_DIR}/debug.log"
            chmod 600 "${LOG_DIR}/debug.log"
            LOG_DIR_VALIDATED=1
            VALIDATED_LOG_DIR="${LOG_DIR}"
        fi
    fi
}

pre_init_log_dir "$@"

arg_die() {
    printf 'Error: %s\n' "$1" >&2
    log_debug "ERROR: $1"
    write_results_json "error" "$1" 2
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
        --validate-args) VALIDATE_ARGS=1 ;;
        --json) JSON_OUT=1 ;;
        --version|-v) printf 'install.sh %s\n' "${VERSION}"; exit 0 ;;
        --uninstall) UNINSTALL=1 ;;
        --no-client-config) CLIENT_CONFIG=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; arg_die "unknown option '$1'" ;;
    esac
    shift
done

say() {
    if [ "${JSON_OUT}" -eq 1 ]; then
        printf '[+] %s\n' "$*" >&2
    else
        printf '[+] %s\n' "$*"
    fi
    log_debug "INFO: $*"
}
warn() { printf '[!] %s\n' "$*" >&2; log_debug "WARN: $*"; }
die()  { printf 'Error: %s\n' "$*" >&2; log_debug "ERROR: $*"; write_results_json "error" "$*" 1; exit 1; }

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

[ -n "${LOG_DIR}" ] && LOG_DIR="$(expand_tilde_path "${LOG_DIR}")"
DEFAULT_MCP_CONFIG="${HOME_DIR}/.gemini/config/mcp_config.json"
BIN_DIR="$(expand_tilde_path "${AGENT_MEMORY_BIN_DIR:-${BIN_DIR:-${HOME_DIR}/.local/bin}}")"
BIN="${BIN_DIR}/agent-memory"
GEMINI_DIR="${HOME_DIR}/.gemini"
MCP_DIR="$(expand_tilde_path "${AGENT_MEMORY_MCP_DIR:-${MCP_DIR:-${GEMINI_DIR}/antigravity-cli/mcp/agent-memory}}")"
SKILL_DIR="$(expand_tilde_path "${AGENT_MEMORY_SKILL_DIR:-${SKILL_DIR:-${GEMINI_DIR}/config/skills/agent-memory}}")"
MCP_CONFIG="$(expand_tilde_path "${AGENT_MEMORY_MCP_CONFIG:-${MCP_CONFIG:-${DEFAULT_MCP_CONFIG}}}")"
[ -n "${DB_OVERRIDE}" ] && DB_OVERRIDE="$(expand_tilde_path "${DB_OVERRIDE}")"

command -v python3 >/dev/null 2>&1 || die "python3 (3.10+) is required but was not found in PATH."
python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "Python 3.10+ is required (found $(python3 -V 2>&1))."
PY="$(python3 -I -c 'import os, sys; print(os.path.abspath(sys.executable))')"
[ -x "${PY}" ] || die "could not resolve the python3 interpreter path."

validate_install_paths() {
    "${PY}" -I - "${BUNDLE_BIN}" "${LOG_DIR}" "${BIN_DIR}" "${MCP_DIR}" "${SKILL_DIR}" "${MCP_CONFIG}" "${DB_OVERRIDE}" "${DEFAULT_MCP_CONFIG}" <<'PY'
"""Validates installer target paths against relative paths, unsafe top-level directories, symlinks, and host perimeter quarantine rules so installation cannot clobber sensitive stores, preventing path traversal or perimeter breaches."""
import importlib.machinery, importlib.util, os, stat, sys
bundle_bin, log_dir, bin_dir, mcp_dir, skill_dir, mcp_cfg, db_over, def_mcp_cfg = sys.argv[1:9]
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
if not os.path.isfile(bundle_bin):
    sys.exit(f"bundle is incomplete: bin/agent-memory not found at '{bundle_bin}'.")
os.environ["AGENT_MEMORY_NO_CFG_FALLBACK"] = "1"
os.environ["ALLOW_NON_OPTANE"] = "1"
env_db = os.environ.pop("AGENT_MEMORY_DB", "").strip()
env_opt = os.environ.pop("OPTANE_BASE", "").strip()
loader = importlib.machinery.SourceFileLoader("am_path_guard", bundle_bin)
spec = importlib.util.spec_from_loader("am_path_guard", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
unsafe_top = {"/", "/bin", "/usr", "/usr/bin", "/etc", "/var", os.path.join("/", "tmp"), os.path.join("/", "var", "tmp"), mod.AUTH_HOME, os.path.realpath(mod.AUTH_HOME)}
for label, val in (
    ("LOG_DIR", log_dir),
    ("BIN_DIR", bin_dir),
    ("MCP_DIR", mcp_dir),
    ("SKILL_DIR", skill_dir),
    ("DB_OVERRIDE", db_over),
    ("MCP_CONFIG", mcp_cfg),
):
    if not val:
        continue
    abs_v = os.path.abspath(val)
    real_v = os.path.realpath(abs_v)
    if abs_v in unsafe_top or real_v in unsafe_top:
        sys.exit(f"Refusing unsafe top-level directory for {label}: '{val}'.")
    if label == "DB_OVERRIDE":
        v_str = val.strip()
        if "$" in v_str or "<user>" in v_str.lower() or ("__" in v_str and v_str.count("__") >= 2):
            sys.exit(f"Refusing unexpanded template placeholder for {label}: '{val}'.")
        if val.endswith("/") or os.path.isdir(abs_v):
            sys.exit(f"{label} must be a database file path, not a directory: '{val}'.")
    if label == "MCP_CONFIG":
        if os.path.lexists(abs_v):
            st_m = os.lstat(abs_v)
            if stat.S_ISLNK(st_m.st_mode) or not stat.S_ISREG(st_m.st_mode) or st_m.st_nlink != 1:
                sys.exit(f"Refusing symlink, hardlink, or non-regular file for {label}: '{val}'.")
        cur_p = os.path.dirname(abs_v)
        while True:
            if os.path.lexists(cur_p) and stat.S_ISLNK(os.lstat(cur_p).st_mode):
                sys.exit(f"Refusing symlinked parent directory for {label}: '{cur_p}'.")
            par_p = os.path.dirname(cur_p)
            if par_p == cur_p:
                break
            cur_p = par_p
        if abs_v == os.path.abspath(def_mcp_cfg):
            continue
    if label in ("BIN_DIR", "MCP_DIR", "SKILL_DIR"):
        cur_d = abs_v
        while True:
            if os.path.lexists(cur_d):
                st_d = os.lstat(cur_d)
                if stat.S_ISLNK(st_d.st_mode):
                    sys.exit(f"Refusing symlinked directory component for {label}: '{cur_d}'.")
                if cur_d == abs_v and not stat.S_ISDIR(st_d.st_mode):
                    sys.exit(f"Refusing non-directory target for {label}: '{abs_v}'.")
            par_d = os.path.dirname(cur_d)
            if par_d == cur_d:
                break
            cur_d = par_d
    try:
        mod._check_not_guarded_path(val, label)
    except RuntimeError as exc:
        sys.exit(str(exc))
for dir_lbl, dir_val, leaves in (
    ("BIN_DIR", bin_dir, ("agent-memory",)),
    ("SKILL_DIR", skill_dir, ("SKILL.md", "references", "references/agent-memory-mcp.md")),
    ("MCP_DIR", mcp_dir, ("instructions.md", "memory_record.json", "memory_search.json", "memory_recall.json", "memory_relate.json", "memory_forget.json")),
):
    if not dir_val:
        continue
    abs_d = os.path.abspath(dir_val)
    for lf in leaves:
        lp = os.path.join(abs_d, lf)
        if os.path.lexists(lp):
            st_lf = os.lstat(lp)
            if stat.S_ISLNK(st_lf.st_mode):
                sys.exit(f"Refusing symlinked target in {dir_lbl}: '{lp}'.")
            if lf != "references" and (not stat.S_ISREG(st_lf.st_mode) or st_lf.st_nlink != 1):
                sys.exit(f"Refusing non-regular or hardlinked target in {dir_lbl}: '{lp}'.")
if log_dir:
    abs_log = os.path.abspath(log_dir)
    real_log = os.path.realpath(abs_log)
    for target_lbl, target_val in (("BIN_DIR", bin_dir), ("MCP_DIR", mcp_dir), ("SKILL_DIR", skill_dir), ("MCP_CONFIG", mcp_cfg)):
        if target_val:
            at = os.path.abspath(target_val)
            rt = os.path.realpath(at)
            if abs_log in (at, rt) or real_log in (at, rt) or abs_log.startswith(at.rstrip("/") + "/") or at.startswith(abs_log.rstrip("/") + "/") or real_log.startswith(rt.rstrip("/") + "/") or rt.startswith(real_log.rstrip("/") + "/"):
                sys.exit(f"Refusing LOG_DIR colliding with {target_lbl}: '{log_dir}'.")
    opt_db = os.path.join(getattr(mod, "_OPTANE_DEFAULT_DIR", os.path.join(getattr(mod, "OPTANE_BASE", f"/mnt/optane/{getattr(mod, 'AUTH_USER', '')}"), "agent_memory")), "memory.db")
    env_opt_db = os.path.join(env_opt, "agent_memory", "memory.db") if env_opt else ""
    non_opt_db = os.path.join(mod.AUTH_HOME, ".local", "share", "agent-memory", "memory.db")
    for cand_db in (db_over, env_db, env_opt_db, opt_db, non_opt_db, getattr(mod, "DB_PATH", ""), getattr(mod, "_RAW_DB_PATH", "")):
        if not cand_db:
            continue
        abs_db = os.path.abspath(cand_db)
        real_db = os.path.realpath(abs_db)
        db_dir = os.path.dirname(abs_db)
        real_db_dir = os.path.dirname(real_db)
        if abs_log in (abs_db, db_dir) or real_log in (real_db, real_db_dir):
            sys.exit(f"Refusing LOG_DIR colliding with database path or directory: '{log_dir}'.")
        if abs_db.startswith(abs_log.rstrip("/") + "/") or abs_log.startswith(abs_db.rstrip("/") + "/") or real_db.startswith(real_log.rstrip("/") + "/") or real_log.startswith(real_db.rstrip("/") + "/"):
            sys.exit(f"Refusing LOG_DIR overlapping database path: '{log_dir}'.")
        if (os.path.basename(db_dir) in ("agent_memory", "agent-memory") and abs_log.startswith(db_dir.rstrip("/") + "/")) or (os.path.basename(real_db_dir) in ("agent_memory", "agent-memory") and real_log.startswith(real_db_dir.rstrip("/") + "/")):
            sys.exit(f"Refusing LOG_DIR inside dedicated database directory: '{log_dir}'.")
    cur = abs_log
    while True:
        if os.path.lexists(cur):
            st_c = os.lstat(cur)
            if stat.S_ISLNK(st_c.st_mode):
                sys.exit(f"Refusing symlinked LOG_DIR component: '{cur}'.")
            if cur == abs_log and not stat.S_ISDIR(st_c.st_mode):
                sys.exit(f"LOG_DIR exists and is not a directory: '{abs_log}'.")
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    for leaf in ("debug.log", "results.json"):
        lp = os.path.join(abs_log, leaf)
        if os.path.lexists(lp):
            st_l = os.lstat(lp)
            if stat.S_ISLNK(st_l.st_mode) or not stat.S_ISREG(st_l.st_mode) or st_l.st_nlink != 1:
                sys.exit(f"Refusing symlink or non-regular file in LOG_DIR: '{lp}'.")
PY
}

if ! VALIDATE_ERR="$(validate_install_paths 2>&1)"; then
    if [ "${LOG_DIR_VALIDATED}" -ne 1 ] || [ "${LOG_DIR}" != "${VALIDATED_LOG_DIR:-}" ] || [[ "${VALIDATE_ERR}" == *LOG_DIR* ]]; then
        LOG_DIR=""
        LOG_DIR_VALIDATED=0
    fi
    arg_die "${VALIDATE_ERR}"
fi

if [ -n "${LOG_DIR}" ] && [ "${LOG_DIR_VALIDATED}" -eq 0 ]; then
    mkdir -p "${LOG_DIR}"
    chmod 700 "${LOG_DIR}"
    [ -L "${LOG_DIR}" ] && { LOG_DIR=""; die "Refusing symlinked --log-dir."; }
    [ -L "${LOG_DIR}/debug.log" ] && { LOG_DIR=""; die "Refusing symlinked debug.log in --log-dir."; }
    [ -f "${LOG_DIR}/debug.log" ] || : > "${LOG_DIR}/debug.log"
    chmod 600 "${LOG_DIR}/debug.log"
    LOG_DIR_VALIDATED=1
fi

if [ "${VALIDATE_ARGS}" -eq 1 ]; then
    say "Validated installer arguments and target paths."
    write_results_json "success" "Validated installer arguments and target paths." 0
    if [ "${JSON_OUT}" -eq 1 ]; then
        printf '{"status": "success", "dry_run": %s, "uninstall": %s}\n' "$([ "${DRY_RUN}" -eq 1 ] && echo true || echo false)" "$([ "${UNINSTALL}" -eq 1 ] && echo true || echo false)"
    fi
    exit 0
fi

install_file_atomic() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local dst_dir
    dst_dir="$(dirname "${dst}")"
    mkdir -p "${dst_dir}"
    [ ! -L "${dst_dir}" ] || die "Refusing symlinked destination directory: ${dst_dir}"
    [ ! -L "${dst}" ] || die "Refusing symlinked destination file: ${dst}"
    [ ! -d "${dst}" ] || die "Refusing directory at destination file path: ${dst}"
    TMP_ATOMIC="$(mktemp "${dst_dir}/.$(basename "${dst}").XXXXXX")"
    cp "${src}" "${TMP_ATOMIC}"
    chmod "${mode}" "${TMP_ATOMIC}"
    mv -f "${TMP_ATOMIC}" "${dst}"
    TMP_ATOMIC=""
}

mcp_config_edit() {
    "${PY}" -I - "$@" <<'PY'
"""Inspects or atomically updates the agent-memory server entry in mcp_config.json with mode 0600 permissions so existing client server registrations remain intact, preventing configuration loss or permission widening."""
import json, os, stat, sys, tempfile
action = sys.argv[1]
orig_path = os.path.abspath(os.path.expanduser(sys.argv[2]))
euid = os.geteuid()
if os.path.lexists(orig_path):
    st_l = os.lstat(orig_path)
    if st_l.st_uid != euid:
        sys.exit(f"Error: {orig_path} is owned by uid {st_l.st_uid}, not current user ({euid}).")
    if stat.S_ISLNK(st_l.st_mode):
        sys.exit(f"Error: {orig_path} is a symlink. Refusing to modify symlinked MCP configuration.")
path = os.path.realpath(orig_path)
data = {}
orig_mode = 0o600
orig_existed = os.path.exists(path)
if orig_existed:
    try:
        st_existing = os.lstat(path)
        if not stat.S_ISREG(st_existing.st_mode):
            sys.exit(f"Error: {path} is not a regular file.")
        if st_existing.st_nlink != 1:
            sys.exit(f"Error: {path} has multiple hardlinks (st_nlink={st_existing.st_nlink}).")
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
    """Checks whether a configuration value is empty or contains unexpanded template tokens so placeholder strings are ignored during config inspection, preventing literal template paths from being adopted as live database paths."""
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
    with open(path, "rb") as src_f:
        raw_orig = src_f.read()
    b_fd = os.open(bak_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        os.fchmod(b_fd, 0o600)
        os.write(b_fd, raw_orig)
        os.fsync(b_fd)
    finally:
        os.close(b_fd)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".mcp_config.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
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

if [ "${UNINSTALL}" -eq 1 ]; then
    DB_HINT=""
    if [ "${CLIENT_CONFIG}" -eq 1 ] && { [ -f "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ]; }; then
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
        DB_HINT="$(env -u AGENT_MEMORY_DB -u OPTANE_BASE -u ALLOW_NON_OPTANE "${PY}" -I "${BIN}" doctor 2>/dev/null | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin).get("db_path",""))' 2>/dev/null || true)"
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
    write_results_json "success" "uninstall completed" 0
    if [ "${JSON_OUT}" -eq 1 ]; then
        printf '{"status": "success", "uninstall": true, "dry_run": %s}\n' "$([ "${DRY_RUN}" -eq 1 ] && echo true || echo false)"
    fi
    exit 0
fi

if [ "${JSON_OUT}" -eq 0 ]; then
    echo "======================================================================"
    echo "Installing agent-memory v${VERSION} for user ${TARGET_USER}"
    echo "======================================================================"
fi
say "Python $("${PY}" -I -c 'import platform; print(platform.python_version())') (${PY})"
[ -f "${BUNDLE_BIN}" ] || die "bundle is incomplete: bin/agent-memory not found next to install.sh."
[ -f "${SCRIPT_DIR}/mcp/instructions.md" ] || die "bundle is incomplete: mcp/instructions.md not found next to install.sh."
[ -f "${SCRIPT_DIR}/skill/SKILL.md" ] || die "bundle is incomplete: skill/SKILL.md not found next to install.sh."
[ -f "${SCRIPT_DIR}/skill/references/agent-memory-mcp.md" ] || die "bundle is incomplete: skill/references/agent-memory-mcp.md not found next to install.sh."
for _schema in memory_record.json memory_search.json memory_recall.json memory_relate.json memory_forget.json; do
    [ -f "${SCRIPT_DIR}/mcp/${_schema}" ] || die "bundle is incomplete: mcp/${_schema} not found next to install.sh."
done

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
            if [ "${ALLOW_NON_OPTANE_FLAG:-0}" = "0" ] && [[ "${EXISTING_DB}" != /mnt/optane/* ]]; then
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
    write_results_json "error" "preflight failed" 1
    exit 1
fi
DB_PATH_RESOLVED="$(printf '%s' "${DOCTOR_OUT}" | "${PY}" -I -c 'import json,sys; print(json.load(sys.stdin).get("db_path", ""))' 2>/dev/null || true)"
[ -n "${DB_PATH_RESOLVED}" ] || die "preflight doctor did not return a valid db_path."
say "Preflight passed (database: ${DB_PATH_RESOLVED})"
[ "${ALLOW_NON_OPTANE_FLAG}" -eq 1 ] && warn "Non-Optane override is active (ALLOW_NON_OPTANE=1)."
RUN_ENV=("${ENV_BASE[@]}" "AGENT_MEMORY_DB=${DB_PATH_RESOLVED}")

DO_ANTIGRAVITY=0
if [ "${CLIENT_CONFIG}" -eq 1 ] && { [ -d "${GEMINI_DIR}" ] || [ -e "${MCP_CONFIG}" ] || [ -L "${MCP_CONFIG}" ] || [ -n "${AGENT_MEMORY_MCP_DIR:-}" ] || [ -n "${AGENT_MEMORY_SKILL_DIR:-}" ] || [ -n "${AGENT_MEMORY_MCP_CONFIG:-}" ] || command -v agy >/dev/null 2>&1; }; then
    DO_ANTIGRAVITY=1
    MCP_CHK_ERR="$(mcp_config_edit check "${MCP_CONFIG}" 2>&1)" || die "${MCP_CHK_ERR}"
fi

if [ "${DRY_RUN}" -eq 1 ]; then
    say "[dry-run] Preflight passed. Would initialize ${DB_PATH_RESOLVED} and install ${BIN}."
    write_results_json "success" "dry-run preflight passed" 0
    if [ "${JSON_OUT}" -eq 1 ]; then
        "${PY}" -I -c 'import json,sys; print(json.dumps({"status": "success", "dry_run": True, "db_path": sys.argv[1], "bin": sys.argv[2]}))' "${DB_PATH_RESOLVED}" "${BIN}"
    fi
    exit 0
fi

INIT_OUT="$("${RUN_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" init 2>&1)" || die "database init failed: ${INIT_OUT}"
say "${INIT_OUT}"
POST_DOCTOR_OUT="$("${RUN_ENV[@]}" "${PY}" -I "${BUNDLE_BIN}" doctor 2>&1)" || {
    printf '%s\n' "${POST_DOCTOR_OUT}" >&2
    die "post-init doctor check failed."
}

SELFTEST_OUT="$("${RUN_ENV[@]}" "${PY}" -I - "${PY}" "${BUNDLE_BIN}" "${DB_PATH_RESOLVED}" 2>&1 <<'PY'
"""Executes an isolated CLI and MCP stdio self-test against a temporary sibling database file so end-to-end record, search, forget, and JSON-RPC operations are verified before binary installation, preventing live production database mutation during installer self-tests."""
import json, os, subprocess, sys, uuid
py_exe, bin_path, live_db = sys.argv[1:4]
probe_db = os.path.join(os.path.dirname(live_db), f".selftest_{os.getpid()}_{uuid.uuid4().hex[:8]}.db")
cmd = [py_exe, "-I", bin_path]
env = dict(os.environ, AGENT_MEMORY_DB=probe_db)
def run(*a, inp=None):
    """Invokes the candidate agent-memory binary against the isolated self-test database and returns stdout on exit code 0 so CLI and MCP round-trips are verified, preventing broken binaries from being installed."""
    p = subprocess.run([*cmd, *a], capture_output=True, text=True, input=inp, env=env, timeout=60)
    if p.returncode != 0:
        sys.exit(f"Self-test failed: agent-memory {' '.join(a)}: {p.stdout}{p.stderr}")
    return p.stdout
try:
    run("init")
    tok = "installprobe" + uuid.uuid4().hex[:12]
    oid = json.loads(run("record", f"agent-memory install self-test {tok}", "--session", "install-selftest"))["observation_id"]
    hits = json.loads(run("search", tok))
    if not any(h.get("observation_id") == oid for h in hits):
        sys.exit(f"Self-test failed: probe not found by search: {hits}")
    if json.loads(run("forget", "--observation", oid)).get("deleted_observations") != 1:
        sys.exit("Self-test failed: probe could not be deleted")
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "installer", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "memory_search", "arguments": {"query": tok}}},
    ]
    out = run("--mcp", inp="\n".join(json.dumps(m) for m in msgs) + "\n")
    resp = {r["id"]: r for r in map(json.loads, out.splitlines()) if "id" in r}
    names = [t["name"] for t in resp[2]["result"]["tools"]]
    if "memory_record" not in names or "memory_forget" not in names:
        sys.exit(f"Self-test failed: unexpected MCP tools {names}")
    call = resp[3]["result"]
    if call.get("isError") or json.loads(call["content"][0]["text"]) != []:
        sys.exit(f"Self-test failed: MCP tool call: {call}")
    print(f"Self-test passed: record -> search -> forget round trip, MCP handshake and tool call ({len(names)} tools), with no data left behind")
finally:
    for ext in ("", "-wal", "-shm", "-journal"):
        p_ext = probe_db + ext
        if os.path.lexists(p_ext):
            try:
                os.unlink(p_ext)
            except OSError:
                pass
PY
)" || die "${SELFTEST_OUT}"
say "${SELFTEST_OUT}"

if [ ! -d "${BIN_DIR}" ]; then
    mkdir -p "${BIN_DIR}"
    chmod 755 "${BIN_DIR}" 2>/dev/null || true
fi
[ ! -L "${BIN_DIR}" ] || die "Refusing symlinked BIN_DIR: ${BIN_DIR}"
[ ! -L "${BIN}" ] || die "Refusing symlinked destination binary: ${BIN}"
TMP_BIN="$(mktemp "${BIN_DIR}/.agent-memory.XXXXXX")"
cp "${BUNDLE_BIN}" "${TMP_BIN}"
chmod 755 "${TMP_BIN}"
mv -f "${TMP_BIN}" "${BIN}"
TMP_BIN=""
"${RUN_ENV[@]}" "${PY}" -I "${BIN}" --version >/dev/null || die "installed binary does not run: ${BIN}"
say "Installed ${BIN}"

ENTRY_JSON="$("${PY}" -I - "${PY}" "${BIN}" "${ALLOW_NON_OPTANE_FLAG}" "${DB_PATH_RESOLVED}" <<'PY'
"""Serializes the MCP server registration JSON object for mcp_config.json so command, args, and environment variables are properly escaped, preventing malformed client configurations."""
import json, sys
py, b, allow, db = sys.argv[1:5]
print(json.dumps({"command": py, "args": ["-I", b, "--mcp"], "env": {"ALLOW_NON_OPTANE": allow, "AGENT_MEMORY_DB": db}}))
PY
)"
CLI_STR="$("${PY}" -I - "${ENTRY_JSON}" <<'PY'
"""Formats a shell-quoted CLI invocation string from the MCP registration entry so operator health-check hints are copy-paste safe, preventing shell word-splitting errors."""
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
    chmod 700 "${MCP_DIR}" 2>/dev/null || true
    install_file_atomic "${SCRIPT_DIR}/mcp/instructions.md" "${MCP_DIR}/instructions.md" 600
    say "Installed MCP instructions to ${MCP_DIR}"
    for _schema in memory_record.json memory_search.json memory_recall.json memory_relate.json memory_forget.json; do
        install_file_atomic "${SCRIPT_DIR}/mcp/${_schema}" "${MCP_DIR}/${_schema}" 600
    done
    say "Installed MCP tool schemas to ${MCP_DIR}"
    mkdir -p "${SKILL_DIR}/references"
    chmod 700 "${SKILL_DIR}" "${SKILL_DIR}/references" 2>/dev/null || true
    install_file_atomic "${SCRIPT_DIR}/skill/references/agent-memory-mcp.md" "${SKILL_DIR}/references/agent-memory-mcp.md" 600
    install_file_atomic "${SCRIPT_DIR}/skill/SKILL.md" "${SKILL_DIR}/SKILL.md" 600
    say "Installed skill files to ${SKILL_DIR}"
fi

write_results_json "success" "installation completed" 0

if [ "${JSON_OUT}" -eq 1 ]; then
    "${PY}" -I -c 'import json,sys; print(json.dumps({"status": "success", "dry_run": False, "db_path": sys.argv[1], "bin": sys.argv[2]}))' "${DB_PATH_RESOLVED}" "${BIN}"
else
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
fi
