# -*- coding: utf-8 -*-
"""
TURKPATENT API Core Module (Extended)
---------------------------------------
Handles reCAPTCHA token resolution via Capsolver, API calls to
turkpatent.gov.tr/api/research, in-memory caching, batch queries,
and bulletin watch tracking.

Bu dosya saidsurucu/markapatent-mcp projesinin core.py dosyasının
genişletilmiş bir versiyonudur. Eklenenler:
  - Marka aramasında bulletin_no filtresi
  - Patent aramasında bulletin_date_from / bulletin_date_to (tarih aralığı)
  - Tasarım aramasında bulletin_no filtresi
  - Toplu (batch) arama fonksiyonları
  - Bülten/duyuru takibi (watchlist) fonksiyonları
"""

import asyncio
import hashlib
import json
import os
import sys
from typing import Any, Optional

import httpx
from cachetools import TTLCache

import watchlist

# --- Configuration ---
CAPSOLVER_API_KEY = os.getenv("CAPSOLVER_API_KEY", "")
CAPSOLVER_CREATE_TASK_URL = "https://api.capsolver.com/createTask"
CAPSOLVER_GET_RESULT_URL = "https://api.capsolver.com/getTaskResult"
RECAPTCHA_SITE_KEY = "6LcsCTYhAAAAAJBX4xh-BMzLJfwxfhri7KJPAxn3"
RECAPTCHA_PAGE_URL = "https://www.turkpatent.gov.tr/arastirma-yap"
API_URL = "https://www.turkpatent.gov.tr/api/research"
HEADERS = {
    "Content-Type": "application/json",
    "Origin": "https://www.turkpatent.gov.tr",
    "Referer": "https://www.turkpatent.gov.tr/arastirma-yap",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
}

# --- Caching ---
search_cache: TTLCache = TTLCache(maxsize=100, ttl=600)  # 10 min
detail_cache: TTLCache = TTLCache(maxsize=500, ttl=3600)  # 1 hour

# Batch sorgularda eş zamanlı istek sayısını sınırlamak için (reCAPTCHA/Capsolver
# maliyetini ve TURKPATENT sunucusuna yükü kontrol altında tutar).
BATCH_CONCURRENCY = int(os.getenv("BATCH_CONCURRENCY", "3"))


def _cache_key(type_: str, params: dict, next_: int, limit: int) -> str:
    """Generate a deterministic cache key from request parameters."""
    raw = json.dumps({"type": type_, "params": params, "next": next_, "limit": limit}, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()


# --- reCAPTCHA Token Resolution ---

async def get_recaptcha_token() -> str:
    """Solve reCAPTCHA v3 via capsolver API (action: research_form)."""
    if not CAPSOLVER_API_KEY:
        raise RuntimeError("CAPSOLVER_API_KEY environment variable is not set")

    async with httpx.AsyncClient(timeout=120) as client:
        create_payload = {
            "clientKey": CAPSOLVER_API_KEY,
            "task": {
                "type": "ReCaptchaV3TaskProxyLess",
                "websiteURL": RECAPTCHA_PAGE_URL,
                "websiteKey": RECAPTCHA_SITE_KEY,
                "pageAction": "research_form",
                "minScore": 0.9,
            },
        }
        resp = await client.post(CAPSOLVER_CREATE_TASK_URL, json=create_payload)
        result = resp.json()
        if result.get("errorId") != 0:
            raise RuntimeError(f"Capsolver create task error: {result.get('errorDescription', result)}")
        task_id = result.get("taskId")
        print(f"Capsolver task created: {task_id}", file=sys.stderr)

        for _ in range(60):
            await asyncio.sleep(2)
            get_payload = {"clientKey": CAPSOLVER_API_KEY, "taskId": task_id}
            resp = await client.post(CAPSOLVER_GET_RESULT_URL, json=get_payload)
            result = resp.json()
            if result.get("status") == "ready":
                token = result.get("solution", {}).get("gRecaptchaResponse")
                if token:
                    print("Capsolver token received.", file=sys.stderr)
                    return token
                raise RuntimeError("Capsolver returned ready but no token")
            if result.get("status") == "failed":
                raise RuntimeError(f"Capsolver task failed: {result.get('errorDescription', result)}")
        raise RuntimeError("Capsolver timeout waiting for token")


# --- API Client ---

async def call_research_api(
    type_: str,
    params: dict,
    next_: int = 0,
    limit: int = 20,
    order: Optional[dict] = None,
    max_retries: int = 5,
) -> dict:
    """Call turkpatent.gov.tr/api/research with reCAPTCHA token.

    Retries with a fresh token on INVALID_CREDENTIALS (v3 score too low).
    """
    last_error = None
    for attempt in range(1, max_retries + 1):
        token = await get_recaptcha_token()
        body = {
            "type": type_,
            "params": params,
            "next": next_,
            "limit": limit,
            "order": order,
            "token": token,
        }
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(API_URL, json=body, headers=HEADERS)

            if response.status_code == 500:
                data = response.json()
                error_code = data.get("error", {}).get("code", "")
                if error_code == "INVALID_CREDENTIALS" and attempt < max_retries:
                    print(f"INVALID_CREDENTIALS (attempt {attempt}/{max_retries}), retrying with new token...", file=sys.stderr)
                    last_error = data
                    await asyncio.sleep(1)
                    continue

            response.raise_for_status()
            data = response.json()
            if not data.get("success"):
                raise RuntimeError(f"API returned success=false: {data}")
            return data

    raise RuntimeError(f"API failed after {max_retries} retries: {last_error}")


# --- Trademark Functions ---

SEARCH_TEXT_OPTION_MAP = {
    "contains": "isContains",
    "startsWith": "isStartWith",
    "equals": "isEqual",
}

HOLDER_NAME_OPTION_MAP = {
    "startsWith": "isStartWith",
    "equals": "isEqual",
}


async def search_trademarks_core(
    trademark_name: str = "",
    name_operator: str = "contains",
    holder_name: Optional[str] = None,
    holder_name_operator: str = "startsWith",
    nice_classes: Optional[str] = None,
    bulletin_no: Optional[str] = None,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """Search trademarks on TURKPATENT.

    bulletin_no: Belirli bir Resmi Marka Bülteni numarasına göre filtreler
        (örn. yeni başvuruları belirli bir bültenle sınırlamak için).
    """
    cache_key = _cache_key("trademark", {
        "searchText": trademark_name,
        "searchTextOption": name_operator,
        "holderName": holder_name or "",
        "holderNameOption": holder_name_operator,
        "niceClasses": nice_classes or "",
        "bulletinNo": bulletin_no or "",
    }, offset, limit)

    cached = search_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: trademark search", file=sys.stderr)
        return cached

    params = {
        "markTypeId": "0",
        "searchText": trademark_name,
        "searchTextOption": SEARCH_TEXT_OPTION_MAP.get(name_operator, "isContains"),
        "holderName": holder_name or "",
        "holderNameOption": HOLDER_NAME_OPTION_MAP.get(holder_name_operator, "isStartWith"),
        "bulletinNo": bulletin_no or "",
        "gazzetteNo": "",
        "clientNo": "",
        "niceClasses": nice_classes or "",
        "niceClassesFor": "selected" if nice_classes else "all",
    }

    data = await call_research_api("trademark", params, next_=offset, limit=limit)
    payload = data.get("payload", {})
    result = _format_search_result(payload)
    search_cache[cache_key] = result
    return result


async def get_trademark_detail_core(application_number: str) -> dict:
    """Get trademark details by application number."""
    cache_key = f"trademark-file:{application_number}"
    cached = detail_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: trademark detail", file=sys.stderr)
        return cached

    params = {"id": application_number}
    data = await call_research_api("trademark-file", params)
    payload = data.get("payload", {})
    item = payload.get("item", {})
    _strip_base64(item)
    detail_cache[cache_key] = item
    return item


async def batch_search_trademarks_core(
    trademark_names: list,
    name_operator: str = "contains",
    holder_name: Optional[str] = None,
    holder_name_operator: str = "startsWith",
    nice_classes: Optional[str] = None,
    bulletin_no: Optional[str] = None,
    limit: int = 10,
) -> dict:
    """Birden fazla marka adını eş zamanlı (sınırlı concurrency ile) arar.

    Returns: {trademark_name: search_result_dict, ...}
    """
    semaphore = asyncio.Semaphore(BATCH_CONCURRENCY)

    async def _one(name: str):
        async with semaphore:
            try:
                return name, await search_trademarks_core(
                    trademark_name=name,
                    name_operator=name_operator,
                    holder_name=holder_name,
                    holder_name_operator=holder_name_operator,
                    nice_classes=nice_classes,
                    bulletin_no=bulletin_no,
                    limit=limit,
                    offset=0,
                )
            except Exception as e:
                return name, {"error": str(e), "total": 0, "items": []}

    pairs = await asyncio.gather(*[_one(n) for n in trademark_names])
    return {name: result for name, result in pairs}


# --- Patent Functions ---

async def search_patents_core(
    title: str = "",
    abstract: Optional[str] = None,
    owner: Optional[str] = None,
    applicant: Optional[str] = None,
    application_number: Optional[str] = None,
    ipc_class: Optional[str] = None,
    cpc_class: Optional[str] = None,
    attorney: Optional[str] = None,
    bulletin_date_from: Optional[str] = None,
    bulletin_date_to: Optional[str] = None,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """Search patents on TURKPATENT.

    bulletin_date_from / bulletin_date_to: "YYYY-MM-DD" formatında tarih
        aralığı (Bülten tarihine göre filtreler). API'nin orijinal alanları
        bulletinDate / bulletinDateLast üzerinden gönderilir.
    """
    params: dict[str, Any] = {
        "title": title,
        "abstracttr": abstract or "",
        "inventionOwner": owner or "",
        "applicationOwner": applicant or "",
        "applicationNumber": application_number or "",
        "epcApplicationNumber": "",
        "pctApplicationNumber": "",
        "epcBulletinNumber": "",
        "priorityNumber": "",
        "pctBulletinNumber": "",
        "ipcType": ipc_class or "",
        "cpcType": cpc_class or "",
        "bulletinDate": bulletin_date_from,
        "bulletinDateLast": bulletin_date_to,
        "attorney": attorney or "",
    }

    cache_key = _cache_key("patent", params, offset, limit)
    cached = search_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: patent search", file=sys.stderr)
        return cached

    data = await call_research_api("patent", params, next_=offset, limit=limit)
    payload = data.get("payload", {})
    result = _format_search_result(payload)
    search_cache[cache_key] = result
    return result


async def get_patent_detail_core(application_number: str) -> dict:
    """Get patent details by application number."""
    cache_key = f"patent-file:{application_number}"
    cached = detail_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: patent detail", file=sys.stderr)
        return cached

    params = {"id": application_number}
    data = await call_research_api("patent-file", params)
    payload = data.get("payload", {})
    item = payload.get("item", {})
    _strip_base64(item)
    detail_cache[cache_key] = item
    return item


async def batch_search_patents_core(
    titles: list,
    limit: int = 10,
    **extra_filters,
) -> dict:
    """Birden fazla patent başlığını eş zamanlı arar. Returns: {title: result}."""
    semaphore = asyncio.Semaphore(BATCH_CONCURRENCY)

    async def _one(title: str):
        async with semaphore:
            try:
                return title, await search_patents_core(title=title, limit=limit, offset=0, **extra_filters)
            except Exception as e:
                return title, {"error": str(e), "total": 0, "items": []}

    pairs = await asyncio.gather(*[_one(t) for t in titles])
    return {title: result for title, result in pairs}


# --- Design Functions ---

async def search_designs_core(
    design_name: str = "",
    designer: Optional[str] = None,
    applicant: Optional[str] = None,
    registration_no: Optional[str] = None,
    locarno_class: Optional[str] = None,
    attorney: Optional[str] = None,
    bulletin_no: Optional[str] = None,
    limit: int = 20,
    offset: int = 0,
) -> dict:
    """Search designs on TURKPATENT.

    bulletin_no: Belirli bir Resmi Tasarım Bülteni numarasına göre filtreler.
    """
    params: dict[str, Any] = {
        "designName": design_name,
        "designerName": designer or "",
        "holderTitle": applicant or "",
        "registrationNo": registration_no or "",
        "locarno": locarno_class or "",
        "bulletin": bulletin_no or "",
        "attorney": attorney or "",
    }

    cache_key = _cache_key("design", params, offset, limit)
    cached = search_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: design search", file=sys.stderr)
        return cached

    data = await call_research_api("design", params, next_=offset, limit=limit)
    payload = data.get("payload", {})
    result = _format_search_result(payload)
    search_cache[cache_key] = result
    return result


async def get_design_detail_core(file_id: str) -> dict:
    """Get design details by file ID (from search results)."""
    cache_key = f"design-file:{file_id}"
    cached = detail_cache.get(cache_key)
    if cached is not None:
        print("Cache HIT: design detail", file=sys.stderr)
        return cached

    params = {"id": file_id}
    data = await call_research_api("design-file", params)
    payload = data.get("payload", {})
    item = payload.get("item", {})
    _strip_base64(item)
    detail_cache[cache_key] = item
    return item


# --- Watchlist (Bülten / Duyuru Takibi) ---

_SEARCH_FN_MAP = {
    "trademark": search_trademarks_core,
    "patent": search_patents_core,
    "design": search_designs_core,
}


def create_watch_core(watch_type: str, label: str, query_params: dict) -> dict:
    """Yeni bir takip kaydı oluşturur. watch_type: trademark|patent|design."""
    if watch_type not in _SEARCH_FN_MAP:
        raise ValueError(f"Unknown watch_type: {watch_type}")
    return watchlist.create_watch(watch_type, label, query_params)


def list_watches_core() -> list:
    return watchlist.list_watches()


def delete_watch_core(watch_id: str) -> bool:
    return watchlist.delete_watch(watch_id)


async def check_watch_core(watch_id: str, scan_limit: int = 50) -> dict:
    """Bir takibi çalıştırır, son kontrolden bu yana YENİ çıkan kayıtları bulur.

    Not: scan_limit ile sınırlı sayıda sonuç taranır (varsayılan 50). Çok
    geniş sorgularda (örn. boş isim + binlerce sonuç) tüm yeni kayıtları
    yakalamak için scan_limit artırılabilir, ancak bu daha fazla
    reCAPTCHA/Capsolver maliyeti demektir.
    """
    watch = watchlist.get_watch(watch_id)
    if not watch:
        raise KeyError(f"Watch not found: {watch_id}")

    search_fn = _SEARCH_FN_MAP[watch["type"]]
    result = await search_fn(limit=scan_limit, offset=0, **watch["params"])
    items = result.get("items", [])
    current_ids = [watchlist.extract_item_id(it) for it in items]
    new_ids = watchlist.update_watch_state(watch_id, current_ids)
    id_set = set(new_ids)
    new_items = [it for it in items if watchlist.extract_item_id(it) in id_set]

    return {
        "watch_id": watch_id,
        "label": watch["label"],
        "type": watch["type"],
        "checked_total": result.get("total", 0),
        "new_count": len(new_items),
        "new_items": new_items,
        "fields": result.get("fields", []),
    }


async def check_all_watches_core() -> list:
    """Tüm kayıtlı takipleri sırayla kontrol eder (rate-limit dostu)."""
    results = []
    for watch in watchlist.list_watches():
        try:
            results.append(await check_watch_core(watch["id"]))
        except Exception as e:
            results.append({"watch_id": watch["id"], "label": watch.get("label"), "error": str(e)})
    return results


# --- Helpers ---

def _strip_base64(obj: Any) -> None:
    """Recursively remove base64-encoded image data from API responses."""
    if isinstance(obj, dict):
        for key, value in list(obj.items()):
            if isinstance(value, str) and len(value) > 500 and (
                value.startswith("data:image") or value.startswith("/9j/") or value.startswith("iVBOR")
            ):
                obj[key] = "[base64 image data omitted]"
            elif key in ("figure", "data") and isinstance(value, str) and len(value) > 500:
                obj[key] = "[base64 image data omitted]"
            else:
                _strip_base64(value)
    elif isinstance(obj, list):
        for item in obj:
            _strip_base64(item)


def _format_search_result(payload: dict) -> dict:
    """Format API search payload into a clean result dict."""
    items = payload.get("items", [])
    for item in items:
        if isinstance(item.get("image"), dict) and item["image"].get("data"):
            item["image"]["data"] = "[base64 omitted]"
    return {
        "total": payload.get("total", len(items)),
        "items": items,
        "fields": payload.get("fields", []),
    }
