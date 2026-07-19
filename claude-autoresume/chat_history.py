"""
chat_history.py — read Claude Desktop's local chat history out of its
IndexedDB / LevelDB cache.

This is reverse-engineered internals with NO stability guarantee across
Claude Desktop releases. Two rules this module always follows:

  1. It NEVER opens the live LevelDB directory in place. Claude.app may hold
     an open handle / lock on it, and writing anything there (even
     accidentally, even read-only-looking operations from a buggy library)
     risks corrupting a user's real chat history. Every entry point copies
     the leveldb dir (and its sibling ".blob" dir, if present) to a fresh
     temp directory first, and only ever opens the copy.
  2. The on-disk schema (database names, object store names, record shapes)
     is discovered at runtime, never hardcoded. See detect_schema().

Background on the format, learned by direct inspection of a real profile
(Claude Desktop, July 2026 build) -- kept here because it is NOT documented
anywhere and the upstream `ccl_chromium_reader` library does not fully
implement it:

  * IndexedDB stores each record's value LevelDB-compressed (transparently
    handled by the ccl_leveldb reader) wrapped in a Blink envelope:
        [0xFF][blink_version:varint][...]
    Immediately after the version varint there is a one-byte marker:
        0x01  -> "kReplaceWithBlob": the real value was moved out to an
                 external blob file (too big to store inline). Followed by
                 [blob_size:varint][blob_index:varint]; the blob file itself
                 must be located via a *separate* family of LevelDB records
                 (index/prefix 3, "blob metadata") keyed by the same record
                 key.
        anything else -> value is inline; if blink_version >= 21 a 13-byte
                 trailer follows (offset+length), then the raw V8-serialized
                 payload.
    ccl_chromium_reader implements the above correctly for *inline* values.

  * What it gets wrong: once you resolve a "kReplaceWithBlob" pointer to an
    actual blob file on disk, that file's content is ALSO wrapped in a
    Blink envelope ([0xFF][blink_version][marker byte]) -- but the marker
    byte there can be 0x02, which means "the rest of this file is
    Snappy-compressed; decompress it, and *that* yields another
    [0xFF][blink_version][...13-byte trailer...][V8 payload]". This
    second-layer application-level Snappy compression (distinct from
    LevelDB's own block compression, which the library does handle) is not
    implemented anywhere in ccl_chromium_reader. This module implements it
    itself (see _parse_wrapped_value).

  * What else it gets wrong: `IndexedDb.get_blob_info()` resolves a blob
    pointer to a blob_number by scanning ALL historical "blob metadata"
    records for a key and simply keeping whichever one it saw *last* while
    iterating -- not the one with the highest LevelDB sequence number. For
    a key that gets rewritten often (e.g. a persisted query cache, rewritten
    every ~30s), this reliably resolves to a stale, already-deleted blob
    file. This module rebuilds that mapping itself, keyed by highest
    sequence number among live records (see _resolve_blob_number).

Given both of the above, this module does its own record resolution
(picking the highest-seq *live* version of each key, i.e. a point-in-time
reconstruction of the object store) and its own envelope parsing, reusing
ccl_chromium_reader only for the pieces it gets right: LevelDB block
reading/decompression, the V8 structured-clone deserializer, and IdbKey
parsing.

IMPORTANT FINDING (as of the profile this was developed against): the
persisted TanStack Query cache in `keyval-store` DOES include queries named
like "chat_conversation_list", but their cached `data` is *empty*
(`{"data": [], "has_more": false}`) -- while other queries in the exact same
cache blob (e.g. "current_account") DO carry real persisted data. This
looks like a deliberate exclusion (a `shouldDehydrateQuery`-style filter)
rather than a decode failure: Claude Desktop does not appear to persist
actual conversation/message content to this local cache. The only
genuinely recoverable "chat" content found was per-session *draft* text
(unsent composer state, `store:chat-draft:<sessionId>` keys) and pinned/
starred conversation IDs (no content). read_conversations() surfaces
whatever it can find, honestly labelled by source, and raises a clear
ChatHistoryError if nothing chat-shaped is found at all -- it does not
fabricate results.
"""

from __future__ import annotations

import dataclasses
import datetime
import io
import json
import pathlib
import shutil
import tempfile
import typing

try:
    import snappy  # python-snappy
except ImportError as _e:  # pragma: no cover
    snappy = None
    _SNAPPY_IMPORT_ERROR = _e

from ccl_chromium_reader.ccl_chromium_indexeddb import (
    WrappedIndexDB,
    IndexedDb,
    IdbKey,
    BlinkTrailer,
    IndexedDBExternalObject,
)
from ccl_chromium_reader.storage_formats import ccl_leveldb
from ccl_chromium_reader.serialization_formats import (
    ccl_v8_value_deserializer,
    ccl_blink_value_deserializer,
)


DEFAULT_LEVELDB_PATH = pathlib.Path(
    "~/Library/Application Support/Claude/IndexedDB/"
    "https_claude.ai_0.indexeddb.leveldb"
).expanduser()


class ChatHistoryError(Exception):
    """Raised for any expected/handled failure: unknown schema, no data
    found, missing dependency, etc. Callers should be able to catch this
    single type and get a human-readable message -- never a stack trace
    from deep inside the parsing internals."""


class _DecodeError(Exception):
    """Internal: raised while decoding a single record. Always caught and
    turned into a skip-this-record, never allowed to propagate out of
    read_conversations()/detect_schema()."""


# --------------------------------------------------------------------------
# Safe staging: never open the live directory
# --------------------------------------------------------------------------

@dataclasses.dataclass
class _StagedCopy:
    leveldb_dir: str
    blob_dir: typing.Optional[str]
    _tmp_root: str

    def cleanup(self) -> None:
        shutil.rmtree(self._tmp_root, ignore_errors=True)


def _infer_blob_dir(leveldb_path: pathlib.Path) -> typing.Optional[pathlib.Path]:
    """Chrome/Electron IndexedDB origins keep large ("wrapped") values in a
    sibling '<origin>.indexeddb.blob' directory next to
    '<origin>.indexeddb.leveldb'. Infer it by name; caller can override."""
    name = leveldb_path.name
    suffix = ".indexeddb.leveldb"
    if name.endswith(suffix):
        candidate = leveldb_path.parent / (name[: -len(suffix)] + ".indexeddb.blob")
        if candidate.exists():
            return candidate
    return None


def _stage_copy(
    path: "str | pathlib.Path",
    blob_path: "str | pathlib.Path | None" = None,
    scratch_root: "str | pathlib.Path | None" = None,
) -> _StagedCopy:
    """Copy the leveldb directory (and blob directory, if any) to a fresh
    temp directory and return paths to the COPY. Never touches/opens the
    original. This is called internally by every public entry point --
    callers do not need to (and should not try to) do this themselves."""
    src = pathlib.Path(path).expanduser()
    if not src.exists():
        raise ChatHistoryError(f"leveldb path does not exist: {src}")
    if not src.is_dir():
        raise ChatHistoryError(f"leveldb path is not a directory: {src}")

    if blob_path is None:
        blob_src = _infer_blob_dir(src)
    else:
        blob_src = pathlib.Path(blob_path).expanduser()
        if not blob_src.exists():
            blob_src = None

    tmp_root = tempfile.mkdtemp(
        prefix="claude_chat_history_",
        dir=str(scratch_root) if scratch_root else None,
    )
    try:
        dest_leveldb = pathlib.Path(tmp_root) / "leveldb"
        shutil.copytree(src, dest_leveldb)
        dest_blob = None
        if blob_src is not None:
            dest_blob = pathlib.Path(tmp_root) / "blob"
            shutil.copytree(blob_src, dest_blob)
    except Exception as e:
        shutil.rmtree(tmp_root, ignore_errors=True)
        raise ChatHistoryError(f"failed to stage a safe copy of {src}: {e}") from e

    return _StagedCopy(
        leveldb_dir=str(dest_leveldb),
        blob_dir=str(dest_blob) if dest_blob else None,
        _tmp_root=tmp_root,
    )


# --------------------------------------------------------------------------
# Low-level varint helper (reimplemented locally rather than reaching into
# the library's underscore-prefixed internals)
# --------------------------------------------------------------------------

def _read_varint(buf: bytes) -> typing.Tuple[int, int]:
    """LevelDB/Blink-style little-endian base-128 varint. Returns
    (value, bytes_consumed)."""
    value = 0
    shift = 0
    for i, b in enumerate(buf):
        value |= (b & 0x7F) << shift
        if not (b & 0x80):
            return value, i + 1
        shift += 7
    raise _DecodeError("truncated varint")


# --------------------------------------------------------------------------
# Record resolution: point-in-time reconstruction of an object store
# --------------------------------------------------------------------------

def _latest_live_records(
    raw_db: IndexedDb, db_id: int, store_id: int
) -> typing.List[typing.Tuple["ccl_leveldb.Record", IdbKey]]:
    """Reimplements what WrappedObjectStore.iterate_records(live_only=True)
    claims to do but does not: LevelDB retains every historical version of
    a key until compaction, and the upstream live_only flag is a no-op (it
    is accepted but never consulted) as of the installed version. This scans
    every record for the store and keeps, per distinct key, only the
    highest-sequence-number version whose state is Live."""
    prefix = IndexedDb.make_prefix(db_id, store_id, 1)
    latest: typing.Dict[bytes, typing.Tuple["ccl_leveldb.Record", IdbKey]] = {}
    for record in raw_db._fetched_records:
        if not record.key.startswith(prefix):
            continue
        if record.state != ccl_leveldb.KeyState.Live:
            continue
        try:
            key = IdbKey(record.key[len(prefix):])
        except Exception:
            continue
        cur = latest.get(key.raw_key)
        if cur is None or record.seq > cur[0].seq:
            latest[key.raw_key] = (record, key)
    return list(latest.values())


def _resolve_blob_number(
    raw_db: IndexedDb, db_id: int, store_id: int, raw_key: bytes, file_index: int
) -> typing.Optional[int]:
    """Freshest blob_number for (raw_key, file_index), picking the highest
    seq among Live "blob metadata" (prefix 3) records -- unlike
    IndexedDb.get_blob_info(), which returns whichever one it encountered
    last while scanning and so silently resolves to deleted/superseded blob
    files for keys that get rewritten often."""
    prefix3 = IndexedDb.make_prefix(db_id, store_id, 3)
    best_seq = -1
    best_number = None
    for record in raw_db._fetched_records:
        if not record.user_key.startswith(prefix3):
            continue
        if record.state != ccl_leveldb.KeyState.Live:
            continue
        this_raw_key = record.user_key[len(prefix3):]
        if this_raw_key != raw_key:
            continue
        buff = io.BytesIO(record.value)
        idx = 0
        while buff.tell() < len(record.value):
            try:
                info = IndexedDBExternalObject.from_stream(buff)
            except Exception:
                break
            if idx == file_index and record.seq > best_seq:
                best_seq = record.seq
                best_number = info.blob_number
            idx += 1
    return best_number


def _read_blob_bytes(blob_dir: str, db_id: int, blob_number: int) -> bytes:
    path = pathlib.Path(blob_dir, f"{db_id:x}", f"{blob_number >> 8:02x}", f"{blob_number:x}")
    if not path.exists():
        raise _DecodeError(f"blob file missing on disk: {path}")
    return path.read_bytes()


def _parse_wrapped_value(
    raw_db: IndexedDb,
    db_id: int,
    store_id: int,
    key: IdbKey,
    buffer: bytes,
    blob_dir: typing.Optional[str],
    depth: int = 0,
) -> bytes:
    """Peel off Blink's value-wrapping envelope(s) and return the raw bytes
    ready for the V8 structured-clone deserializer. Handles both cases the
    upstream library gets wrong: blob-number resolution (see
    _resolve_blob_number) and second-layer Snappy compression of blob
    content (marker byte 0x02, undocumented, not implemented upstream)."""
    if depth > 6:
        raise _DecodeError("value-wrapping recursion too deep (corrupt data?)")
    if not buffer or buffer[0] != 0xFF:
        raise _DecodeError("missing Blink version tag (0xFF) at envelope start")

    blink_version, vlen = _read_varint(buffer[1:])
    idx = 1 + vlen
    if idx >= len(buffer):
        raise _DecodeError("truncated envelope after version varint")

    marker = buffer[idx]

    if marker == 0x01:
        # kReplaceWithBlob: value lives in an external blob file.
        idx += 1
        _blob_size, vlen = _read_varint(buffer[idx:])
        idx += vlen
        blob_index, vlen = _read_varint(buffer[idx:])
        idx += vlen

        if blob_dir is None:
            raise _DecodeError("value references an external blob but no blob dir is available")

        blob_number = _resolve_blob_number(raw_db, db_id, store_id, key.raw_key, blob_index)
        if blob_number is None:
            raise _DecodeError(
                "no live blob-metadata entry for this key/index "
                "(value was likely superseded or garbage-collected)"
            )
        blob_bytes = _read_blob_bytes(blob_dir, db_id, blob_number)
        return _parse_wrapped_value(raw_db, db_id, store_id, key, blob_bytes, blob_dir, depth + 1)

    if marker == 0x02:
        # Undocumented (not in upstream ccl_chromium_reader): rest of this
        # buffer is Snappy-compressed; decompressing yields another
        # [0xFF][blink_version][...] envelope.
        if snappy is None:
            raise _DecodeError(
                f"value is Snappy-compressed but the 'snappy' python module "
                f"is not available ({_SNAPPY_IMPORT_ERROR})"
            )
        idx += 1
        try:
            decompressed = snappy.decompress(bytes(buffer[idx:]))
        except Exception as e:
            raise _DecodeError(f"snappy decompression failed: {e}") from e
        return _parse_wrapped_value(raw_db, db_id, store_id, key, decompressed, blob_dir, depth + 1)

    # Not further wrapped: optional trailer, then the raw V8 payload.
    if blink_version >= BlinkTrailer.MIN_WIRE_FORMAT_VERSION_FOR_TRAILER:
        try:
            BlinkTrailer.from_buffer(buffer, idx)
        except Exception as e:
            raise _DecodeError(f"failed to parse Blink trailer: {e}") from e
        idx += BlinkTrailer.TRAILER_SIZE

    return buffer[idx:]


def _deserialize_v8(obj_bytes: bytes) -> typing.Any:
    blink_deserializer = ccl_blink_value_deserializer.BlinkV8Deserializer()
    try:
        deserializer = ccl_v8_value_deserializer.Deserializer(
            io.BytesIO(obj_bytes), host_object_delegate=blink_deserializer.read
        )
        return deserializer.read()
    except Exception as e:
        raise _DecodeError(f"V8 deserialization failed: {e}") from e


def _decode_record(
    raw_db: IndexedDb,
    db_id: int,
    store_id: int,
    key: IdbKey,
    raw_value: typing.Optional[bytes],
    blob_dir: typing.Optional[str],
) -> typing.Any:
    if not raw_value:
        return None
    _value_version, vlen = _read_varint(raw_value)
    obj_bytes = _parse_wrapped_value(raw_db, db_id, store_id, key, raw_value[vlen:], blob_dir)
    return _deserialize_v8(obj_bytes)


# --------------------------------------------------------------------------
# Public: schema discovery
# --------------------------------------------------------------------------

def detect_schema(
    path: "str | pathlib.Path" = DEFAULT_LEVELDB_PATH,
    blob_path: "str | pathlib.Path | None" = None,
    scratch_root: "str | pathlib.Path | None" = None,
) -> dict:
    """Enumerate database ids and object-store names found in the IndexedDB
    LevelDB store at `path`. Always works off a throwaway copy (see module
    docstring). The schema is NOT assumed stable across Claude Desktop
    updates -- this discovers it fresh every call rather than hardcoding
    names.

    Returns:
        {
          "origin": "https_claude.ai_0@1",
          "databases": [
            {"name": "keyval-store", "dbid_no": 1, "object_stores": ["keyval"]},
            ...
          ]
        }
    """
    staged = _stage_copy(path, blob_path, scratch_root)
    try:
        try:
            wdb = WrappedIndexDB(staged.leveldb_dir, staged.blob_dir)
        except Exception as e:
            raise ChatHistoryError(f"failed to open IndexedDB store: {e}") from e

        try:
            schema: dict = {"origin": None, "databases": []}
            try:
                db_ids = list(wdb.database_ids)
            except Exception as e:
                raise ChatHistoryError(f"failed to enumerate databases: {e}") from e

            if not db_ids:
                raise ChatHistoryError(
                    "no databases found in the IndexedDB store -- schema may "
                    "have changed, or the store is empty/corrupt"
                )

            for dbid in db_ids:
                try:
                    wrapped_db = wdb[dbid]
                    object_stores = list(wrapped_db.object_store_names)
                except Exception as e:
                    object_stores = []
                    schema.setdefault("errors", []).append(
                        f"failed to read object stores for db '{dbid.name}': {e}"
                    )
                schema["origin"] = dbid.origin
                schema["databases"].append(
                    {
                        "name": dbid.name,
                        "dbid_no": dbid.dbid_no,
                        "object_stores": object_stores,
                    }
                )
            return schema
        finally:
            wdb.close()
    finally:
        staged.cleanup()


# --------------------------------------------------------------------------
# Public: conversation extraction
# --------------------------------------------------------------------------

def _parse_ts(value: typing.Any) -> typing.Optional[str]:
    """Best-effort: most timestamps here are epoch-milliseconds floats."""
    if value is None:
        return None
    try:
        if isinstance(value, (int, float)):
            return datetime.datetime.fromtimestamp(
                value / 1000.0, tz=datetime.timezone.utc
            ).isoformat()
        if isinstance(value, datetime.datetime):
            return value.isoformat()
    except (ValueError, OSError, OverflowError):
        return None
    return None


def _ts_sort_key(iso_str: typing.Optional[str]) -> str:
    return iso_str or ""


def _extract_tiptap_text(node: typing.Any, chunks: typing.Optional[list] = None) -> str:
    """Walk a TipTap/ProseMirror editor-state doc and concatenate its text
    nodes -- this is how per-session chat drafts are stored."""
    if chunks is None:
        chunks = []
    if isinstance(node, dict):
        if node.get("type") == "text" and isinstance(node.get("text"), str):
            chunks.append(node["text"])
        for child in node.get("content") or []:
            _extract_tiptap_text(child, chunks)
    elif isinstance(node, list):
        for child in node:
            _extract_tiptap_text(child, chunks)
    return "".join(chunks)


def _extract_conversation_items(data: typing.Any) -> typing.List[dict]:
    """A cached query's `state.data` may be a plain list-shaped payload
    ({"data": [...]}) or a react-query "infinite query" shape
    ({"pages": [{"data": [...]}, ...]}). Normalize both to a flat list of
    conversation-ish dicts."""
    items: typing.List[dict] = []
    if not isinstance(data, dict):
        return items
    if isinstance(data.get("data"), list):
        items.extend(x for x in data["data"] if isinstance(x, dict))
    if isinstance(data.get("pages"), list):
        for page in data["pages"]:
            if isinstance(page, dict) and isinstance(page.get("data"), list):
                items.extend(x for x in page["data"] if isinstance(x, dict))
    return items


def _collect_candidates(out: list, key: IdbKey, value: typing.Any) -> None:
    if not isinstance(value, dict):
        return

    # Heuristic A: a persisted TanStack/react-query cache blob. Detected
    # structurally (clientState.queries), not by any hardcoded key name, so
    # this keeps working if the persistence key itself gets renamed.
    client_state = value.get("clientState")
    if isinstance(client_state, dict) and isinstance(client_state.get("queries"), list):
        for q in client_state["queries"]:
            if not isinstance(q, dict):
                continue
            query_key = q.get("queryKey")
            if not isinstance(query_key, (list, tuple)) or not query_key:
                continue
            name = str(query_key[0])
            if "conversation" not in name.lower():
                continue
            state = q.get("state") or {}
            for item in _extract_conversation_items(state.get("data")):
                out.append(
                    {
                        "source": "query_cache",
                        "kind": "conversation",
                        "title": item.get("name") or item.get("title") or "(untitled)",
                        "id": item.get("uuid") or item.get("id"),
                        "updated_at": _parse_ts(
                            item.get("updated_at") or item.get("updatedAt")
                        ),
                        "excerpt": None,
                        "raw_query_key": name,
                    }
                )

    # Heuristic B: a per-session chat draft (unsent composer text). Detected
    # structurally (a TipTap editor-state doc under `state`), not by the
    # literal "chat-draft" key prefix.
    state = value.get("state")
    if isinstance(state, dict) and isinstance(state.get("tipTapEditorState"), dict):
        text = _extract_tiptap_text(state["tipTapEditorState"]).strip()
        if text:
            session_id = getattr(key, "value", None) or str(key)
            out.append(
                {
                    "source": "draft",
                    "kind": "unsent_draft",
                    "title": f"(unsent draft, session {session_id})",
                    "id": session_id,
                    "updated_at": _parse_ts(value.get("updatedAt")),
                    "excerpt": text[:280],
                }
            )


def read_conversations(
    path: "str | pathlib.Path" = DEFAULT_LEVELDB_PATH,
    blob_path: "str | pathlib.Path | None" = None,
    limit: int = 5,
    scratch_root: "str | pathlib.Path | None" = None,
) -> typing.List[dict]:
    """Return up to `limit` decoded conversation-shaped records, most
    recent first, as plain Python dicts.

    Each item looks like:
        {
          "source": "query_cache" | "draft",
          "kind": "conversation" | "unsent_draft",
          "title": str,
          "id": str | None,
          "updated_at": iso8601 str | None,
          "excerpt": str | None,
        }

    Raises ChatHistoryError if the store can't be opened, no live records
    are found at all, or records decode fine but nothing chat-shaped turns
    up (this module does not fabricate results -- see the module docstring
    for what was actually found to be persisted, as of the profile this was
    developed against, versus what was not).
    """
    staged = _stage_copy(path, blob_path, scratch_root)
    try:
        try:
            wdb = WrappedIndexDB(staged.leveldb_dir, staged.blob_dir)
        except Exception as e:
            raise ChatHistoryError(f"failed to open IndexedDB store: {e}") from e

        try:
            try:
                db_ids = list(wdb.database_ids)
            except Exception as e:
                raise ChatHistoryError(f"failed to enumerate databases: {e}") from e

            total_live_records = 0
            total_decoded_dicts = 0
            candidates: list = []
            decode_errors: typing.List[str] = []

            for dbid in db_ids:
                try:
                    wrapped_db = wdb[dbid]
                except Exception:
                    continue
                raw_db = getattr(wrapped_db, "_raw_db", None)
                if raw_db is None:
                    continue

                for store in wrapped_db:
                    store_id = store.object_store_id
                    try:
                        records = _latest_live_records(raw_db, dbid.dbid_no, store_id)
                    except Exception as e:
                        decode_errors.append(
                            f"{dbid.name}/{store.name}: failed to enumerate records: {e}"
                        )
                        continue

                    total_live_records += len(records)
                    for record, key in records:
                        try:
                            value = _decode_record(
                                raw_db, dbid.dbid_no, store_id, key, record.value, staged.blob_dir
                            )
                        except _DecodeError as e:
                            decode_errors.append(f"{dbid.name}/{store.name}/{key}: {e}")
                            continue
                        except Exception as e:  # never let a single bad record kill the run
                            decode_errors.append(
                                f"{dbid.name}/{store.name}/{key}: unexpected decode error: {e}"
                            )
                            continue

                        if isinstance(value, dict):
                            total_decoded_dicts += 1
                            _collect_candidates(candidates, key, value)

            if total_live_records == 0:
                raise ChatHistoryError(
                    "no live records found in any object store -- the schema "
                    "may have changed, or this profile has no local chat cache yet"
                )

            if total_decoded_dicts == 0:
                raise ChatHistoryError(
                    "decoded zero dict-shaped values out of "
                    f"{total_live_records} live records (all failed to decode) -- "
                    "the on-disk format likely changed. Sample errors: "
                    + "; ".join(decode_errors[:5])
                )

            if not candidates:
                raise ChatHistoryError(
                    "decoded records successfully (found real account/session "
                    "metadata) but nothing conversation- or draft-shaped. The "
                    "installed Claude Desktop build does not appear to persist "
                    "actual conversation content to this local cache -- see the "
                    "module docstring for details."
                )

            candidates.sort(key=lambda c: _ts_sort_key(c.get("updated_at")), reverse=True)
            return candidates[:limit]
        finally:
            wdb.close()
    finally:
        staged.cleanup()


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _main() -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        description=(
            "Read Claude Desktop's local chat/IndexedDB cache. "
            "Reverse-engineered internals, best-effort, no stability guarantee."
        )
    )
    parser.add_argument(
        "command", choices=["schema", "conversations"], nargs="?", default="conversations"
    )
    parser.add_argument(
        "--path",
        default=str(DEFAULT_LEVELDB_PATH),
        help="Path to the *.indexeddb.leveldb directory (default: live Claude Desktop location)",
    )
    parser.add_argument(
        "--blob-path",
        default=None,
        help="Path to the sibling *.indexeddb.blob directory (default: inferred next to --path)",
    )
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument(
        "--scratch-root",
        default=None,
        help="Directory to stage the safe copy under (default: system temp dir)",
    )
    args = parser.parse_args()

    try:
        if args.command == "schema":
            result = detect_schema(args.path, args.blob_path, args.scratch_root)
        else:
            result = read_conversations(args.path, args.blob_path, args.limit, args.scratch_root)
    except ChatHistoryError as e:
        print(f"chat_history: {e}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, default=str))
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(_main())
