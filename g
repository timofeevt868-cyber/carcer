"""
SpyBot — ловит удалённые и изменённые сообщения через Telegram Business API.
Запуск: python bot.py  (зависимости установятся автоматически)

Как включить Business Mode:
  1. @BotFather → твой бот → Bot Settings → Business Mode → Enable
  2. Telegram → Настройки → Telegram Business → Чат-боты → добавь бота
"""

# ══════════════════════════════════════════════════════════
#  АВТОУСТАНОВКА ЗАВИСИМОСТЕЙ
# ══════════════════════════════════════════════════════════
import subprocess, sys

_REQUIRED = {
    "aiogram":   "aiogram==3.13.1",
    "aiosqlite": "aiosqlite==0.20.0",
}

def _install_missing():
    ok = True
    for mod, pkg in _REQUIRED.items():
        try:
            __import__(mod)
        except ImportError:
            print(f"[SpyBot] Устанавливаю {pkg}...")
            r = subprocess.run([sys.executable, "-m", "pip", "install", pkg],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"[SpyBot] ОШИБКА: {r.stderr[-300:]}")
                ok = False
            else:
                print(f"[SpyBot] {pkg} — OK ✅")
    return ok

if not _install_missing():
    print("\n[SpyBot] Установи вручную:\n  pip install aiogram aiosqlite")
    sys.exit(1)

# ══════════════════════════════════════════════════════════
#  ▼▼▼  НАСТРОЙКИ — ЗАПОЛНИ ЭТИ 2 СТРОКИ  ▼▼▼
# ══════════════════════════════════════════════════════════
import os

BOT_TOKEN = "8989924852:AAFPev4Tva0mBjXMqIDlxLzmdrEEZCfCSR4"  # ← @BotFather → /newbot → скопируй токен
ADMIN_ID  = 8769232009   # ← твой Telegram ID (напиши @userinfobot — он ответит числом)

# ── Остальное можно не трогать ────────────────────────────
STARS_PRICE = 69    # цена подписки в Telegram Stars
TRIAL_DAYS  = 10    # дней пробного периода
SUB_DAYS    = 30    # дней платной подписки
DB_PATH     = "spybot.db"
# ══════════════════════════════════════════════════════════
#  ▲▲▲  ТОЛЬКО ЭТО НУЖНО ЗАПОЛНИТЬ  ▲▲▲
# ══════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════
#  ИМПОРТЫ
# ══════════════════════════════════════════════════════════
import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional

import aiosqlite

from aiogram import Bot, Dispatcher, Router, F
from aiogram.client.default import DefaultBotProperties
from aiogram.enums import ParseMode
from aiogram.fsm.storage.memory import MemoryStorage
from aiogram.types import (
    Message, ChatMemberUpdated, CallbackQuery,
    InlineKeyboardMarkup, InlineKeyboardButton,
    LabeledPrice, PreCheckoutQuery,
    BusinessConnection, BusinessMessagesDeleted,
)
from aiogram.filters import CommandStart, Command, ChatMemberUpdatedFilter, KICKED, MEMBER

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

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
            chat_id  INTEGER PRIMARY KEY,
            owner_id INTEGER NOT NULL,
            title    TEXT
        );
        CREATE TABLE IF NOT EXISTS message_cache (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id     INTEGER NOT NULL,
            message_id  INTEGER NOT NULL,
            chat_title  TEXT,
            sender_name TEXT,
            text        TEXT,
            media_type  TEXT,
            file_id     TEXT,
            date        TIMESTAMP,
            cached_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(chat_id, message_id)
        );
        CREATE TABLE IF NOT EXISTS business_connections (
            bc_id    TEXT PRIMARY KEY,
            user_id  INTEGER NOT NULL,
            phone    TEXT,
            active   INTEGER DEFAULT 1
        );
    """)
    await _db.commit()
    log.info(f"Database ready: {DB_PATH}")

def _dt(val) -> Optional[datetime]:
    if not val: return None
    if isinstance(val, datetime): return val
    try: return datetime.fromisoformat(val)
    except: return None

# ── users ──────────────────────────────────────────────────

async def db_get_or_create(user_id: int, name: str) -> dict:
    async with _db.execute("SELECT * FROM users WHERE user_id=?", (user_id,)) as c:
        row = await c.fetchone()
    if row: return dict(row)
    await _db.execute("INSERT OR IGNORE INTO users(user_id,name) VALUES(?,?)", (user_id, name))
    await _db.commit()
    return {"user_id": user_id, "name": name, "trial_used": 0}

async def db_get_user(user_id: int) -> Optional[dict]:
    async with _db.execute("SELECT * FROM users WHERE user_id=?", (user_id,)) as c:
        row = await c.fetchone()
    if not row: return None
    d = dict(row)
    d["trial_start"] = _dt(d.get("trial_start"))
    d["sub_until"]   = _dt(d.get("sub_until"))
    return d

async def db_activate_trial(user_id: int):
    await _db.execute("UPDATE users SET trial_start=?,trial_used=1 WHERE user_id=?",
                      (datetime.utcnow(), user_id))
    await _db.commit()

async def db_set_sub(user_id: int, until: datetime):
    await _db.execute("UPDATE users SET sub_until=? WHERE user_id=?", (until, user_id))
    await _db.commit()

async def db_all_ids() -> list[int]:
    async with _db.execute("SELECT user_id FROM users") as c:
        return [r[0] for r in await c.fetchall()]

# ── chats ──────────────────────────────────────────────────

async def db_add_chat(owner_id: int, chat_id: int, title: str):
    await _db.execute("INSERT OR REPLACE INTO chats(chat_id,owner_id,title) VALUES(?,?,?)",
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

# ── business connections ───────────────────────────────────

async def db_save_bc(bc_id: str, user_id: int):
    await _db.execute(
        "INSERT OR REPLACE INTO business_connections(bc_id,user_id,active) VALUES(?,?,1)",
        (bc_id, user_id))
    await _db.commit()

async def db_deactivate_bc(bc_id: str):
    await _db.execute("UPDATE business_connections SET active=0 WHERE bc_id=?", (bc_id,))
    await _db.commit()

async def db_get_bc_owner(bc_id: str) -> Optional[int]:
    async with _db.execute(
        "SELECT user_id FROM business_connections WHERE bc_id=? AND active=1", (bc_id,)
    ) as c:
        row = await c.fetchone()
    return row[0] if row else None

async def db_get_user_bc(user_id: int) -> Optional[str]:
    async with _db.execute(
        "SELECT bc_id FROM business_connections WHERE user_id=? AND active=1", (user_id,)
    ) as c:
        row = await c.fetchone()
    return row[0] if row else None

async def db_all_bc_owners() -> list[int]:
    async with _db.execute("SELECT DISTINCT user_id FROM business_connections WHERE active=1") as c:
        return [r[0] for r in await c.fetchall()]

# ── message cache ──────────────────────────────────────────

async def db_cache(message: Message):
    mt = fi = None
    if message.photo:        mt, fi = "photo",      message.photo[-1].file_id
    elif message.video:      mt, fi = "video",       message.video.file_id
    elif message.audio:      mt, fi = "audio",       message.audio.file_id
    elif message.document:   mt, fi = "document",    message.document.file_id
    elif message.sticker:    mt, fi = "sticker",     message.sticker.file_id
    elif message.voice:      mt, fi = "voice",       message.voice.file_id
    elif message.video_note: mt, fi = "video_note",  message.video_note.file_id

    sender = message.from_user.full_name if message.from_user else "Аноним"
    title  = getattr(message.chat, "title", None) or \
             getattr(message.chat, "first_name", None) or str(message.chat.id)
    try:
        await _db.execute(
            """INSERT OR REPLACE INTO message_cache
               (chat_id,message_id,chat_title,sender_name,text,media_type,file_id,date)
               VALUES(?,?,?,?,?,?,?,?)""",
            (message.chat.id, message.message_id, title, sender,
             message.text or message.caption, mt, fi, message.date))
        await _db.commit()
    except Exception as e:
        log.warning(f"cache error: {e}")
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
    if not row: return None
    d = dict(row)
    d["date"] = _dt(d.get("date")) or datetime.utcnow()
    return d

async def db_del_cached(chat_id: int, msg_id: int):
    await _db.execute(
        "DELETE FROM message_cache WHERE chat_id=? AND message_id=?", (chat_id, msg_id))
    await _db.commit()

# ── stats ──────────────────────────────────────────────────

async def db_stats() -> dict:
    now = datetime.utcnow()
    async def one(q, *a):
        async with _db.execute(q, a) as c: return (await c.fetchone())[0]
    return {
        "users":    await one("SELECT COUNT(*) FROM users"),
        "chats":    await one("SELECT COUNT(*) FROM chats"),
        "cached":   await one("SELECT COUNT(*) FROM message_cache"),
        "subs":     await one("SELECT COUNT(*) FROM users WHERE sub_until>?", now),
        "trials":   await one("SELECT COUNT(*) FROM users WHERE trial_start>? AND sub_until IS NULL",
                              now - timedelta(days=TRIAL_DAYS)),
        "business": await one("SELECT COUNT(*) FROM business_connections WHERE active=1"),
    }

# ══════════════════════════════════════════════════════════
#  ПОДПИСКА
# ══════════════════════════════════════════════════════════

async def is_subscribed(user_id: int) -> bool:
    u = await db_get_user(user_id)
    if not u: return False
    if u.get("sub_until"):
        return datetime.utcnow() < u["sub_until"]
    if u.get("trial_start"):
        return datetime.utcnow() < u["trial_start"] + timedelta(days=TRIAL_DAYS)
    return False

async def active_owners(chat_id: int) -> list[int]:
    return [uid for uid in await db_chat_owners(chat_id) if await is_subscribed(uid)]

# ══════════════════════════════════════════════════════════
#  КЛАВИАТУРЫ
# ══════════════════════════════════════════════════════════

def kb_main() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Мои чаты",           callback_data="my_chats")],
        [InlineKeyboardButton(text="👤 Профиль / Подписка", callback_data="profile")],
        [InlineKeyboardButton(text="❓ Как это работает",    callback_data="howto")],
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

# ══════════════════════════════════════════════════════════
#  УВЕДОМЛЕНИЯ
# ══════════════════════════════════════════════════════════

async def notify_deleted(bot: Bot, user_id: int, cached: dict):
    date_str = cached["date"].strftime("%d.%m.%Y %H:%M") if cached.get("date") else "?"
    header = (
        f"🗑 <b>Удалённое сообщение</b>\n"
        f"💬 Чат: <b>{cached.get('chat_title','?')}</b>\n"
        f"👤 От: <b>{cached.get('sender_name','Аноним')}</b>\n"
        f"🕐 {date_str}\n"
    )
    try:
        if cached.get("text"):
            await bot.send_message(user_id, header + f"\n📝 Текст:\n{cached['text']}")
        elif cached.get("file_id"):
            await bot.send_message(user_id, header + f"\n📎 Тип: {cached.get('media_type')}")
            await resend_media(bot, user_id, cached["media_type"], cached["file_id"])
        else:
            await bot.send_message(user_id, header + "\n[медиа]")
    except Exception as e:
        log.warning(f"notify_deleted failed for {user_id}: {e}")

async def notify_edited(bot: Bot, user_id: int, chat_title: str,
                        sender: str, old_text: str, new_text: str):
    try:
        await bot.send_message(user_id,
            f"✏️ <b>Изменённое сообщение</b>\n"
            f"💬 Чат: <b>{chat_title}</b>\n"
            f"👤 Автор: <b>{sender}</b>\n"
            f"🕐 {datetime.utcnow().strftime('%d.%m.%Y %H:%M')}\n\n"
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
        log.warning(f"resend_media: {e}")

# ══════════════════════════════════════════════════════════
#  РОУТЕР / ХЕНДЛЕРЫ
# ══════════════════════════════════════════════════════════

router = Router(name="spybot")

# ── /start ─────────────────────────────────────────────────

@router.message(CommandStart())
async def cmd_start(message: Message):
    await db_get_or_create(message.from_user.id, message.from_user.full_name)
    active = await is_subscribed(message.from_user.id)
    if active:
        bc = await db_get_user_bc(message.from_user.id)
        bc_status = "🟢 Business подключён — ловлю личку" if bc else "🔴 Business не подключён"
        await message.answer(
            f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"
            "🤖 <b>SpyBot</b> активен.\n\n"
            "Что ловлю:\n"
            "🗑 Удалённые сообщения\n"
            "✏️ Изменённые сообщения\n\n"
            f"Статус: {bc_status}",
            reply_markup=kb_main()
        )
    else:
        await message.answer(
            f"👋 Привет, <b>{message.from_user.first_name}</b>!\n\n"
            "🤖 <b>SpyBot</b> — ловит удалённые и изменённые сообщения через Telegram Business.\n\n"
            "✅ Работает в личке (нужен Telegram Premium)\n"
            "✅ Работает в группах\n\n"
            f"💰 <b>{STARS_PRICE} ⭐ Stars</b> / месяц\n"
            f"🎁 Пробный период: <b>{TRIAL_DAYS} дней бесплатно</b>",
            reply_markup=kb_sub()
        )

# ── профиль ────────────────────────────────────────────────

@router.callback_query(F.data == "profile")
async def cb_profile(call: CallbackQuery):
    user = await db_get_user(call.from_user.id)
    if not user:
        await call.answer("Сначала /start", show_alert=True); return
    active = await is_subscribed(call.from_user.id)
    chats  = await db_user_chats(call.from_user.id)
    bc     = await db_get_user_bc(call.from_user.id)

    if active:
        if user.get("sub_until"):
            status = f"✅ Подписка до <b>{user['sub_until'].strftime('%d.%m.%Y')}</b>"
        else:
            end  = user["trial_start"] + timedelta(days=TRIAL_DAYS)
            left = max((end - datetime.utcnow()).days, 0)
            status = f"🎁 Пробный до <b>{end.strftime('%d.%m.%Y')}</b> ({left} дн.)"
    else:
        status = "❌ Подписка не активна"

    bc_status = "🟢 Подключён (личка ловится)" if bc else "🔴 Не подключён"

    await call.message.edit_text(
        f"👤 <b>Профиль</b>\n\n"
        f"ID: <code>{call.from_user.id}</code>\n"
        f"Статус: {status}\n"
        f"Групп отслеживается: <b>{len(chats)}</b>\n"
        f"Telegram Business: {bc_status}",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text=f"⭐ Продлить — {STARS_PRICE} Stars", callback_data="buy_sub")],
            [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
        ])
    )
    await call.answer()

# ── мои чаты ───────────────────────────────────────────────

@router.callback_query(F.data == "my_chats")
async def cb_my_chats(call: CallbackQuery):
    chats = await db_user_chats(call.from_user.id)
    if not chats:
        text = "📋 <b>Мои группы</b>\n\nПока нет отслеживаемых групп.\nДобавь бота в группу как администратора!"
    else:
        lines = "\n".join(f"• {c['title']} (<code>{c['chat_id']}</code>)" for c in chats)
        text = f"📋 <b>Мои группы</b> ({len(chats)}):\n\n{lines}"
    await call.message.edit_text(text, reply_markup=kb_back())
    await call.answer()

# ── как это работает ───────────────────────────────────────

@router.callback_query(F.data == "howto")
async def cb_howto(call: CallbackQuery):
    await call.message.edit_text(
        "❓ <b>Как использовать SpyBot</b>\n\n"
        "<b>── Личная переписка ──</b>\n"
        "Нужен Telegram Premium\n\n"
        "<b>Шаг 1.</b> Включи Business Mode в боте:\n"
        "@BotFather → твой бот → Bot Settings → Business Mode → Enable\n\n"
        "<b>Шаг 2.</b> Подключи бота в Telegram:\n"
        "Настройки → Telegram Business → Чат-боты → введи @username бота\n\n"
        "✅ Готово! Бот начнёт ловить удалённые и изменённые в твоей личке.\n\n"
        "<b>── Группы ──</b>\n"
        "Добавь бота в группу как администратора — и он будет ловить там.",
        reply_markup=kb_back()
    )
    await call.answer()

@router.callback_query(F.data == "back_main")
async def cb_back(call: CallbackQuery):
    await call.message.edit_text("🏠 <b>Главное меню</b>", reply_markup=kb_main())
    await call.answer()

# ── триал ──────────────────────────────────────────────────

@router.callback_query(F.data == "trial")
async def cb_trial(call: CallbackQuery):
    user = await db_get_user(call.from_user.id)
    if not user:
        await db_get_or_create(call.from_user.id, call.from_user.full_name)
        user = await db_get_user(call.from_user.id)
    if user.get("trial_used"):
        await call.answer("❌ Пробный период уже использован!", show_alert=True); return
    await db_activate_trial(call.from_user.id)
    end = (datetime.utcnow() + timedelta(days=TRIAL_DAYS)).strftime("%d.%m.%Y")
    await call.message.edit_text(
        f"🎉 <b>Пробный период активирован!</b>\n\nДо: <b>{end}</b>\n\n"
        "Теперь подключи бота через Telegram Business чтобы ловить сообщения в личке!\n"
        "Инструкция: кнопка ❓ в главном меню.",
        reply_markup=kb_main()
    )
    await call.answer("✅ Активировано!")

# ── оплата ─────────────────────────────────────────────────

@router.callback_query(F.data == "buy_sub")
async def cb_buy(call: CallbackQuery, bot: Bot):
    await bot.send_invoice(
        chat_id=call.from_user.id,
        title=f"⭐ Подписка SpyBot — {SUB_DAYS} дней",
        description=f"Перехват удалённых и изменённых сообщений на {SUB_DAYS} дней.",
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
    await message.answer(
        f"✅ <b>Подписка активирована!</b>\nДо: <b>{until.strftime('%d.%m.%Y')}</b>\n\n"
        "Подключи бота через Telegram Business чтобы ловить личку — инструкция в меню ❓",
        reply_markup=kb_main()
    )
    log.info(f"Payment OK: user={message.from_user.id} until={until}")

# ══════════════════════════════════════════════════════════
#  TELEGRAM BUSINESS API — ЛИЧКА
# ══════════════════════════════════════════════════════════

@router.business_connection()
async def on_business_connection(update: BusinessConnection, bot: Bot):
    """Пользователь подключил/отключил бота через Telegram Business."""
    if update.is_enabled:
        await db_save_bc(update.id, update.user.id)
        log.info(f"Business connected: user={update.user.id} bc_id={update.id}")
        try:
            active = await is_subscribed(update.user.id)
            if active:
                await bot.send_message(
                    update.user.id,
                    "✅ <b>Telegram Business подключён!</b>\n\n"
                    "Теперь ловлю в твоей личке:\n"
                    "🗑 Удалённые сообщения собеседников\n"
                    "✏️ Изменённые сообщения собеседников\n\n"
                    "Всё перехваченное приходит сюда в ЛС."
                )
            else:
                await bot.send_message(
                    update.user.id,
                    "⚠️ Telegram Business подключён, но подписка не активна.\n"
                    "Активируй пробный период или купи подписку:",
                    reply_markup=kb_sub()
                )
        except Exception as e:
            log.warning(f"Could not notify user {update.user.id}: {e}")
    else:
        await db_deactivate_bc(update.id)
        log.info(f"Business disconnected: user={update.user.id}")

@router.business_message()
async def on_business_message(message: Message):
    """Новое сообщение в личке бизнес-аккаунта — кешируем."""
    owner_id = await db_get_bc_owner(message.business_connection_id)
    if not owner_id or not await is_subscribed(owner_id):
        return
    await db_cache(message)

@router.edited_business_message()
async def on_edited_business_message(message: Message, bot: Bot):
    """Собеседник изменил сообщение в личке."""
    owner_id = await db_get_bc_owner(message.business_connection_id)
    if not owner_id or not await is_subscribed(owner_id):
        return

    old = await db_get_cached(message.chat.id, message.message_id)
    old_text = (old.get("text") or "[медиа]") if old else "[нет в кеше]"
    new_text = message.text or message.caption or "[медиа]"
    sender = message.from_user.full_name if message.from_user else "Аноним"
    chat_title = (getattr(message.chat, "first_name", None) or
                  getattr(message.chat, "title", None) or "Личка")

    await notify_edited(bot, owner_id, f"Личка: {chat_title}", sender, old_text, new_text)
    await db_cache(message)

@router.deleted_business_messages()
async def on_deleted_business_messages(event: BusinessMessagesDeleted, bot: Bot):
    """Собеседник удалил сообщения в личке — главная фича!"""
    owner_id = await db_get_bc_owner(event.business_connection_id)
    if not owner_id or not await is_subscribed(owner_id):
        return

    chat_id = event.chat.id
    chat_name = (getattr(event.chat, "first_name", None) or
                 getattr(event.chat, "title", None) or str(chat_id))

    for msg_id in event.message_ids:
        cached = await db_get_cached(chat_id, msg_id)
        if cached:
            await notify_deleted(bot, owner_id, cached)
            await db_del_cached(chat_id, msg_id)
        else:
            # Сообщение не было закешировано (отправлено до подключения бота)
            try:
                await bot.send_message(
                    owner_id,
                    f"🗑 <b>Удалено в личке</b>\n"
                    f"💬 Собеседник: <b>{chat_name}</b>\n\n"
                    f"⚠️ Не удалось восстановить — сообщение было отправлено "
                    f"до подключения бота."
                )
            except Exception as e:
                log.warning(f"notify failed: {e}")

# ══════════════════════════════════════════════════════════
#  ГРУППЫ
# ══════════════════════════════════════════════════════════

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
    await bot.send_message(adder,
        f"✅ Бот добавлен в группу <b>{chat.title}</b>!\n"
        "Буду ловить удалённые и изменённые сообщения.",
        reply_markup=kb_main())
    log.info(f"Bot added to {chat.id} by {adder}")

@router.my_chat_member(ChatMemberUpdatedFilter(member_status_changed=KICKED))
async def bot_removed(event: ChatMemberUpdated):
    await db_remove_chat(event.chat.id)

@router.message(F.chat.type.in_({"group", "supergroup", "channel"}))
async def cache_group_message(message: Message):
    """Кешируем сообщения в группах."""
    owners = await active_owners(message.chat.id)
    if not owners:
        return
    await db_cache(message)

@router.edited_message(F.chat.type.in_({"group", "supergroup", "channel"}))
async def edited_group_message(message: Message):
    """Изменённые сообщения в группах."""
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
    await db_cache(message)

# ══════════════════════════════════════════════════════════
#  АДМИН
# ══════════════════════════════════════════════════════════

@router.message(Command("admin"), F.from_user.id == ADMIN_ID)
async def cmd_admin(message: Message):
    s = await db_stats()
    await message.answer(
        f"🔧 <b>Администратор</b>\n\n"
        f"👥 Пользователей: <b>{s['users']}</b>\n"
        f"💬 Групп: <b>{s['chats']}</b>\n"
        f"📦 Кешировано: <b>{s['cached']}</b>\n"
        f"✅ Подписок: <b>{s['subs']}</b>\n"
        f"🎁 Триалов: <b>{s['trials']}</b>\n"
        f"🏢 Business подключений: <b>{s['business']}</b>"
    )

@router.message(Command("broadcast"), F.from_user.id == ADMIN_ID)
async def cmd_broadcast(message: Message, bot: Bot):
    text = message.text.replace("/broadcast", "").strip()
    if not text:
        await message.answer("Использование: /broadcast Текст"); return
    users = await db_all_ids()
    ok = fail = 0
    for uid in users:
        try:
            await bot.send_message(uid, text); ok += 1
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

    print("\n" + "="*50)
    print("  ✅ SpyBot запущен!")
    print("  🏢 Режим: Telegram Business API")
    print(f"  🗄  База данных: {DB_PATH}")
    print("  💬 Напиши боту /start в Telegram")
    print("="*50 + "\n")

    await dp.start_polling(
        bot,
        allowed_updates=[
            "message", "edited_message", "callback_query",
            "my_chat_member", "pre_checkout_query",
            "business_connection", "business_message",
            "edited_business_message", "deleted_business_messages",
        ]
    )

if __name__ == "__main__":
    errors = []
    if not BOT_TOKEN or "СЮДА" in BOT_TOKEN:
        errors.append("  BOT_TOKEN — токен от @BotFather")
    if not ADMIN_ID:
        errors.append("  ADMIN_ID  — твой Telegram ID (узнай у @userinfobot)")
    if errors:
        print("\n" + "="*50)
        print("  SpyBot: заполни настройки в bot.py!")
        print("="*50)
        for e in errors: print(e)
        print("="*50 + "\n")
        sys.exit(0)
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log.info("Остановлен")
