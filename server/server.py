#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 HuaXu
"""之计同步服务端：账号、云端快照与情侣房间。"""
import base64
import hashlib
import json
import os
import re
import secrets
import smtplib
import socket
import ssl
import threading
import time
import uuid
import zlib
from email.header import Header
from email.mime.text import MIMEText
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_KEY = os.environ.get("GD_APP_KEY", "")
PORT = int(os.environ.get("GD_PORT", "8443"))
TLS_CTX = None  # main() 里加载证书后由 Handler.setup() 使用
DATA_DIR = Path(os.environ.get("GD_DATA_DIR", "/var/lib/goalday-sync"))
CERT_FILE = Path(os.environ.get("GD_CERT", "/opt/goalday-sync/certs/sync.crt"))
KEY_FILE = Path(os.environ.get("GD_KEY", "/opt/goalday-sync/certs/sync.key"))

SMTP_HOST = os.environ.get("GD_SMTP_HOST", "smtp.139.com")
SMTP_PORT = int(os.environ.get("GD_SMTP_PORT", "465"))
SMTP_USER = os.environ.get("GD_SMTP_USER", "")
SMTP_PASS = os.environ.get("GD_SMTP_PASS", "")

# 应用更新托管：APK 与 version.json 放在 APK_DIR 下。
APK_DIR = Path(os.environ.get("GD_APK_DIR", "/var/lib/goalday-sync/apk"))

# 联调开关：GD_DEBUG=1 时附带 devCode。
GD_DEBUG = os.environ.get("GD_DEBUG") == "1"

CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
CODE_LEN = 6
# X25519 协商公钥：base64(32 字节) = 44 字符，仅转发不解析。
PUB_KEY_RE = re.compile(r"^[A-Za-z0-9+/]{43}=$")


def _pub_key(p):
    v = p.get("pubKey")
    if isinstance(v, str) and PUB_KEY_RE.match(v):
        return v
    return None


def _identity_pair(p):
    """解析可选的长期身份公钥+签名；任一缺失/长度不对都整体忽略（不报错）。"""
    ip = p.get("identityPub")
    sig = p.get("pubKeySig")
    if not isinstance(ip, str) or not isinstance(sig, str) or not ip or not sig:
        return None
    try:
        if len(base64.b64decode(ip, validate=True)) != 32:
            return None
        if len(base64.b64decode(sig, validate=True)) != 64:
            return None
    except Exception:
        return None
    return {"identityPub": ip, "sig": sig}


def _store_room_identity(room, aid, ident):
    """存账号长期身份公钥+签名；已相同不写，返回是否变化。"""
    if not ident:
        return False
    pis = room.setdefault("pubIdentities", {})
    if pis.get(aid) == ident:
        return False
    pis[aid] = ident
    return True
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
# 客户端数据量大了以后走 gzip 通道：解压后允许更大，但必须有硬上限防解压炸弹。
MAX_SNAPSHOT_GZ_BYTES = 4 * 1024 * 1024
# 每个账号最多保留几台设备的备份槽。槽位满时按 updatedAt 挤掉最旧的槽
# （不再拒绝新设备），避免用任意 device 名把内存和磁盘写放大打爆。
MAX_DEVICE_SLOTS = 8
# 同一账号最多同时保留几个登录会话（手机+电脑+备用机足够）。
MAX_SESSIONS_PER_ACCOUNT = 8
# 降级安装防护：账号云上已有加密备份时，只接受版本 >= 此值的客户端 push。
# v5.15.2 起未配对账号的 shared 用 shared_key='own' 加密，旧版读不懂，
# restore 会拿到空数据并把备份覆盖成空/明文，因此必须在写入前拦住旧版。
MIN_PUSH_VER = os.environ.get("GD_MIN_PUSH_VER", "5.15.2")

# 扫描/爆破防护：同一 IP 10 分钟内 4xx 超过阈值，临时拒绝一段时间。
_bad_ip_state = {}
BAD_IP_WINDOW_MS = 10 * 60 * 1000
BAD_IP_LIMIT = 120
BAD_IP_BAN_MS = 15 * 60 * 1000
MAX_COMMENTS = 1200
MAX_MESSAGES = 2000
# 单房间历史总字节上限：条数够多但每条很大时，从最旧开始丢，避免内存爆掉。
# 开源部署可按机器内存用 GD_ROOM_MESSAGE_BYTES / GD_ROOM_COMMENT_BYTES 调整。
MAX_ROOM_MESSAGE_BYTES = int(os.environ.get(
    "GD_ROOM_MESSAGE_BYTES", str(24 * 1024 * 1024)))
MAX_ROOM_COMMENT_BYTES = int(os.environ.get(
    "GD_ROOM_COMMENT_BYTES", str(12 * 1024 * 1024)))
MAX_TEXT = 500
# 密文比明文长：base64(12B nonce + 密文 + 16B tag)。校验按密文长度给足余量，
# 否则中文长消息会在加密后超限，或被截断成解不开的废密文。
MAX_ENC_TEXT = 8000
# 留言正文在客户端加密后上传（base64 后约为明文 4/3 再加 38 字符），
# 沿用 MAX_TEXT 会把长留言截断成无法解密的密文，因此单独放宽。
MAX_MSG_TEXT = 1200
# 单次 sync 响应体积预算：超出时只裁剪本次返回的消息/评价/设备槽，
# 不删除服务端数据。按十进制 6MB 收口（客户端上限远大于此）。
MAX_RESPONSE_BYTES = 6_000_000
_RESPONSE_SAFETY_BYTES = 128 * 1024
MAX_JOIN_ATTEMPTS = 20
JOIN_WINDOW_MS = 10 * 60 * 1000
MAX_AUTH_ATTEMPTS = 10
AUTH_WINDOW_MS = 10 * 60 * 1000
ROOM_TTL_MS = 365 * 24 * 3600 * 1000
# 每 IP 速率上限：双端 5 秒轮询常态约 24 次/分，上限留足余量。
SYNC_CAP = 90
# 每分钟每 IP 的发送上限。自建服务可以按需要调（例如内网压测）。
MSG_CAP = int(os.environ.get("GD_MSG_CAP", "30"))
COMMENT_CAP = int(os.environ.get("GD_COMMENT_CAP", "30"))
EVENT_CAP = 30
UPDATE_CAP = 12
MINUTE_MS = 60 * 1000

_lock = threading.RLock()

# 数据目录独占锁：两个实例共用一个目录会互相覆盖 json，宁可起不来。
_instance_lock_fd = None


def acquire_instance_lock():
    """拿不到锁就退出。systemd 重启时旧进程先退出，锁随之释放。"""
    global _instance_lock_fd
    try:
        import fcntl
    except ImportError:  # 非 POSIX 平台（本机调试用）直接跳过
        return
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    path = DATA_DIR / ".instance.lock"
    fd = open(path, "w", encoding="utf-8")
    try:
        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("另一个实例正在使用这个数据目录，退出：", DATA_DIR, flush=True)
        raise SystemExit(1)
    fd.write(str(os.getpid()))
    fd.flush()
    _instance_lock_fd = fd
# 长轮询：每房间一个条件变量（复用全局 _lock），房间数据变更后统一唤醒。
_room_conds = {}
_room_waiters = 0
MAX_ROOM_WAITERS = 24
LONGPOLL_MAX_S = 25


def _room_cond(rid):
    cond = _room_conds.get(rid)
    if cond is None:
        cond = _room_conds[rid] = threading.Condition(_lock)
    return cond


def _notify_room_change(rid=None):
    """房间数据变更后唤醒所有长轮询（rid=None 广播，量级小无所谓）。"""
    if rid is not None:
        cond = _room_conds.get(rid)
        if cond is not None:
            cond.notify_all()
            return
    for cond in _room_conds.values():
        cond.notify_all()


_accounts = {}   # username_lower -> account record
_tokens = {}     # token -> accountId
_token_devices = {}  # token -> 最近一次 sync/listDevices 上报的设备 id（当前设备判定用）
_rooms = {}      # room_id -> room
# 绑定码与验证码共用一张表；邮箱含 @，不与 6 位码冲突。
_codes = {}
_email_daily = {}  # email -> [ts] 每邮箱每日发送上限
_code_log = {}   # email -> [ts] 重发冷却
_snapshots = {}  # accountId -> {"devices": {...}, "updatedAt": int}
_join_log = {}
_auth_log = {}
_sync_log = {}   # 以下均为 ip -> [ts]
_msg_log = {}
_comment_log = {}
_event_log = {}
_update_log = {}


def now_ms():
    return int(time.time() * 1000)


def _hash(salt: str, password: str) -> str:
    """旧记录的 SHA-256 口令校验。"""
    return hashlib.sha256((salt + password).encode("utf-8")).hexdigest()


PBKDF2_ITERS = 210_000


def pbkdf2_hex(password: str, salt_hex: str, iters: int) -> str:
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), iters
    )
    return dk.hex()


def _hash_password(password: str, salt_hex: str) -> str:
    return f"pbkdf2${PBKDF2_ITERS}${salt_hex}${pbkdf2_hex(password, salt_hex, PBKDF2_ITERS)}"


def _verify_password(rec, password: str) -> bool:
    stored = rec.get("passHash", "")
    if stored.startswith("pbkdf2$"):
        try:
            _, iters, salt_hex, hash_hex = stored.split("$")
            dk = pbkdf2_hex(password, salt_hex, int(iters))
            return secrets.compare_digest(dk, hash_hex)
        except Exception:
            return False
    return _hash(rec.get("salt", ""), password) == stored


def _prehash_register(payload):
    """register 的盐在注册时才生成，散列参数一并在此备好，
    让 PBKDF2 不占用全局锁。"""
    password = str(payload.get("password", ""))
    salt = secrets.token_hex(8)
    payload["_prepared"] = (salt, _hash_password(password, salt))


def _prehash_login(payload):
    """按存量口令的参数先算好候选散列；未知邮箱跑等价散列抹平时差。"""
    email = str(payload.get("username", "")).strip().lower()
    password = str(payload.get("password", ""))
    with _lock:
        stored = (_accounts.get(email) or {}).get("passHash", "")
    salt_hex, iters = "00" * 16, PBKDF2_ITERS
    if stored.startswith("pbkdf2$"):
        try:
            _, s_iters, s_salt, _ = stored.split("$")
            salt_hex, iters = s_salt, int(s_iters)
        except (ValueError, IndexError):
            pass
    payload["_prepared"] = (salt_hex, iters, pbkdf2_hex(password, salt_hex, iters))


def _verify_prehashed(rec, dk_hex: str, salt_hex: str, iters: int):
    """锁外算好的散列与存量口令比对；参数已变（如刚 rehash）返回 None。"""
    stored = rec.get("passHash", "")
    if stored.startswith("pbkdf2$"):
        try:
            _, s_iters, s_salt, s_hash = stored.split("$")
            if int(s_iters) == iters and s_salt == salt_hex:
                return secrets.compare_digest(dk_hex, s_hash)
        except (ValueError, IndexError):
            pass
    return None


PREHASH = {
    "login": _prehash_login,
    "register": _prehash_register,
}


def _needs_rehash(rec) -> bool:
    return not rec.get("passHash", "").startswith("pbkdf2$")


def _account_tokens(rec):
    """账号当前有效的全部 token（多设备同时在线）。"""
    out = []
    tokens = rec.get("tokens")
    if isinstance(tokens, list):
        out.extend(t for t in tokens if isinstance(t, str) and t)
    legacy = rec.get("token")
    if isinstance(legacy, str) and legacy and legacy not in out:
        out.append(legacy)
    return out


def _add_token(rec, token):
    """登录发新 token，保留其它设备已登录的会话。"""
    tokens = [t for t in _account_tokens(rec) if t != token]
    tokens.insert(0, token)
    # 上限防止长期不登出的设备无限堆积。
    rec["tokens"] = tokens[:MAX_SESSIONS_PER_ACCOUNT]
    rec["token"] = token
    td = rec.get("tokenDevices")
    for stale in tokens[MAX_SESSIONS_PER_ACCOUNT:]:
        _tokens.pop(stale, None)
        _token_devices.pop(stale, None)
        if isinstance(td, dict):
            td.pop(stale, None)


def _find_account_by_aid(aid):
    for rec in _accounts.values():
        if rec.get("accountId") == aid:
            return rec
    return None


def _remember_token_device(aid, token, device):
    """记录 token 当前设备，并持久化到 accounts.json 的 tokenDevices。"""
    if not token or not device:
        return
    device = str(device)[:64]
    if _token_devices.get(token) == device:
        return
    _token_devices[token] = device
    rec = _find_account_by_aid(aid)
    if rec is None:
        return
    td = rec.get("tokenDevices")
    if not isinstance(td, dict):
        td = {}
        rec["tokenDevices"] = td
    td[token] = device
    save_accounts()


def _restore_token_devices(rec):
    td = rec.get("tokenDevices")
    if not isinstance(td, dict):
        return
    for tk, dev in td.items():
        if isinstance(tk, str) and isinstance(dev, str) and tk in _tokens:
            _token_devices[tk] = dev[:64]


def load_state():
    _token_devices.clear()
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    (DATA_DIR / "data").mkdir(exist_ok=True)
    acc_file = DATA_DIR / "accounts.json"
    if not acc_file.exists():
        # 崩溃可能留下只有 .bak/.tmp 的现场：先从 .bak 起步，避免空库启动。
        bak = acc_file.with_suffix(".json.bak")
        if bak.exists():
            try:
                bak.replace(acc_file)
                print("accounts main file missing, restored from .bak", flush=True)
            except Exception as exc:
                print("accounts .bak promote failed:", exc, flush=True)
    if acc_file.exists():
        try:
            raw = json.loads(acc_file.read_text(encoding="utf-8"))
            for name, rec in raw.items():
                try:
                    if not isinstance(rec, dict) or not rec.get("accountId"):
                        raise ValueError("bad record")
                    _accounts[name] = rec
                    # 空 token 不入表；多设备会话存在 tokens 数组里，
                    # 早期单 token 版本兼容读取。
                    for tk in _account_tokens(rec):
                        _tokens[tk] = rec["accountId"]
                except Exception as record_exc:
                    print("account record skipped:", name, record_exc, flush=True)
        except Exception as exc:
            stamp = now_ms()
            acc_file.rename(acc_file.with_suffix(f".corrupt-{stamp}"))
            bak = acc_file.with_suffix(".json.bak")
            restored = False
            if bak.exists():
                try:
                    raw = json.loads(bak.read_text(encoding="utf-8"))
                    for name, rec in raw.items():
                        # 与主文件一致：逐条校验，坏记录跳过不整体放弃。
                        if not isinstance(rec, dict) or not rec.get("accountId"):
                            continue
                        _accounts[name] = rec
                        for tk in _account_tokens(rec):
                            _tokens[tk] = rec["accountId"]
                    restored = True
                    print("accounts restored from .bak", flush=True)
                except Exception as bak_exc:
                    print("accounts .bak restore failed:", bak_exc, flush=True)
            if not restored:
                print("accounts load failed:", exc, flush=True)
    # rooms.json / 快照与 accounts 同样面临「rotate 备份与主文件替换之间崩溃」
    # 的现场：主文件缺失时从 .bak 提升，损坏时隔离后回退 .bak，避免静默清空。
    room_file = DATA_DIR / "rooms.json"
    room_bak = room_file.with_suffix(".json.bak")
    if not room_file.exists() and room_bak.exists():
        try:
            room_bak.replace(room_file)
            print("rooms main file missing, restored from .bak", flush=True)
        except Exception as exc:
            print("rooms .bak promote failed:", exc, flush=True)
    if room_file.exists():
        try:
            for r in json.loads(room_file.read_text(encoding="utf-8")):
                try:
                    _rooms[r["roomId"]] = r
                    if len(r.get("members", [])) < 2:
                        for code in r.get("codes", {}).values():
                            _codes[code] = r["roomId"]
                except Exception as exc:
                    print("room record skipped:", exc, flush=True)
        except Exception as exc:
            stamp = now_ms()
            room_file.rename(room_file.with_suffix(f".corrupt-{stamp}"))
            restored = False
            if room_bak.exists():
                try:
                    for r in json.loads(room_bak.read_text(encoding="utf-8")):
                        _rooms[r["roomId"]] = r
                        if len(r.get("members", [])) < 2:
                            for code in r.get("codes", {}).values():
                                _codes[code] = r["roomId"]
                    restored = True
                    print("rooms restored from .bak", flush=True)
                except Exception as bak_exc:
                    print("rooms .bak restore failed:", bak_exc, flush=True)
            if not restored:
                print("rooms load failed, quarantined:", exc, flush=True)
    snap_dir = DATA_DIR / "data"
    for f in snap_dir.glob("*.json"):
        if f.name.endswith(".bak"):
            continue
        try:
            _snapshots[f.stem] = json.loads(f.read_text(encoding="utf-8"))
        except Exception as exc:
            stamp = now_ms()
            f.rename(f.with_suffix(f".json.corrupt-{stamp}"))
            bak = f.with_suffix(f".json.bak")
            if bak.exists():
                try:
                    _snapshots[f.stem] = json.loads(bak.read_text(encoding="utf-8"))
                    print("snapshot restored from .bak:", f.stem, flush=True)
                except Exception as bak_exc:
                    print("snapshot load failed:", f.stem, exc, bak_exc, flush=True)
            else:
                print("snapshot load failed:", f.stem, exc, flush=True)
    for rec in _accounts.values():
        _restore_token_devices(rec)


def _rotate_bak(target):
    """单代备份：写入前保留上一份，损坏时可用于人工恢复。"""
    try:
        if target.exists():
            target.replace(target.with_suffix(target.suffix + ".bak"))
    except Exception as exc:
        print("bak rotate failed:", target.name, exc, flush=True)


def _write_atomic(target, payload):
    """写临时文件、刷盘、再替换；断电时最多丢这一次写入，不会留半截 JSON。"""
    tmp = target.with_suffix(target.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fp:
        fp.write(payload)
        fp.flush()
        os.fsync(fp.fileno())
    _rotate_bak(target)
    tmp.replace(target)


def save_accounts():
    _write_atomic(DATA_DIR / "accounts.json",
                  json.dumps(_accounts, ensure_ascii=False))


def save_rooms():
    _write_atomic(DATA_DIR / "rooms.json",
                  json.dumps(list(_rooms.values()), ensure_ascii=False))


def save_snapshot(aid):
    f = DATA_DIR / "data" / f"{aid}.json"
    _write_atomic(f, json.dumps(_snapshots.get(aid, {}), ensure_ascii=False))


SWEEP_INTERVAL_S = 30
_last_sweep_mono = 0.0


def maybe_sweep():
    """房间 TTL 巡检按节流执行，避免每个请求都全量扫描。

    返回 True 表示本次真的删除了房间（需要落盘 rooms.json 并唤醒等待者）。
    """
    global _last_sweep_mono
    now = time.monotonic()
    if now - _last_sweep_mono < SWEEP_INTERVAL_S:
        return False
    _last_sweep_mono = now
    return sweep_expired()


def sweep_expired():
    cutoff = now_ms() - ROOM_TTL_MS
    stale = [rid for rid, r in _rooms.items() if r.get("updatedAt", 0) < cutoff]
    for rid in stale:
        drop_room(rid)
    # 限流日志封顶：超阈值时清掉一小时无活动的键。
    # _email_daily 不参与：它是 24h 每邮箱配额，被清会重置每日上限。
    now = now_ms()
    rate_logs = (_code_log, _auth_log, _join_log,
                 _sync_log, _msg_log, _comment_log, _event_log, _update_log)
    for log in rate_logs:
        if len(log) <= 4096:
            continue
        for k in [k for k, v in log.items()
                  if not any(t > now - 3600 * 1000 for t in v)]:
            log.pop(k, None)
    return bool(stale)


def drop_room(rid):
    room = _rooms.pop(rid, None)
    # 条件变量要跟着房间一起回收，否则解绑/过期后只增不减。
    cond = _room_conds.pop(rid, None)
    if cond is not None:
        cond.notify_all()
    if room:
        for code in room.get("codes", {}):
            _codes.pop(code, None)


def _trim_room_history(room, key, max_items, max_bytes):
    """按条数/总字节从最旧开始裁剪房间历史（写入时调用）。"""
    seq = room.get(key)
    if not isinstance(seq, list):
        return

    def _bytes(item):
        if not isinstance(item, dict):
            return 0
        return len(str(item.get("text") or "").encode("utf-8"))

    total = sum(_bytes(item) for item in seq)
    changed = False
    while seq and (len(seq) > max_items or total > max_bytes):
        total -= _bytes(seq.pop(0))
        changed = True
    return changed


def gen_code():
    while True:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
        if code not in _codes:
            return code


def room_of_account(aid):
    for r in _rooms.values():
        if aid in r["members"]:
            return r
    return None


def detach_account(aid):
    room = room_of_account(aid)
    if not room:
        return
    if aid in room.get("codes", {}):
        _codes.pop(room["codes"].pop(aid), None)
    room["members"].remove(aid)
    room.get("snapshots", {}).pop(aid, None)
    room.get("memberInfo", {}).pop(aid, None)
    room.get("pubKeys", {}).pop(aid, None)
    room.get("pubIdentities", {}).pop(aid, None)
    if len(room["members"]) < 2:
        drop_room(room["roomId"])
    else:
        room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1


def limited(log, ip, cap, window):
    now = now_ms()
    entries = [t for t in log.get(ip, []) if now - t < window]
    entries.append(now)
    log[ip] = entries[-200:]
    return len(entries) > cap


class ApiError(Exception):
    """业务错误：消息会原样下发给客户端。"""


def auth_account(payload):
    token = str(payload.get("token", ""))
    aid = _tokens.get(token)
    if not aid or len(token) < 32:
        raise ApiError("登录已失效，请重新登录")
    return aid


# ---------- auth ----------

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

CODE_TTL_MS = 10 * 60 * 1000
CODE_RESEND_COOLDOWN_MS = 60 * 1000
MAX_CODE_PER_IP = 10
CODE_IP_WINDOW_MS = 3600 * 1000


def send_code_email(to: str, code: str):
    # 英文主题并补全 Message-ID/Date，降低拒收率。
    from email.message import EmailMessage
    from email.utils import formatdate, make_msgid

    m = EmailMessage()
    m["From"] = "ZhiJi <%s>" % SMTP_USER
    m["To"] = to
    m["Subject"] = "ZhiJi login code: %s" % code
    m["Date"] = formatdate(localtime=True)
    m["Message-ID"] = make_msgid(domain=SMTP_HOST.split(".", 1)[-1])
    m.set_content(
        "Hi,\n\n"
        "Your ZhiJi verification code is %s.\n"
        "It expires in 10 minutes.\n\n"
        "If you did not request this, ignore this mail.\n" % code
    )
    if SMTP_PORT == 465:
        server = smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=20)
    else:
        server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20)
        server.starttls()
    try:
        server.login(SMTP_USER, SMTP_PASS)
        server.sendmail(SMTP_USER, [to], m.as_string())
    finally:
        server.quit()


def api_request_code(p, ip):
    """生成注册验证码；发送由 do_POST 在锁外完成。"""
    if limited(_code_log, ip, MAX_CODE_PER_IP, CODE_IP_WINDOW_MS):
        raise ApiError("请求过于频繁，请稍后再试")
    email = str(p.get("username", "")).strip().lower()
    if not EMAIL_RE.fullmatch(email):
        raise ApiError("邮箱格式不对")
    sent_today = [t for t in _email_daily.get(email, []) if t > now_ms() - 24 * 3600 * 1000]
    if len(sent_today) >= 10:
        raise ApiError("该邮箱今日发送次数已达上限，请明天再试")
    now = now_ms()
    prev = _codes.get(email)
    if prev and now - prev["sentAt"] < CODE_RESEND_COOLDOWN_MS:
        # 冷却判断在扣额前。
        raise ApiError("发送太频繁，请 1 分钟后再试")
    sent_today.append(now_ms())
    _email_daily[email] = sent_today
    code = f"{secrets.randbelow(1000000):06d}"
    _codes[email] = {
        "code": code,
        "expiresAt": now + CODE_TTL_MS,
        "sentAt": now,
    }
    # devCode 仅供联调。
    result = {"email": email, "code": code, "cooldown": 60}
    if GD_DEBUG:
        result["devCode"] = code
        print(f"[DEBUG] devCode {email}: {code}", flush=True)
    return result


def api_register(p, ip):
    # 限流在 do_POST 里、PBKDF2 之前统一做（见 Handler.do_POST）。
    email = str(p.get("username", "")).strip().lower()
    password = str(p.get("password", ""))
    if not EMAIL_RE.fullmatch(email):
        raise ApiError("邮箱格式不对")
    if len(password) < 6:
        raise ApiError("密码至少 6 位")
    if len(password) > 1024:
        raise ApiError("密码过长")
    code = str(p.get("code", "")).strip()
    rec = _codes.get(email)
    if not rec or rec["expiresAt"] < now_ms() or not secrets.compare_digest(rec["code"], code):
        raise ApiError("验证码不对或已过期")
    _codes.pop(email, None)
    if email in _accounts:
        raise ApiError("该邮箱已注册过，直接登录吧")
    salt = secrets.token_hex(8)
    aid = uuid.uuid4().hex
    token = secrets.token_hex(24)
    display = str(p.get("name", "")).strip()[:20] or email.split("@")[0]
    prepared = p.get("_prepared")  # 锁外已算好的 (salt, passHash)
    if prepared is None:
        prepared = (salt, _hash_password(password, salt))
    _accounts[email] = {
        "username": email,
        "name": display,
        "accountId": aid,
        "salt": prepared[0],
        "passHash": prepared[1],
        "token": token,
        "createdAt": now_ms(),
    }
    _tokens[token] = aid
    save_accounts()
    return {"token": token, "accountId": aid, "username": email, "name": display}


def api_login(p, ip):
    # 限流在 do_POST 里、PBKDF2 之前统一做（见 Handler.do_POST）。
    email = str(p.get("username", "")).strip().lower()
    password = str(p.get("password", ""))
    if len(password) > 1024 or len(email) > 254:
        raise ApiError("参数错误")
    device = str(p.get("device") or "")[:64]
    rec = _accounts.get(email)
    prepared = p.get("_prepared")  # (salt, iters, dk_hex) 锁外已算
    if rec is None:
        if prepared is None:
            pbkdf2_hex(password, "00" * 16, PBKDF2_ITERS)
        raise ApiError("邮箱或密码不对")
    # 常规路径用锁外散列比对；返回 None（参数已变，如刚 rehash）才锁内重算。
    r = _verify_prehashed(rec, prepared[2], prepared[0], prepared[1]) \
        if prepared is not None else None
    ok = _verify_password(rec, password) if r is None else r
    if not ok:
        raise ApiError("邮箱或密码不对")
    if _needs_rehash(rec):
        # SHA-256 账号登录成功后升级为 PBKDF2。
        rec["passHash"] = _hash_password(password, rec["salt"])
    # 多设备同时在线：新登录只增发 token，不踢掉其它设备。
    token = secrets.token_hex(24)
    _tokens[token] = rec["accountId"]
    _add_token(rec, token)
    # 登录就带 device（新客户端）：立刻建立 tokenDevices，设备管理页无空档。
    if device:
        _remember_token_device(rec["accountId"], token, device)
    save_accounts()
    return {
        "token": token,
        "accountId": rec["accountId"],
        "username": email,
        "name": rec.get("name", email.split("@")[0]),
        "avatar": rec.get("avatar", ""),
    }


def api_profile(p, ip):
    aid = auth_account(p)
    rec = next((r for r in _accounts.values() if r["accountId"] == aid), None)
    if rec is None:
        raise ApiError("账号不存在")

    name = str(p.get("name", "")).strip()[:20]
    avatar = str(p.get("avatar", ""))
    if avatar:
        if len(avatar) > 120 * 1024:
            raise ApiError("头像太大，请换一张小图")
        if not avatar.startswith("data:image/"):
            raise ApiError("头像格式不对")
        import base64 as _b64
        try:
            head = _b64.b64decode(avatar.split(",", 1)[1][:16])
        except Exception:
            raise ApiError("头像格式不对")
        if not (head.startswith(bytes([137]) + b"PNG") or head.startswith(bytes([255, 216, 255]))):
            raise ApiError("仅支持 PNG/JPG 图片")
    if name:
        rec["name"] = name
    if avatar:
        rec["avatar"] = avatar
    save_accounts()

    room = room_of_account(aid)
    room_mutated = False
    if room:
        info = room.setdefault("memberInfo", {}).setdefault(aid, {})
        if name:
            info["name"] = name
        if avatar:
            info["avatar"] = avatar
        room["updatedAt"] = now_ms()
        room["rev"] = room.get("rev", 0) + 1
        room_mutated = True

    out = {
        "name": rec.get("name", ""),
        "avatar": rec.get("avatar", ""),
        "email": rec["username"],
    }
    if room_mutated:
        out["_mutated"] = True
    return out


# ---------- account data sync ----------

def _slot_devices(aid):
    """账号的设备分槽视图：兼容旧的单快照格式（视为 legacy 槽）。"""
    rec = _snapshots.get(aid) or {}
    devices = rec.get("devices")
    if devices is None:
        devices = {}
        if rec.get("data") is not None:
            devices["legacy"] = {"data": rec["data"],
                                 "updatedAt": rec.get("updatedAt", 0)}
    return devices


def ip_banned(ip):
    v = _bad_ip_state.get(ip)
    return bool(v and v.get("banUntil", 0) > now_ms())


def note_bad_request(ip):
    """统计公网 4xx；阈值较高，正常用户不会因为偶发失败被封。"""
    if not ip or ip.startswith("127.") or ip in ("::1", "localhost"):
        return
    now = now_ms()
    v = _bad_ip_state.get(ip)
    if not v or now - v.get("t", 0) > BAD_IP_WINDOW_MS:
        v = {"n": 0, "t": now, "banUntil": 0}
    v["n"] += 1
    if v["n"] >= BAD_IP_LIMIT and v.get("banUntil", 0) <= now:
        v["banUntil"] = now + BAD_IP_BAN_MS
        print("bad ip banned:", ip, flush=True)
    _bad_ip_state[ip] = v
    if len(_bad_ip_state) > 20000:
        cutoff = now - BAD_IP_WINDOW_MS
        for k in [k for k, s in _bad_ip_state.items()
                  if s.get("t", 0) < cutoff and s.get("banUntil", 0) < now]:
            _bad_ip_state.pop(k, None)


def _decode_snapshot(p):
    """解析快照：优先 gzip 通道（解压后按更大上限校验），兼容旧明文 payload。"""
    gz = p.get("snapshotGz")
    if isinstance(gz, str) and gz:
        try:
            raw = base64.b64decode(gz, validate=True)
        except Exception:
            raise ApiError("同步数据格式错误")
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            body = d.decompress(raw, MAX_SNAPSHOT_GZ_BYTES + 1)
            if len(body) > MAX_SNAPSHOT_GZ_BYTES or d.unconsumed_tail:
                raise ApiError("内容过大，同步失败")
            body += d.flush()
        except ApiError:
            raise
        except Exception:
            raise ApiError("同步数据格式错误")
        if len(body) > MAX_SNAPSHOT_GZ_BYTES:
            raise ApiError("内容过大，同步失败")
        try:
            return json.loads(body.decode("utf-8"))
        except Exception:
            raise ApiError("同步数据格式错误")
    snapshot = p.get("snapshot")
    if snapshot is None:
        return None
    raw = json.dumps(snapshot, ensure_ascii=False)
    if len(raw.encode("utf-8")) > MAX_SNAPSHOT_BYTES:
        raise ApiError("内容过大，同步失败")
    return snapshot


def _ver_tuple(v):
    """解析版本前缀：'5.15.10+107' / '5.15.2' -> 数字元组；无法解析 -> (0,)。"""
    m = re.match(r"\s*(\d+(?:\.\d+)*)", str(v or ""))
    if not m:
        return (0,)
    return tuple(int(x) for x in m.group(1).split("."))


def _version_lt(a, b):
    """语义化比较（逐段整数、忽略 +build 后缀），a < b 为 True。"""
    ta, tb = _ver_tuple(a), _ver_tuple(b)
    n = max(len(ta), len(tb))
    return ta + (0,) * (n - len(ta)) < tb + (0,) * (n - len(tb))


def _snapshot_needs_new_client(data):
    """旧版客户端读不懂、也不该被其覆盖的加密快照（v2 加密包）。"""
    if not isinstance(data, dict) or data.get("v") != 2:
        return False
    if data.get("shared_key") == "own":
        return True
    priv = data.get("priv")
    journal = priv.get("journal") if isinstance(priv, dict) else None
    encrypted = (isinstance(journal, dict)
                 and isinstance(journal.get("_encrypted"), str)
                 and bool(journal.get("_encrypted")))
    return bool(data.get("shared_enc") is True and encrypted)


def _snapshot_is_encrypted(data):
    """本次 push 上来的 shared 是否仍是密文（v2 + shared_enc + shared 为密文字符串）。"""
    return (isinstance(data, dict) and data.get("v") == 2
            and data.get("shared_enc") is True
            and isinstance(data.get("shared"), str)
            and bool(data.get("shared")))


def api_sync(p, ip):
    global _room_waiters
    if limited(_sync_log, ip, SYNC_CAP, MINUTE_MS):
        raise ApiError("请求过于频繁，请稍后再试")
    aid = auth_account(p)
    name = str(p.get("name", ""))[:20]
    snapshot = _decode_snapshot(p)
    # 快照必须是 dict：客户端会 as Map 强转，非 dict 落库会让该账号永久
    # 同步失败。服务端信封里的 data（伴侣视图）若存在也必须是 dict。
    if snapshot is not None:
        if not isinstance(snapshot, dict):
            raise ApiError("参数错误")
        if "data" in snapshot and not isinstance(snapshot["data"], dict):
            raise ApiError("参数错误")
    device = str(p.get("device", ""))[:64] or "legacy"
    _remember_token_device(aid, str(p.get("token", "")), device)
    # 设备槽显示名：sync 请求本就有 name（账号显示名），首次落槽用；
    # 之后用户用 renameDevice 改过的名字带 customName 标记，不再被 sync 覆盖。
    sync_name = str(p.get("name", "")).strip()[:40]
    # 历史分页：主用 (olderBeforeAt, olderBeforeId) 复合游标；
    # 兼容旧客户端只传 olderBefore（等价于 at=olderBefore, id=""）。
    want_older = p.get("wantOlder") is True
    older_at = None
    older_id = ""
    if want_older:
        has_at = "olderBeforeAt" in p
        has_id = "olderBeforeId" in p
        if has_at or has_id:
            at = p.get("olderBeforeAt")
            oid = p.get("olderBeforeId")
            if (isinstance(at, bool) or not isinstance(at, int) or at <= 0
                    or not isinstance(oid, str) or not oid):
                raise ApiError("参数错误")
            older_at, older_id = at, oid
        else:
            ob = p.get("olderBefore")
            if isinstance(ob, bool) or not isinstance(ob, int) or ob <= 0:
                raise ApiError("参数错误")
            older_at, older_id = ob, ""
    evicted_device = None
    # 降级安装防护：账号云上已有加密备份时，只拦"会把备份写坏"的 push：
    #  1) 带 ver 且 < MIN_PUSH_VER：一律拒绝（本版起的新客户端都会带 ver）。
    #  2) 不带 ver（存量 5.15.2/5.15.3 客户端）：它们 push 的仍是加密快照，
    #     放行；只有 push 的是不加密快照（v!=2 / shared_enc!=true / shared 非
    #     密文字符串）时才拒绝——这正是 ≤5.15.1 未配对用户把加密备份写成
    #     明文空数据那条危险路径。
    # pull（snapshot is None）始终不受影响。
    if snapshot is not None:
        slots = _slot_devices(aid)
        if any(_snapshot_needs_new_client(v.get("data")) for v in slots.values()):
            client_ver = p.get("ver")
            if client_ver is None or client_ver == "":
                if not _snapshot_is_encrypted(snapshot):
                    raise ApiError(
                        "当前版本太旧，可能会覆盖已加密的云端备份，请先升级客户端")
            elif _version_lt(client_ver, MIN_PUSH_VER):
                raise ApiError(
                    "当前版本太旧，可能会覆盖已加密的云端备份，请先升级客户端")
    pushed = False
    if snapshot is not None:
        raw = json.dumps(snapshot, ensure_ascii=False)
        devices = _slot_devices(aid)
        prev = devices.get(device) or {}
        # 内容未变的推送不落盘、不推进房间版本号。
        prev_raw = (json.dumps(prev["data"], ensure_ascii=False)
                    if prev.get("data") is not None else None)
        if raw != prev_raw:
            # 设备槽上限：防止一个账号用任意 device 名撑爆内存与磁盘。
            # 已存在的槽位直接更新；新增槽位满时按 updatedAt 挤掉最旧的槽。
            if device not in devices and len(devices) >= MAX_DEVICE_SLOTS:
                # 槽位满时不拒绝新设备：按 updatedAt 挤掉最旧的槽腾位。
                # 旧设备下次同步会发现自己的槽已不在，客户端可据此提示。
                oldest = min(devices.items(),
                             key=lambda kv: (kv[1].get("updatedAt", 0), kv[0]))
                evicted_device = oldest[0]
                devices.pop(evicted_device, None)
            slot_updated = max((d.get("updatedAt", 0)
                                for d in devices.values()), default=0)
            slot = devices.get(device)
            if not isinstance(slot, dict):
                slot = {}
            slot["data"] = snapshot
            slot["updatedAt"] = max(now_ms(), slot_updated + 1)
            if sync_name and not slot.get("customName"):
                slot["name"] = sync_name
            devices[device] = slot
            _snapshots[aid] = {"devices": devices,
                               "updatedAt": max(now_ms(), slot_updated + 1)}
            save_snapshot(aid)
            pushed = True

    devices = _slot_devices(aid)
    mine = devices.get(device) or {}
    if not mine.get("data"):
        # 本设备槽位还没有数据（新设备/重装）：回落到该账号最近更新的
        # 槽位，让「从云端恢复」在跨设备场景下仍能拿到备份。
        for d, v in devices.items():
            if v.get("data") and v.get("updatedAt", 0) >= mine.get("updatedAt", 0):
                mine = v
    others = [{"device": d, "data": v.get("data"),
               "updatedAt": v.get("updatedAt", 0)}
              for d, v in devices.items() if d != device and v.get("data")]

    result = {
        "accountId": aid,
        "bound": False,
        "roomActive": False,
        "serverSnapshot": mine.get("data"),
        "serverUpdatedAt": mine.get("updatedAt", 0),
        "deviceSnapshots": others,
    }

    room = room_of_account(aid)
    # 无房间的账号也会走到函数收尾，先初始化避免未赋值。
    early_mutated = False
    if room:
        # 存量/导入数据可能超过新的历史上限：在 sync 时补一次裁剪并落盘，
        # 保证读取到的房间不会无限膨胀（正常写入路径已在 append 时裁剪）。
        if (_trim_room_history(room, "messages", MAX_MESSAGES,
                               MAX_ROOM_MESSAGE_BYTES)
                or _trim_room_history(room, "comments", MAX_COMMENTS,
                                      MAX_ROOM_COMMENT_BYTES)):
            early_mutated = True
        # 存量已绑定房间补记绑定时间：一次性补齐，之后走正常轮询。
        if room.get("boundAt") is None and len(room["members"]) >= 2:
            room["boundAt"] = room.get("createdAt") or now_ms()
            room["updatedAt"] = now_ms()
            room["rev"] = room.get("rev", 0) + 1
            early_mutated = True
        # 已读回执/资料更新：必须在长轮询挂起判断【之前】记录——
        # 带 wait 的请求在 rev 无变化时会提前 return（unchanged/woken），
        # 放在挂起之后会被静默丢弃（前台已读回执因此从未上行）。
        read_up_to = p.get("readUpTo")
        if isinstance(read_up_to, int) and read_up_to > 0:
            # 未来时间戳会把之后的消息永久算作已读，按服务端当前时间封顶。
            read_up_to = min(read_up_to, now_ms())
            ra = room.setdefault("readAt", {})
            if read_up_to > ra.get(aid, 0):
                ra[aid] = read_up_to
                early_mutated = True
        if name:
            info = room.setdefault("memberInfo", {}).setdefault(aid, {})
            if info.get("name") != name:
                info["name"] = name
                early_mutated = True
        # 新配对的 X25519 公钥：只存不解释，供对方派生共享密钥。
        pub_key = _pub_key(p)
        if pub_key:
            pks = room.setdefault("pubKeys", {})
            if pks.get(aid) != pub_key:
                pks[aid] = pub_key
                early_mutated = True
        # 长期身份公钥 + 对 X25519 公钥的签名：只落库/转发，验签在客户端。
        if _store_room_identity(room, aid, _identity_pair(p)):
            early_mutated = True
        if early_mutated:
            room["updatedAt"] = now_ms()
            room["rev"] = room.get("rev", 0) + 1
            # 内部标记：do_POST 据此唤醒对端挂起的长轮询（已读回执即时可见）。
        # 无推送且 rev 未变时只回版本号。
        try:
            since_rev = int(p.get("since") or 0)
        except (TypeError, ValueError):
            raise ApiError("参数错误")
        if not want_older and not pushed and since_rev and since_rev == room.get("rev"):
            # 活跃房间在内存触摸活跃时间（不落盘），避免纯轮询房间被 TTL 回收。
            room["updatedAt"] = now_ms()
            # 长轮询：无变化时挂起，对方动作（rev 推进/房间删除）或超时唤醒。
            try:
                wait_s = min(int(p.get("wait") or 0), LONGPOLL_MAX_S)
            except (TypeError, ValueError):
                wait_s = 0
            if wait_s > 0 and _room_waiters < MAX_ROOM_WAITERS:
                cond = _room_cond(room["roomId"])
                deadline = time.monotonic() + wait_s
                _room_waiters += 1
                try:
                    while time.monotonic() < deadline:
                        if (room.get("rev") != since_rev
                                or room["roomId"] not in _rooms):
                            break
                        cond.wait(timeout=min(5.0, deadline - time.monotonic()))
                finally:
                    _room_waiters -= 1
                room["updatedAt"] = now_ms()
                if room.get("rev") != since_rev:
                    return {"roomRev": room["rev"], "woken": True,
                            "roomActive": True}
            # roomActive 供客户端区分无变化与房间已失效
            return {"roomRev": room["rev"], "unchanged": True,
                    "roomActive": True}

        # 版本号只在真实数据变更时推进，读同步不 bump（否则双端永久追逐全量）。
        mutated = pushed
        # （readUpTo/name 已在长轮询挂起之前记录，见上方 early_mutated。）
        # 未配满的房间持有绑定码，24h 轮换。
        if len(room["members"]) < 2:
            my_code = room.get("codes", {}).get(aid)
            born = room.get("codeBornAt", 0)
            if not my_code or now_ms() - born > 24 * 3600 * 1000:
                if my_code:
                    _codes.pop(my_code, None)
                    room["codes"].pop(aid, None)
                fresh = gen_code()
                room.setdefault("codes", {})[aid] = fresh
                _codes[fresh] = room["roomId"]
                room["codeBornAt"] = now_ms()
                mutated = True
        if mutated:
            room["updatedAt"] = now_ms()
            room["rev"] = room.get("rev", 0) + 1
        partner = next((u for u in room["members"] if u != aid), None)

        enriched = {}
        for member in room["members"]:
            rec = next((r for r in _accounts.values()
                        if r["accountId"] == member), None)
            info = dict(room["memberInfo"].get(member, {}))
            if rec is not None:
                info.setdefault("name", rec.get("name", ""))
                if rec.get("avatar"):
                    info["avatar"] = rec["avatar"]
                info["email"] = rec["username"]
            enriched[member] = info

        # 对方可见的快照 = 对方最新设备槽（v2 结构原样下发，客户端用
        # coupleKey 解密；旧明文格式兼容直读）。journal 对旧格式仍剥离。
        ps_devices = _slot_devices(partner) if partner else {}
        ps_raw = {}
        ps_ts = 0
        for d, v in ps_devices.items():
            if v.get("updatedAt", 0) >= ps_ts:
                ps_raw = v
                ps_ts = v.get("updatedAt", 0)
        ps_data = None
        if partner:
            ps_data = ps_raw.get("data")
            if ps_data is not None and "v" not in ps_data:
                ps_data = _strip_journal(ps_data)
        result.update({
            "roomActive": True,
            "revChanged": bool(mutated or early_mutated),
            "roomId": room["roomId"],
            "roomRev": room.get("rev", 0),
            "myCode": room.get("codes", {}).get(aid),
            "bound": partner is not None,
            "partnerAccountId": partner,
            "partnerName": enriched.get(partner, {}).get("name", "TA") if partner else None,
            "partnerSnapshot": ({"data": ps_data, "updatedAt": ps_raw.get("updatedAt", 0)}
                                if partner and ps_data is not None else None),
            "boundAt": room.get("boundAt", 0),
            "anniversary": room.get("anniversary", ""),
            "bookName": room.get("bookName", ""),
            "partnerReadAt": ((room.get("readAt") or {}).get(partner, 0)
                              if partner else 0),
            "partnerPubKey": ((room.get("pubKeys") or {}).get(partner)
                              if partner else None),
            "partnerIdentityPub": (((room.get("pubIdentities") or {})
                                    .get(partner) or {}).get("identityPub")
                                   if partner else None),
            "partnerPubKeySig": (((room.get("pubIdentities") or {})
                                  .get(partner) or {}).get("sig")
                                 if partner else None),
            "comments": room["comments"],
            "messages": room["messages"],
            "memberInfo": enriched,
        })
    if want_older:
        def _older_items(seq):
            out = []
            for m in seq:
                if not isinstance(m, dict):
                    continue
                ts = m.get("createdAt")
                if not isinstance(ts, (int, float)):
                    continue
                if ts < older_at or (ts == older_at
                                     and _cursor_id_lt(m.get("id", ""),
                                                       older_id)):
                    out.append(m)
            return out
        if "messages" in result:
            result["messages"] = _older_items(result.get("messages") or [])
        if "comments" in result:
            result["comments"] = _older_items(result.get("comments") or [])
    if evicted_device:
        # 客户端可据此提示「旧设备已被挤下线」；老客户端忽略未知字段。
        result["evictedDevice"] = evicted_device
    # 体积预算：只裁剪本次返回，不修改服务端已存的数据。
    result = _fit_sync_response(result, want_older=want_older)
    if early_mutated:
        # 内部标记：do_POST 据此唤醒对端挂起的长轮询（已读回执即时可见）。
        result["_mutated"] = True
    return result


def _strip_journal(snapshot):
    if not isinstance(snapshot, dict) or "journal" not in snapshot:
        return snapshot
    slim = dict(snapshot)
    slim.pop("journal", None)
    return slim


def _json_size(obj):
    return len(json.dumps(obj, ensure_ascii=False).encode("utf-8"))


def _cursor_id_lt(a, b):
    """复合分页游标里的 id 全序比较。

    服务端新数据 id 是定长 uuid hex，字典序即可；但历史/导入数据可能是
    非定长数字（"9" vs "10"）。这里定义：两端都是纯数字 -> 按数值比；
    否则先比长度、再字典序。这样 "9" < "10"，且任意两个 id 都有确定
    前后关系（不会因为定长假设把同毫秒的条目丢掉或重复返回）。
    """
    a = str(a if a is not None else "")
    b = str(b if b is not None else "")

    def _canonical_numeric(x):
        # 0 开头的数字串不按数值处理：否则 "01" 与 "1" 数值相等会破坏全序。
        return x.isdigit() and (len(x) == 1 or x[0] != "0")

    if _canonical_numeric(a) and _canonical_numeric(b):
        try:
            ia, ib = int(a), int(b)
        except ValueError:
            # Python 对超长数字串有 int 转换上限，退化为字符串全序。
            ia = ib = None
        if ia is not None:
            if ia != ib:
                return ia < ib
            # 规范数字串数值相等即字符串相等；显式兜底保持严格全序。
    if len(a) != len(b):
        return len(a) < len(b)
    return a < b


def _fit_sync_response(result, want_older=False):
    """单次 sync 响应体积预算（默认 6MB）。

    只裁剪本次返回，不修改服务端已存数据：
    - 先按 updatedAt 从旧到新挤掉可选的 deviceSnapshots；
    - 再把 messages/comments 从旧到新截断（保留最近的，新增 truncated 标记）；
    - serverSnapshot/partnerSnapshot 是同步必需数据，不裁剪。
    """
    budget = MAX_RESPONSE_BYTES - _RESPONSE_SAFETY_BYTES
    if _json_size(result) <= budget:
        return result

    messages = list(result.get("messages") or [])
    comments = list(result.get("comments") or [])
    base = {k: v for k, v in result.items()
            if k not in ("messages", "comments")}
    truncated = False

    snaps = list(base.get("deviceSnapshots") or [])
    snaps_truncated = False
    if snaps:
        base_size = _json_size(base)
        while snaps and base_size > budget:
            oldest = min(range(len(snaps)),
                         key=lambda i: (snaps[i].get("updatedAt", 0), i))
            snaps.pop(oldest)
            base["deviceSnapshots"] = snaps
            base_size = _json_size(base)
            snaps_truncated = True
        if not snaps:
            base["deviceSnapshots"] = []

    base_size = _json_size(base)
    avail = budget - base_size
    core_truncated = False
    if base_size > budget:
        # 光 serverSnapshot/partnerSnapshot/其它元数据就超预算（极端的大快照）：
        # 下面无法再截，标记 truncated 并让调用方知道还有数据没下发。
        core_truncated = True

    def fit_suffix(items, sizes, cap):
        if cap <= 0:
            return 0, 0
        keep = 0
        used = 0
        for sz in reversed(sizes):
            if used + sz > cap:
                break
            used += sz
            keep += 1
        return keep, used

    msg_sizes = [_json_size(m) + 1 for m in messages]
    cmt_sizes = [_json_size(c) + 1 for c in comments]
    msg_total = sum(msg_sizes)
    cmt_total = sum(cmt_sizes)
    keep_m = len(messages)
    keep_c = len(comments)
    used_m = used_c = 0
    if msg_total + cmt_total > avail:
        total = msg_total + cmt_total
        cap_m = int(avail * msg_total / total) if total else 0
        keep_m, used_m = fit_suffix(messages, msg_sizes, cap_m)
        keep_c, used_c = fit_suffix(comments, cmt_sizes, avail - used_m)
        # 评价太旧挤不进来时，把剩余预算再给消息。
        if used_m + used_c < avail and keep_m < len(messages):
            older = messages[:len(messages) - keep_m]
            older_sizes = msg_sizes[:len(msg_sizes) - keep_m]
            extra, extra_used = fit_suffix(
                older, older_sizes, avail - used_m - used_c)
            if extra:
                keep_m += extra
                used_m += extra_used
        rows_truncated = keep_m < len(messages) or keep_c < len(comments)
    else:
        rows_truncated = False

    out = dict(base)
    if "messages" in result:
        out["messages"] = messages[len(messages) - keep_m:] if keep_m else []
    if "comments" in result:
        out["comments"] = comments[len(comments) - keep_c:] if keep_c else []

    def _cursor_lt(x, y):
        if x[0] != y[0]:
            return x[0] < y[0]
        return _cursor_id_lt(x[1], y[1])

    def _oldest_key(seq):
        best = None
        for x in seq:
            if not isinstance(x, dict):
                continue
            ts = x.get("createdAt")
            if not isinstance(ts, (int, float)):
                continue
            key = (int(ts), str(x.get("id", "")))
            if best is None or _cursor_lt(key, best):
                best = key
        return best

    def _key_of(item):
        if not isinstance(item, dict):
            return None
        ts = item.get("createdAt")
        if not isinstance(ts, (int, float)):
            return None
        return (int(ts), str(item.get("id", "")))

    # 分页一致性：两个列表各自按预算截断后，最旧复合游标可能不同；客户端只有
    # 一个 olderBeforeAt/Id，通常取两个 oldest 的较小者。若某列表被截掉的条目
    # 复合游标晚于这个 min，下一页就永远取不到 → 丢数据。这里统一截到
    # cut=max(两列表最旧返回游标)，被切掉的条目全部 < cut，下一页取回且不重复。
    if rows_truncated:
        km = _oldest_key(out.get("messages") or [])
        kc = _oldest_key(out.get("comments") or [])
        candidates = [k for k in (km, kc) if k is not None]
        if candidates:
            cut = candidates[0]
            for k in candidates[1:]:
                if _cursor_lt(cut, k):
                    cut = k
            if "messages" in out:
                out["messages"] = [
                    m for m in out["messages"]
                    if _key_of(m) is not None
                    and not _cursor_lt(_key_of(m), cut)]
            if "comments" in out:
                out["comments"] = [
                    c for c in out["comments"]
                    if _key_of(c) is not None
                    and not _cursor_lt(_key_of(c), cut)]
    # truncated 永远只表示「还有更早的消息/评价」；设备槽裁剪统一用独立的
    # snapshotsTruncated（普通页/wantOlder 页都一样），避免两个语义混用。
    truncated = rows_truncated
    if truncated:
        out["truncated"] = True
        # 分页游标：本次实际返回里最旧的一条（没截断就不给）。
        km = _oldest_key(out.get("messages") or [])
        if km is not None:
            out["oldestMessageAt"], out["oldestMessageId"] = km
        kc = _oldest_key(out.get("comments") or [])
        if kc is not None:
            out["oldestCommentAt"], out["oldestCommentId"] = kc
    if snaps_truncated:
        out["snapshotsTruncated"] = True
    final_size = _json_size(out)
    if final_size > MAX_RESPONSE_BYTES:
        # 只有 serverSnapshot/partnerSnapshot 本身就近 6MB 时才会走到这里；
        # 它们是同步必需数据（客户端上限 48MB），记录日志便于排查。
        print("sync response still over budget:", final_size, flush=True)
    return out


# ---------- couple room ----------

def api_create_room(p, ip):
    aid = auth_account(p)
    prev = room_of_account(aid)
    if prev and len(prev["members"]) >= 2:
        raise ApiError("请先解除当前伴侣的绑定")
    detach_account(aid)
    room = {
        "roomId": uuid.uuid4().hex,
        "codes": {aid: gen_code()},
        "codeBornAt": now_ms(),
        "members": [aid],
        "memberInfo": {aid: {"name": str(p.get("name", ""))[:20] or "我"}},
        "snapshots": {},
        "comments": [],
        "messages": [],
        "rev": 1,  # 从 1 起步：客户端 since=0 与「无游标」可区分
        "createdAt": now_ms(),
        "updatedAt": now_ms(),
    }
    _rooms[room["roomId"]] = room
    pk = _pub_key(p)
    if pk:
        room["pubKeys"] = {aid: pk}
    ident = _identity_pair(p)
    if ident:
        room["pubIdentities"] = {aid: ident}
    _codes[room["codes"][aid]] = room["roomId"]
    return {"code": room["codes"][aid], "roomId": room["roomId"],
            "_mutated": True}


def api_join_room(p, ip):
    if limited(_join_log, ip, MAX_JOIN_ATTEMPTS, JOIN_WINDOW_MS):
        raise ApiError("尝试过于频繁，请稍后再试")
    aid = auth_account(p)
    code = str(p.get("code", "")).strip().upper()
    rid = _codes.get(code)
    if not rid or rid not in _rooms:
        raise ApiError("绑定码不存在或已失效")
    room = _rooms[rid]
    if len(room["members"]) >= 2:
        raise ApiError("这对情侣已经绑定好啦")
    if room["members"][0] == aid:
        raise ApiError("不能和自己绑定哦")
    prev = room_of_account(aid)
    if prev and len(prev["members"]) >= 2:
        raise ApiError("请先解除当前伴侣的绑定，再输入新的绑定码")
    detach_account(aid)
    partner = room["members"][0]
    room["members"].append(aid)
    room["memberInfo"][aid] = {"name": str(p.get("name", ""))[:20] or "我"}
    pk = _pub_key(p)
    if pk:
        room.setdefault("pubKeys", {})[aid] = pk
    ident = _identity_pair(p)
    if ident:
        _store_room_identity(room, aid, ident)
    room["boundAt"] = now_ms()
    _codes.pop(code, None)
    for k, v in list(room["codes"].items()):
        if v == code:
            room["codes"].pop(k, None)
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {
        "roomId": rid,
        "boundAt": room["boundAt"],
        "partnerAccountId": partner,
        "partnerName": room["memberInfo"].get(partner, {}).get("name", "TA"),
        "_mutated": True,
    }


def api_add_comment(p, ip):
    if limited(_comment_log, ip, COMMENT_CAP, MINUTE_MS):
        raise ApiError("操作太频繁，请稍后再试")
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room:
        raise ApiError("还没有绑定情侣")
    partner = next((u for u in room["members"] if u != aid), None)
    if partner is None or p.get("targetOwnerAccountId") != partner:
        raise ApiError("只能评价对方的内容")
    kind_label = {"journal": "日记", "habit": "习惯"}.get(p.get("targetKind", "task"), "任务")
    enc = p.get("enc") is True
    raw_text = str(p.get("text", ""))
    raw_title = str(p.get("displayTitle", ""))
    if enc and (len(raw_text) > MAX_ENC_TEXT or len(raw_title) > MAX_ENC_TEXT):
        raise ApiError("评价内容过长")
    # 明文沿用旧的截断行为；密文一旦截断就解不开，只能整条拒绝。
    title = raw_title[:50] if not enc else raw_title[:MAX_ENC_TEXT]
    text = raw_text[:MAX_TEXT] if not enc else raw_text[:MAX_ENC_TEXT]
    by_name = room["memberInfo"].get(aid, {}).get("name", "TA")
    comment = {
        "id": uuid.uuid4().hex,
        "byAccountId": aid,
        "targetOwnerAccountId": partner,
        "targetId": str(p.get("targetId", ""))[:64],
        "targetKind": str(p.get("targetKind", "task"))[:16],
        "kind": str(p.get("kind", "text"))[:16],
        "emoji": str(p.get("emoji") or "")[:16],
        "text": text,
        "enc": enc,
        "createdAt": now_ms(),
    }
    room["comments"].append(comment)
    _trim_room_history(room, "comments", MAX_COMMENTS, MAX_ROOM_COMMENT_BYTES)
    # 加密的评价服务端读不到正文，系统消息只记录「谁评价了哪一类」，
    # 具体内容由客户端用共享密钥解开后自行展示。
    if enc:
        if comment["kind"] == "emoji":
            sys_text = f"{by_name} {comment['emoji'] or '❤️'} 了你的{kind_label}"
        else:
            sys_text = f"{by_name} 评价了你的{kind_label}"
    elif comment["kind"] == "emoji":
        sys_text = f"{by_name} {comment['emoji'] or '❤️'} 了你的{kind_label}「{title}」"
    else:
        sys_text = f"{by_name} 评价了你的{kind_label}「{title}」：{comment['text']}"
    room["messages"].append({
        "id": uuid.uuid4().hex,
        "byAccountId": aid,
        "kind": "system",
        "text": sys_text,
        "createdAt": now_ms(),
    })
    _trim_room_history(room, "messages", MAX_MESSAGES, MAX_ROOM_MESSAGE_BYTES)
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"comment": comment, "_mutated": True}


def api_send_message(p, ip):
    if limited(_msg_log, ip, MSG_CAP, MINUTE_MS):
        raise ApiError("发送太频繁，请稍后再试")
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room:
        raise ApiError("还没有绑定情侣")
    text = str(p.get("text", "")).strip()
    enc = p.get("enc") is True
    limit = MAX_ENC_TEXT if enc else MAX_MSG_TEXT
    if len(text) > limit:
        raise ApiError("消息过长，请分段发送")
    if not text:
        raise ApiError("消息不能为空")
    reply_to = str(p.get("replyTo", ""))[:64]
    if reply_to and not any(
            m.get("id") == reply_to and m.get("kind") == "text"
            for m in room["messages"]):
        reply_to = ""
    msg = {
        "id": uuid.uuid4().hex,
        "byAccountId": aid,
        "kind": "text",
        "text": text,
        "enc": enc,
        "createdAt": now_ms(),
    }
    if reply_to:
        msg["replyTo"] = reply_to
    room["messages"].append(msg)
    _trim_room_history(room, "messages", MAX_MESSAGES, MAX_ROOM_MESSAGE_BYTES)
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"message": msg, "_mutated": True}


def api_delete_message(p, ip):
    """撤回：仅发送者本人；消息原位改为墓碑，旧客户端也能显示合理文案。"""
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room:
        raise ApiError("还没有绑定情侣")
    mid = str(p.get("messageId", ""))[:64]
    msg = next((m for m in room["messages"] if m.get("id") == mid), None)
    if msg is None:
        raise ApiError("消息不存在或已被清理")
    if msg.get("byAccountId") != aid or msg.get("kind") != "text":
        raise ApiError("只能撤回自己发的消息")
    msg["kind"] = "deleted"
    msg["text"] = "撤回了一条消息"
    msg.pop("replyTo", None)
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"ok": True, "_mutated": True}


def api_report_event(p, ip):
    """Client-detected events (e.g. task completed) become board system messages."""
    if limited(_event_log, ip, EVENT_CAP, MINUTE_MS):
        raise ApiError("请求过于频繁，请稍后再试")
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room:
        return {"ok": True}
    text = str(p.get("text", "")).strip()[:MAX_TEXT]
    if not text:
        return {"ok": True}
    room["messages"].append({
        "id": uuid.uuid4().hex,
        "byAccountId": aid,  # 客户端按发送者过滤自己的消息
        "kind": "system",
        "text": text,
        "createdAt": now_ms(),
    })
    _trim_room_history(room, "messages", MAX_MESSAGES, MAX_ROOM_MESSAGE_BYTES)
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"ok": True, "_mutated": True}


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def api_set_anniversary(p, ip):
    """设置或清除房间纪念日；清空后按绑定日计在一起天数。"""
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room or len(room["members"]) < 2:
        raise ApiError("还没有绑定情侣")
    date = str(p.get("date", "")).strip()
    if date:
        if not DATE_RE.fullmatch(date):
            raise ApiError("日期格式不对")
        try:
            time.strptime(date, "%Y-%m-%d")
        except ValueError:
            raise ApiError("这个日期不存在")
        # 客户端按本地日历选日期；服务器时钟可能是 UTC，
        # 以东八区的「今天」为参照，避免 UTC+8 用户凌晨被误拒。
        today = time.strftime("%Y-%m-%d", time.gmtime(time.time() + 8 * 3600))
        if date > today:
            raise ApiError("纪念日不能是未来的日子")
    room["anniversary"] = date
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"anniversary": date, "_mutated": True}


def api_logout(p, ip):
    token = str(p.get("token", ""))
    aid = _tokens.pop(token, None)
    _token_devices.pop(token, None)
    if aid:
        for rec in _accounts.values():
            if rec["accountId"] == aid:
                # 只注销这一个会话，其它设备保持登录。
                tokens = [t for t in _account_tokens(rec) if t != token]
                if tokens:
                    rec["tokens"] = tokens
                    rec["token"] = tokens[0]
                else:
                    rec.pop("tokens", None)
                    rec["token"] = ""
                td = rec.get("tokenDevices")
                if isinstance(td, dict):
                    td.pop(token, None)
                break
        save_accounts()
    return {"ok": True}


def api_unbind(p, ip):
    aid = auth_account(p)
    room = room_of_account(aid)
    if room:
        drop_room(room["roomId"])
        return {"ok": True, "_mutated": True}
    return {"ok": True}


def read_manifest():
    f = APK_DIR / "version.json"
    if not f.exists():
        return None
    try:
        # utf-8-sig：Windows 记事本/PowerShell 导出的 JSON 常带 BOM，
        # 用 utf-8 直接读会抛异常，导致更新检查一直返回「无更新」。
        return json.loads(f.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        print("version.json load failed:", exc, flush=True)
        return None


_sha_cache = {}  # 文件名 -> (mtime_ns, size, sha256)


def _file_sha256(path):
    st = path.stat()
    cached = _sha_cache.get(path.name)
    if cached and cached[0] == st.st_mtime_ns and cached[1] == st.st_size:
        return cached[2]
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(256 * 1024), b""):
            h.update(chunk)
    digest = h.hexdigest()
    _sha_cache[path.name] = (st.st_mtime_ns, st.st_size, digest)
    return digest


def api_check_update(p, ip):
    """入参 {version, platform}；返回更新与下载信息。"""
    if limited(_update_log, ip, UPDATE_CAP, MINUTE_MS):
        raise ApiError("请求过于频繁，请稍后再试")
    manifest = read_manifest()
    if not manifest:
        return {"update": False}
    current = str(p.get("version", "0.0.0"))
    latest = str(manifest.get("version", "0.0.0"))

    def vt(v):
        # 宽松版本比较：忽略后缀，按段数值比较。
        core = re.split(r"[+\-~]", str(v).strip())[0]
        parts = []
        for x in core.split("."):
            try:
                parts.append(int(x))
            except ValueError:
                break
        if not parts:
            return (0,)
        return tuple(parts)

    a, b = vt(latest), vt(current)
    n = max(len(a), len(b))
    has_update = a + (0,) * (n - len(a)) > b + (0,) * (n - len(b))
    # 桌面端走独立的便携 zip 通道(fileWindows)。没有配这一项就说明当前
    # 不发布桌面版，直接回「已是最新」，不要退回去让客户端下 APK。
    is_win = str(p.get("platform", "android")) == "windows"
    if is_win:
        fname = str(manifest.get("fileWindows") or "")
    else:
        fname = str(manifest.get("file", ""))
    # 只认本目录下的文件名，挡住 ../ 这种写法。
    fname = os.path.basename(fname)
    if not fname or not (fname.endswith(".apk") or fname.endswith(".zip")):
        return {"update": False}
    f = APK_DIR / fname
    if not f.exists():
        return {"update": False}
    result = {
        "update": has_update,
        "latest": latest,
        "file": fname,
        "size": f.stat().st_size,
        "notes": manifest.get("notes", ""),
    }
    # 只在真有更新时才算哈希（客户端以此校验下载完整性）。
    if has_update:
        result["sha256"] = _file_sha256(f)
    return result


def api_set_book_name(p, ip):
    """设置情侣「纪念日」名称；空串回退默认显示。双方同步。"""
    aid = auth_account(p)
    room = room_of_account(aid)
    if not room or len(room["members"]) < 2:
        raise ApiError("还没有绑定情侣")
    name = str(p.get("name", "")).strip()[:20]
    room["bookName"] = name
    room["updatedAt"] = now_ms()
    room["rev"] = room.get("rev", 0) + 1
    return {"bookName": name, "_mutated": True}


def api_list_devices(p, ip):
    """本账号登录过的设备列表（设备管理 UI 用）。只回自己账号的槽。"""
    aid = auth_account(p)
    token = str(p.get("token", ""))
    # current 只认服务端会话记录；没有记录就不标当前设备，
    # 免得请求里随便传个 device 就成了"当前设备"、绕开删除保护。
    current = _token_devices.get(token, "")
    devices = _slot_devices(aid)
    rows = []
    for dev, info in devices.items():
        rows.append({
            "device": dev,
            "name": str(info.get("name", ""))[:40],
            "updatedAt": int(info.get("updatedAt", 0)),
            "current": dev == current,
        })
    rows.sort(key=lambda r: r["updatedAt"], reverse=True)
    return {"devices": rows, "max": MAX_DEVICE_SLOTS}


def api_drop_device(p, ip):
    """删除本账号的指定设备槽（设备管理用）。只能删自己账号的槽。

    device 必填，作为要删除的目标槽。当前设备判定优先级：
      1) 显式 currentDevice/callerDevice（配合新客户端可同时传 target 槽）；
      2) 本 token 最近一次 sync/listDevices 上报的 device；
      3) 若请求用 targetDevice 指定目标，则请求里的 device 视为当前设备。
    当前设备一律拒绝（400），服务端兜底客户端 UI。
    """
    aid = auth_account(p)
    token = str(p.get("token", ""))
    raw_device = str(p.get("device", ""))[:64]
    if not raw_device:
        raise ApiError("参数错误")
    target_override = p.get("targetDevice") or p.get("target")
    if target_override:
        target = str(target_override)[:64]
    else:
        target = raw_device
    # 以服务端会话的 tokenDevices 为准；没有任何记录时直接拒绝，绝不把
    # 请求里的 device 当 current（否则第一次就能删别的槽）。
    current = _token_devices.get(token, "")
    if not current:
        raise ApiError("请先同步一次再管理设备")
    if not target:
        raise ApiError("参数错误")
    if target == current:
        raise ApiError("不能移除当前设备，退出登录即可")
    device = target
    devices = _slot_devices(aid)
    if device not in devices:
        raise ApiError("设备不存在")
    devices.pop(device)
    if devices:
        slot_updated = max((d.get("updatedAt", 0) for d in devices.values()),
                           default=0)
        _snapshots[aid] = {"devices": devices, "updatedAt": slot_updated}
        save_snapshot(aid)
    else:
        _snapshots.pop(aid, None)
        f = DATA_DIR / "data" / f"{aid}.json"
        for path in (f, f.with_suffix(".json.tmp"), f.with_suffix(".json.bak")):
            try:
                path.unlink()
            except OSError:
                pass
    return {"dropped": device, "remaining": len(devices)}


def api_rename_device(p, ip):
    """重命名本账号的指定设备槽；name 最长 40 字符。"""
    aid = auth_account(p)
    device = str(p.get("device", ""))[:64]
    if not device:
        raise ApiError("参数错误")
    name = str(p.get("name", "")).strip()[:40]
    if not name:
        raise ApiError("设备名不能为空")
    devices = _slot_devices(aid)
    slot = devices.get(device)
    if not isinstance(slot, dict):
        raise ApiError("设备不存在")
    slot["name"] = name
    slot["customName"] = True
    slot_updated = max((d.get("updatedAt", 0) for d in devices.values()),
                       default=0)
    _snapshots[aid] = {"devices": devices, "updatedAt": slot_updated}
    save_snapshot(aid)
    return {"renamed": device, "name": name}


# ---------- 通知投递 ----------
# 不接入任何第三方推送服务：留言/动态的实时性完全由客户端长轮询保证
# （前台常驻连接 + Android 前台服务保活 + 精确闹钟兜底）。
# 服务端只负责在数据变化时立刻唤醒挂起的长轮询，不主动外发通知。


ACTIONS = {
    "requestCode": api_request_code,
    "register": api_register,
    "login": api_login,
    "sync": api_sync,
    "createRoom": api_create_room,
    "joinRoom": api_join_room,
    "setAnniversary": api_set_anniversary,
    "setBookName": api_set_book_name,
    "unbind": api_unbind,
    "logout": api_logout,
    "profile": api_profile,
    "checkUpdate": api_check_update,
    "addComment": api_add_comment,
    "sendMessage": api_send_message,
    "deleteMessage": api_delete_message,
    "reportEvent": api_report_event,
    "dropDevice": api_drop_device,
    "listDevices": api_list_devices,
    "renameDevice": api_rename_device,
}


class Handler(BaseHTTPRequestHandler):
    timeout = 30  # 无进展的慢连接断开

    def setup(self):
        # TLS 握手移到工作线程并限时完成。listening socket 整体 wrap 时，
        # 握手在主线程 accept 里、且该阶段无超时——一个完成 TCP 握手却
        # 挂着不发 TLS 数据的连接（扫描器/探活）就能永久卡死接受循环，
        # 所有客户端连接超时而进程看起来正常。
        self.request.settimeout(10)
        self.request = TLS_CTX.wrap_socket(self.request, server_side=True)
        super().setup()

    def _reply(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        if status >= 400:
            note_bad_request(self.client_address[0])

    def do_GET(self):
        """应用更新包下载：GET /apk/<白名单文件名>。"""
        ip = self.client_address[0]
        if ip_banned(ip):
            self._reply({"error": "请求过于频繁，请稍后再试"}, 429)
            return
        if not self.path.startswith("/apk/"):
            self._reply({"error": "not found"}, 404)
            return
        name = os.path.basename(self.path[len("/apk/"):])
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or not name.endswith(
                (".apk", ".zip")):
            self._reply({"error": "bad file"}, 400)
            return
        f = APK_DIR / name
        if not f.exists():
            self._reply({"error": "not found"}, 404)
            return
        try:
            size = f.stat().st_size
            # 断点续传：仅支持 bytes=N- 单起始区间；畸形头一律回 200 全量。
            start = 0
            range_head = self.headers.get("Range", "")
            m = re.fullmatch(r"bytes=(\d+)-", range_head.strip())
            if m is not None:
                start = min(int(m.group(1)), size)
            partial = start > 0
            self.send_response(206 if partial else 200)
            self.send_header(
                "Content-Type",
                "application/zip" if name.endswith(".zip")
                else "application/vnd.android.package-archive"
            )
            self.send_header("Accept-Ranges", "bytes")
            if partial:
                self.send_header(
                    "Content-Range", f"bytes {start}-{size - 1}/{size}")
            self.send_header("Content-Length", str(size - start))
            self.end_headers()
            with open(f, "rb") as fh:
                if partial:
                    fh.seek(start)
                while True:
                    chunk = fh.read(1024 * 64)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass  # 客户端取消下载属正常情况
        except Exception as exc:
            print("apk download error:", exc, flush=True)

    def do_POST(self):
        ip = self.client_address[0]
        if ip_banned(ip):
            self._reply({"error": "请求过于频繁，请稍后再试"}, 429)
            return
        if self.path != "/api":
            self._reply({"error": "not found"}, 404)
            return
        try:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self._reply({"error": "bad request"}, 400)
                return
            if length <= 0 or length > 3 * 1024 * 1024:
                self._reply({"error": "payload too large"}, 413)
                return
            try:
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._reply({"error": "bad request"}, 400)
                return
            if not isinstance(payload, dict):
                self._reply({"error": "bad request"}, 400)
                return
            if not APP_KEY or not secrets.compare_digest(
                str(payload.get("appKey", "")).encode("utf-8"),
                APP_KEY.encode("utf-8"),
            ):
                self._reply({"error": "unauthorized"}, 401)
                return
            action = payload.get("action")
            # action 必须是字符串：list/dict 会让字典查找抛 TypeError 变成 500。
            if not isinstance(action, str) or not action:
                self._reply({"error": "unknown action"}, 400)
                return
            fn = ACTIONS.get(action)
            if fn is None:
                self._reply({"error": "unknown action"}, 400)
                return
            ip = self.client_address[0]
            # 限流必须在 PBKDF2 之前：否则被限的请求仍要烧一次慢散列，
            # 单机几秒就能被压满一核。
            if action in ("login", "register") and limited(
                    _auth_log, ip, MAX_AUTH_ATTEMPTS, AUTH_WINDOW_MS):
                raise ApiError("尝试过于频繁，请稍后再试")
            # PBKDF2 在锁外完成，避免慢散列拖住全局锁上的所有请求。
            pre = PREHASH.get(action)
            if pre is not None:
                pre(payload)
            with _lock:
                swept = maybe_sweep()
                if swept:
                    # 巡检真的删了房间：先落盘，避免本次 handler 抛错时
                    # 删除只存在于内存、重启后又把过期房间带回来。
                    save_rooms()
                result = fn(payload, ip)
                # 只有真的写入了 rooms 的动作才落盘/广播：handler 用 _mutated
                # 显式声明；sync 用 revChanged（rev 真的推进）声明；TTL 巡检
                # 真删了房间也算。login/checkUpdate 等不碰 rooms 的动作不再
                # 重写 rooms.json，也不再唤醒所有房间的长轮询。
                mutated = bool(swept)
                if isinstance(result, dict):
                    if result.pop("_mutated", False):
                        mutated = True
                    if result.get("revChanged"):
                        mutated = True
                if mutated:
                    _notify_room_change()
                    save_rooms()
            # 邮件在锁外发送。
            if action == "requestCode" and isinstance(result, dict):
                email = result.pop("email")
                code = result.pop("code")
                try:
                    send_code_email(email, code)
                except Exception as exc:
                    print("code email send failed:", exc, flush=True)
                    _codes.pop(email, None)
                    self._reply(
                        {"error": "验证码邮件发送失败，请稍后再试"}, 502)
                    return
                if GD_DEBUG:
                    result["devCode"] = code
            self._reply({"ok": True, "result": result})
        except ApiError as exc:
            self._reply({"error": str(exc)}, 400)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass  # 客户端断开/写超时属正常情况，不再补发 500
        except Exception as exc:
            print("internal error:", exc, flush=True)
            self._reply({"error": "internal error"}, 500)


class Server(ThreadingHTTPServer):
    # 默认 backlog 只有 5，accept 稍慢就丢新连接；128 抗突发。
    request_queue_size = 128

    def handle_error(self, request, client_address):
        # setup 阶段的握手失败/超时是高频噪音（扫描器、探活），静默关闭。
        # handler 内部异常已在 do_POST/do_GET 里自行打印，这里无需重复。
        pass

    def service_actions(self):
        # systemd Type=notify 看门狗喂狗：只有接受循环活着才会走到这里，
        # 主循环一旦卡死即停喂，systemd 在 WatchdogSec 后自动拉起服务。
        super().service_actions()
        _sd_notify("WATCHDOG=1")


def _sd_notify(message):
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    global _notify_sock
    try:
        if _notify_sock is None:
            if addr.startswith("@"):
                addr = "\0" + addr[1:]
            _notify_sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            _notify_sock.connect(addr)
        _notify_sock.sendall(message.encode())
    except OSError as exc:
        print("sd notify failed:", exc, flush=True)
        _notify_sock = None


_notify_sock = None


def main():
    acquire_instance_lock()
    load_state()
    global TLS_CTX
    TLS_CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    TLS_CTX.load_cert_chain(CERT_FILE, KEY_FILE)
    server = Server(("0.0.0.0", PORT), Handler)
    print(f"goalday-sync v2 listening on :{PORT}", flush=True)
    _sd_notify("READY=1")
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
