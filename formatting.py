# -*- coding: utf-8 -*-
"""
Markdown Formatting Helpers
-----------------------------
TURKPATENT API'sinin döndürdüğü item şeması dokümante edilmediği için bu
modül "şema bağımsız" çalışır: mümkünse API'nin verdiği `fields` meta verisini
kullanır, yoksa ilk sonucun anahtarlarından otomatik kolon türetir.
"""

from typing import Any, Optional

MAX_COLUMNS = 6
MAX_CELL_LEN = 60


def _pick_columns(items: list, fields: Optional[list]) -> list:
    """[(key, label), ...] biçiminde gösterilecek kolonları belirler."""
    if fields:
        cols = []
        for f in fields:
            if isinstance(f, dict):
                key = f.get("field") or f.get("name") or f.get("key") or f.get("id")
                label = f.get("label") or f.get("title") or f.get("header") or key
            else:
                key = label = str(f)
            if key:
                cols.append((key, label))
        if cols:
            return cols[:MAX_COLUMNS]

    if items:
        cols = []
        for k, v in items[0].items():
            if isinstance(v, (dict, list)):
                continue
            cols.append((k, k))
        return cols[:MAX_COLUMNS]

    return []


def _cell(value: Any) -> str:
    if value is None or value == "":
        return "-"
    text = str(value).replace("|", "/").replace("\n", " ").strip()
    if len(text) > MAX_CELL_LEN:
        text = text[: MAX_CELL_LEN - 1] + "…"
    return text


def format_search_result_as_markdown(result: dict, title: str = "Arama Sonuçları") -> str:
    """Bir search_*_core() çıktısını Markdown tabloya çevirir."""
    items = result.get("items", [])
    total = result.get("total", len(items))
    fields = result.get("fields", [])

    lines = [f"### {title}", f"**Toplam:** {total} | **Bu sayfada:** {len(items)}", ""]

    if "error" in result:
        lines.append(f"⚠️ **Hata:** {result['error']}")
        return "\n".join(lines)

    if not items:
        lines.append("_Sonuç bulunamadı._")
        return "\n".join(lines)

    cols = _pick_columns(items, fields)
    if not cols:
        lines.append("_Sonuçlar gösterilemedi (alan bilgisi çözümlenemedi, output_format='json' deneyin)._")
        return "\n".join(lines)

    header = " | ".join(label for _, label in cols)
    sep = " | ".join("---" for _ in cols)
    lines.append(f"| {header} |")
    lines.append(f"| {sep} |")
    for item in items:
        row = [_cell(item.get(key)) for key, _ in cols]
        lines.append("| " + " | ".join(row) + " |")

    return "\n".join(lines)


def format_batch_results_as_markdown(results: dict, title: str = "Toplu Arama Sonuçları") -> str:
    """batch_search_*_core() çıktısını (query -> result dict) Markdown'a çevirir."""
    sections = [f"## {title}", ""]
    for query, result in results.items():
        sections.append(format_search_result_as_markdown(result, title=f"'{query}'"))
        sections.append("")
    return "\n".join(sections)


def format_watch_check_as_markdown(check_result: dict) -> str:
    """check_watch_core() çıktısını Markdown'a çevirir."""
    lines = [
        f"### 🔔 Takip: {check_result.get('label', check_result.get('watch_id'))}",
        f"**Tarandı:** {check_result.get('checked_total', 0)} sonuç | "
        f"**Yeni:** {check_result.get('new_count', 0)}",
        "",
    ]
    new_items = check_result.get("new_items", [])
    if not new_items:
        lines.append("_Son kontrolden bu yana yeni başvuru yok._")
        return "\n".join(lines)

    fake_result = {"items": new_items, "total": len(new_items), "fields": check_result.get("fields", [])}
    lines.append(format_search_result_as_markdown(fake_result, title="Yeni Başvurular"))
    return "\n".join(lines)
