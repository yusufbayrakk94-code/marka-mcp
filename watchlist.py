# -*- coding: utf-8 -*-
"""
Watchlist / Bulletin Tracking Module
"""

import hashlib
import json
import os
import time
import uuid
from typing import Any, Optional

STORE_PATH = os.getenv(
    "WATCHLIST_STORE_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "watchlist.json"),
)

ID_CANDIDATE_KEYS = [
    "applicationNumber", "applicationNo", "fileId", "id",
    "registrationNo", "registrationNumber", "applicationId",
]


def _ensure_store() -> None:
    os.makedirs(os.path.dirname(STORE_PATH), exist_ok=True)
    if not os.path.exists(STORE_PATH):
        with open(STORE_PATH, "w", encoding="utf-8") as f:
            json.dump({}, f)


def load_watches() -> dict:
    _ensure_store()
    with open(STORE_PATH, "r", encoding="utf-8") as f:
        try:
            return json.load(f)
        except json.JSONDecodeError:
            return {}


def save_watches(data: dict) -> None:
    _ensure_store()
    with open(STORE_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def extract_item_id(item: dict) -> str:
    for key in ID_CANDIDATE_KEYS:
        value = item.get(key)
        if value:
            return str(value)
    raw = json.dumps(item, sort_keys=True, default=str, ensure_ascii=False)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]


def create_watch(watch_type: str, label: str, query_params: dict) -> dict:
    watches = load_watches()
    watch_id = uuid.uuid4().hex[:8]
    watches[watch_id] = {
        "id": watch_id,
        "type": watch_type,
        "label": label,
        "params": query_params,
        "known_ids": [],
        "created_at": time.time(),
        "last_checked_at": None,
        "last_new_count": 0,
    }
    save_watches(watches)
    return watches[watch_id]


def list_watches() -> list:
    return list(load_watches().values())


def get_watch(watch_id: str) -> Optional[dict]:
    return load_watches().get(watch_id)


def delete_watch(watch_id: str) -> bool:
    watches = load_watches()
    if watch_id in watches:
        del watches[watch_id]
        save_watches(watches)
        return True
    return False


def update_watch_state(watch_id: str, current_ids: list) -> list:
    watches = load_watches()
    if watch_id not in watches:
        raise KeyError(f"Watch not found: {watch_id}")

    watch = watches[watch_id]
    known = set(watch.get("known_ids", []))
    current = set(current_ids)
    is_first_check = len(known) == 0 and watch.get("last_checked_at") is None

    new_ids = [] if is_first_check else list(current - known)

    watch["known_ids"] = list(current | known)
    watch["last_checked_at"] = time.time()
    watch["last_new_count"] = len(new_ids)
    watches[watch_id] = watch
    save_watches(watches)
    return new_ids
