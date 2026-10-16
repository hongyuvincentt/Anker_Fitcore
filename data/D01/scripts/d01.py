#!/usr/bin/env python3
"""Offline, standard-library D01 WAV collection. Never invokes cloud services."""
import argparse
from collections import Counter
from contextlib import contextmanager
import csv
from datetime import date, datetime, time
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import tempfile
from zoneinfo import ZoneInfo


CONSENT_FIELDS = "consent_id,speaker_id_pseudonym,consent_timestamp,recording_allowed,internal_team_use_allowed,aws_model_processing_allowed,share_scope,retention_until,withdrawal_method,consent_status,withdrawn_at,verification_reviewer,notes_no_pii".split(",")
MANIFEST_FIELDS = "recording_id,speaker_id_pseudonym,consent_id,session_id,scene_id,recorded_at,device_type,recording_source,sample_rate_hz,channels,bits_per_sample,duration_sec,size_bytes,sha256,private_storage_pointer,quality_status,label_status,data_split,retention_status".split(",")
SHANGHAI = ZoneInfo("Asia/Shanghai")
MAX_BYTES = 7_000_000
HUMAN_SOURCES = {"iphone_microphone", "soundcore_microphone", "human_recording"}
SCENES = ("ordinary", "numeric_ambiguity", "correction_context", "plan", "noise")


class Invalid(ValueError):
    """A safe validation message without private absolute paths."""


def identifier(value, field):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}", value):
        raise Invalid(f"invalid identifier: {field}")
    return value


def timestamp(value, field):
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        raise Invalid(f"invalid ISO8601 timestamp: {field}") from None
    if result.tzinfo is None:
        raise Invalid(f"timezone required: {field}")
    return result


def as_of(value=None):
    if value is None:
        return datetime.now(SHANGHAI)
    try:
        # A date means end of that Shanghai calendar day, conservatively excluding
        # timestamp expirations earlier that day. Date retention includes the day.
        if len(value) == 10:
            return datetime.combine(date.fromisoformat(value), time.max, SHANGHAI)
        return timestamp(value, "as-of").astimezone(SHANGHAI)
    except ValueError:
        raise Invalid("invalid --as-of; use YYYY-MM-DD or timezone ISO8601") from None


def private_path(root, pointer):
    if not isinstance(pointer, str) or "\\" in pointer:
        raise Invalid("unsafe private path")
    parts = PurePosixPath(pointer)
    if parts.is_absolute() or not parts.parts or any(part in (".", "..", "") for part in pointer.split("/")):
        raise Invalid("unsafe private path")
    current = root
    for part in parts.parts:
        current = current / part
        if current.is_symlink():
            raise Invalid("symlink private path rejected")
    try:
        current.resolve().relative_to(root.resolve())
    except ValueError:
        raise Invalid("private path escapes root") from None
    return current


def check_root(root):
    if root.is_symlink() or not root.is_dir():
        raise Invalid("private root missing or symlink")
    if root.stat().st_mode & 0o077:
        raise Invalid("private root permissions must exclude group/other access (chmod 700)")


def read_csv(root, name, fields):
    path = private_path(root, name)
    with path.open(encoding="utf-8-sig", newline="") as inp:
        reader = csv.DictReader(inp)
        if reader.fieldnames != fields:
            raise Invalid(f"CSV header mismatch: {name}")
        rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise Invalid(f"CSV row width mismatch: {name}")
    return rows


def write_csv(root, name, fields, rows):
    path = private_path(root, name)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8-sig", newline="", dir=root, prefix=".d01-", delete=False) as out:
        temp_path = Path(out.name)
        writer = csv.DictWriter(out, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp_path, path)


@contextmanager
def locked(root):
    check_root(root)
    lock = private_path(root, ".d01.lock")
    try:
        descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Invalid("collection is locked; inspect .d01.lock after an interrupted operation") from None
    try:
        os.close(descriptor)
        yield
    finally:
        lock.unlink()


def audit(root, event, **fields):
    path = private_path(root, "audit.jsonl")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as out:
        out.write(json.dumps({"at": datetime.now(SHANGHAI).isoformat(), "event": event, **fields}, ensure_ascii=False) + "\n")


def init_store(root):
    if root.exists() or root.is_symlink():
        raise Invalid("private root already exists; no overwrite")
    root.mkdir(mode=0o700, parents=True)
    (root / "audio").mkdir(mode=0o700)
    write_csv(root, "CONSENT_REGISTER.csv", CONSENT_FIELDS, [])
    write_csv(root, "WAV_MANIFEST.csv", MANIFEST_FIELDS, [])
    audit(root, "initialized")
    return {"initialized": True, "consents": 0, "recordings": 0}


def validate_consent_rows(rows):
    index = {}
    for row in rows:
        key = identifier(row["consent_id"], "consent_id")
        identifier(row["speaker_id_pseudonym"], "speaker_id_pseudonym")
        if key in index:
            raise Invalid("duplicate consent_id")
        index[key] = row
        for field in ("recording_allowed", "internal_team_use_allowed", "aws_model_processing_allowed"):
            if row[field] not in ("true", "false"):
                raise Invalid(f"{field} must be explicit true/false")
        if row["consent_status"] not in ("pending", "granted", "denied", "withdrawn"):
            raise Invalid("invalid consent_status")
        timestamp(row["consent_timestamp"], "consent_timestamp")
        if not row["retention_until"]:
            raise Invalid("consent retention_until is required")
        if len(row["retention_until"]) == 10:
            try:
                date.fromisoformat(row["retention_until"])
            except ValueError:
                raise Invalid("invalid retention_until") from None
        else:
            timestamp(row["retention_until"], "retention_until")
        if row["withdrawn_at"]:
            timestamp(row["withdrawn_at"], "withdrawn_at")
        if row["consent_status"] == "granted" and (not row["withdrawal_method"] or not row["verification_reviewer"]):
            raise Invalid("granted consent needs withdrawal_method and verification_reviewer")
    return index


def consent_reason(row, purpose, when):
    if row["consent_status"] != "granted":
        return "consent_not_granted"
    if row["withdrawn_at"]:
        return "consent_withdrawn"
    if timestamp(row["consent_timestamp"], "consent_timestamp") > when:
        return "consent_not_yet_effective"
    expiry = row["retention_until"]
    if (len(expiry) == 10 and date.fromisoformat(expiry) < when.astimezone(SHANGHAI).date()) or (len(expiry) != 10 and timestamp(expiry, "retention_until") <= when):
        return "consent_expired"
    for field in ("recording_allowed", {"local": "recording_allowed", "team": "internal_team_use_allowed", "cloud": "aws_model_processing_allowed"}[purpose]):
        if row[field] != "true":
            return field + "_not_allowed"
    return None


def inspect_wav(path):
    """Strict RIFF PCM16 inspection; returns metadata plus immutable input bytes."""
    if path.is_symlink() or not path.is_file():
        raise Invalid("WAV source must be a regular non-symlink file")
    if path.stat().st_size > MAX_BYTES:
        raise Invalid("WAV exceeds 7MB (7000000 bytes)")
    with path.open("rb") as inp:
        data = inp.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise Invalid("WAV exceeds 7MB (7000000 bytes)")
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise Invalid("invalid RIFF/WAVE header")
    if struct.unpack_from("<I", data, 4)[0] + 8 != len(data):
        raise Invalid("RIFF length mismatch or truncated/trailing bytes")
    offset, fmt, samples = 12, None, None
    while offset < len(data):
        if offset + 8 > len(data):
            raise Invalid("RIFF truncated chunk header")
        tag = data[offset:offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        start, end = offset + 8, offset + 8 + size
        if end + size % 2 > len(data):
            raise Invalid("RIFF truncated chunk")
        if tag == b"fmt ":
            if fmt is not None or size < 16:
                raise Invalid("RIFF invalid/duplicate format chunk")
            fmt = struct.unpack_from("<HHIIHH", data, start)
        elif tag == b"data":
            if samples is not None:
                raise Invalid("RIFF duplicate data chunk")
            samples = data[start:end]
        offset = end + size % 2
    if fmt is None or samples is None:
        raise Invalid("RIFF missing format/data chunk")
    codec, channels, rate, byte_rate, align, bits = fmt
    if codec != 1 or bits != 16:
        raise Invalid("WAV must be uncompressed PCM16")
    if channels != 1:
        raise Invalid("WAV must be mono")
    if rate != 16000:
        raise Invalid("WAV must use 16000 Hz")
    if byte_rate != 32000 or align != 2 or len(samples) % 2:
        raise Invalid("RIFF invalid PCM16 block alignment")
    frames = len(samples) // 2
    if frames == 0:
        raise Invalid("empty WAV audio")
    values = [value[0] for value in struct.iter_unpack("<h", samples)]
    mean = sum(values) / frames
    # Reject silence and constant/DC-only input, without claiming speech detection.
    rms = math.sqrt(sum((value - mean) ** 2 for value in values) / frames)
    if rms / 32768 < 0.0001:
        raise Invalid("silence or DC-only WAV")
    metadata = {"sample_rate_hz": rate, "channels": channels, "bits_per_sample": bits, "duration_sec": frames / rate, "size_bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "frame_count": frames}
    return metadata, data


def load_store(root):
    check_root(root)
    consents = validate_consent_rows(read_csv(root, "CONSENT_REGISTER.csv", CONSENT_FIELDS))
    recordings = read_csv(root, "WAV_MANIFEST.csv", MANIFEST_FIELDS)
    ids, hashes = set(), set()
    provenance = sidecar_provenance(root)
    for row in recordings:
        for field in ("recording_id", "speaker_id_pseudonym", "consent_id", "session_id", "scene_id"):
            identifier(row[field], field)
        if row["recording_id"] in ids or row["sha256"] in hashes:
            raise Invalid("duplicate recording_id or sha256 in manifest")
        ids.add(row["recording_id"])
        hashes.add(row["sha256"])
        consent = consents.get(row["consent_id"])
        if consent is None:
            raise Invalid("manifest consent_id has no consent")
        if row["speaker_id_pseudonym"] != consent["speaker_id_pseudonym"]:
            raise Invalid("manifest speaker does not match consent")
        recorded = timestamp(row["recorded_at"], "recorded_at")
        if recorded < timestamp(consent["consent_timestamp"], "consent_timestamp"):
            raise Invalid("manifest recorded_at precedes consent_timestamp")
        path = private_path(root, row["private_storage_pointer"])
        if row["private_storage_pointer"] != f"audio/{row['recording_id']}.wav":
            raise Invalid("private path does not match recording_id")
        actual, _ = inspect_wav(path)
        for field in ("sample_rate_hz", "channels", "bits_per_sample", "size_bytes", "sha256"):
            if str(actual[field]) != row[field]:
                raise Invalid(f"manifest {field} mismatch")
        try:
            duration = float(row["duration_sec"])
        except ValueError:
            raise Invalid("manifest duration_sec mismatch") from None
        if not math.isfinite(duration) or abs(duration - actual["duration_sec"]) > 0.000001:
            raise Invalid("manifest duration_sec mismatch")
        if row["quality_status"] not in ("needs_review", "human_verified", "rejected"):
            raise Invalid("invalid quality_status")
        if row["quality_status"] == "human_verified" and row["recording_source"] not in HUMAN_SOURCES:
            raise Invalid("source cannot be human_verified")
        expected_sidecar = provenance.get(row["recording_id"])
        if expected_sidecar:
            sidecar = private_path(root, f"sidecars/{row['recording_id']}.metadata.json")
            raw = sidecar_bytes(sidecar)
            if hashlib.sha256(raw).hexdigest() != expected_sidecar:
                raise Invalid("retained sidecar hash mismatch")
            validate_sidecar(sidecar_metadata(sidecar, raw), row, actual)
    sidecar_dir = private_path(root, "sidecars")
    if not set(provenance).issubset(ids):
        raise Invalid("orphan sidecar provenance requires private reconciliation")
    if sidecar_dir.exists():
        if not sidecar_dir.is_dir() or sidecar_dir.stat().st_mode & 0o077:
            raise Invalid("sidecar directory must have private permissions")
        expected = {f"{key}.metadata.json" for key in provenance}
        if any(path.name not in expected for path in sidecar_dir.iterdir()):
            raise Invalid("orphan sidecar files require private reconciliation")
    return consents, recordings


def sidecar_bytes(path):
    if path.is_symlink() or not path.is_file():
        raise Invalid("metadata sidecar must be a regular non-symlink file")
    if path.stat().st_size > 65536:
        raise Invalid("metadata sidecar too large")
    with path.open("rb") as inp:
        raw = inp.read(65537)
    if len(raw) > 65536:
        raise Invalid("metadata sidecar too large")
    return raw


def sidecar_metadata(path, raw=None):
    if path is None:
        return {}
    if raw is None:
        raw = sidecar_bytes(path)
    try:
        result = json.loads(raw.decode("utf-8-sig"))
    except (ValueError, UnicodeError):
        raise Invalid("invalid metadata sidecar JSON") from None
    if not isinstance(result, dict):
        raise Invalid("metadata sidecar must be an object")
    if "schema_version" in result and (type(result["schema_version"]) is not int or result["schema_version"] != 1):
        raise Invalid("unsupported metadata schema_version")
    for field in ("is_simulated", "local_recording_consent"):
        if field in result and type(result[field]) is not bool:
            raise Invalid(f"metadata {field} must be boolean")
    if result.get("local_recording_consent") is False:
        raise Invalid("sidecar local recording consent denied")
    return result


def sidecar_provenance(root):
    """Old imports without a sidecar hash remain explicitly legacy/CLI provenance."""
    path = private_path(root, "audit.jsonl")
    if not path.exists():
        return {}
    index = {}
    try:
        with path.open(encoding="utf-8") as inp:
            for line in inp:
                event = json.loads(line)
                if not isinstance(event, dict):
                    raise Invalid("invalid provenance audit event")
                if event.get("event") in ("imported", "sidecar_recovered") and event.get("sidecar_sha256"):
                    key = identifier(event.get("recording_id"), "recording_id")
                    digest = event["sidecar_sha256"]
                    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                        raise Invalid("invalid sidecar provenance hash")
                    if key in index:
                        raise Invalid("duplicate sidecar provenance")
                    index[key] = digest
    except (ValueError, UnicodeError):
        raise Invalid("invalid provenance audit JSON") from None
    return index


def validate_sidecar(meta, row, actual, when=None):
    for field in ("recording_id", "speaker_id_pseudonym", "consent_id", "session_id", "scene_id", "recorded_at", "device_type"):
        if field in meta and meta[field] != row[field]:
            raise Invalid(f"metadata {field} mismatch")
    if "utterance_id" in meta and meta["utterance_id"] != row["recording_id"]:
        raise Invalid("metadata utterance_id mismatch")
    if "file_name" in meta and meta["file_name"] != row["recording_id"] + ".wav":
        raise Invalid("metadata file_name mismatch")
    source = "simulator" if meta.get("is_simulated") is True else meta.get("recording_source")
    if source is not None and source != row["recording_source"]:
        raise Invalid("metadata recording_source mismatch")
    if "completed_at" in meta:
        completed = timestamp(meta["completed_at"], "completed_at")
        if completed < timestamp(row["recorded_at"], "recorded_at") or (when is not None and completed > when):
            raise Invalid("metadata completed_at outside recording/as-of interval")
    inspection = meta.get("inspection", {})
    if not isinstance(inspection, dict):
        raise Invalid("metadata inspection must be an object")
    aliases = {"sample_rate": "sample_rate_hz", "duration_seconds": "duration_sec"}
    for values in (meta, inspection):
        for key, claimed in values.items():
            field = aliases.get(key, key)
            if field in actual:
                if field == "duration_sec":
                    if type(claimed) not in (int, float) or not (actual[field] - 0.000001 <= claimed <= actual[field] + 0.000001):
                        raise Invalid(f"metadata {field} mismatch")
                elif field != "sha256" and type(claimed) in (int, float):
                    if claimed != actual[field] or not math.isfinite(claimed):
                        raise Invalid(f"metadata {field} mismatch")
                elif str(claimed) != str(actual[field]):
                    raise Invalid(f"metadata {field} mismatch")


def import_recording(root, args, when):
    with locked(root):
        try:
            consents, recordings = load_store(root)
            raw_sidecar = sidecar_bytes(args.metadata) if args.metadata is not None else None
            meta = sidecar_metadata(args.metadata, raw_sidecar)
            row = dict.fromkeys(MANIFEST_FIELDS, "")
            for field in ("recording_id", "speaker_id_pseudonym", "consent_id", "session_id", "scene_id", "recorded_at", "device_type", "recording_source"):
                provided = getattr(args, field)
                if provided is not None and field in meta and provided != meta[field]:
                    raise Invalid(f"metadata/CLI conflict: {field}")
                row[field] = provided if provided is not None else meta.get(field, "")
            for field in ("recording_id", "speaker_id_pseudonym", "consent_id", "session_id", "scene_id", "device_type"):
                identifier(row[field], field)
            recorded = timestamp(row["recorded_at"], "recorded_at")
            if recorded > when:
                raise Invalid("recorded_at is in the future relative to as-of")
            row["recording_source"] = "simulator" if meta.get("is_simulated") is True else row["recording_source"] or "unknown"
            identifier(row["recording_source"], "recording_source")
            consent = consents.get(row["consent_id"])
            if consent is None:
                raise Invalid("missing consent_id in consent register")
            if consent["speaker_id_pseudonym"] != row["speaker_id_pseudonym"]:
                raise Invalid("speaker does not match consent_id")
            reason = consent_reason(consent, "local", when)
            if reason:
                raise Invalid("consent denied: " + reason)
            if timestamp(row["recorded_at"], "recorded_at") < timestamp(consent["consent_timestamp"], "consent_timestamp"):
                raise Invalid("recorded_at precedes consent_timestamp")
            actual, data = inspect_wav(args.wav)
            validate_sidecar(meta, row, actual, when)
            if any(existing["recording_id"] == row["recording_id"] or existing["sha256"] == actual["sha256"] for existing in recordings):
                raise Invalid("duplicate recording_id or sha256")
            pointer = f"audio/{row['recording_id']}.wav"
            target = private_path(root, pointer)
            if target.exists():
                raise Invalid("audio destination exists; no overwrite")
            sidecar_target = None
            if raw_sidecar is not None:
                sidecar_dir = private_path(root, "sidecars")
                if not sidecar_dir.exists():
                    sidecar_dir.mkdir(mode=0o700)
                if not sidecar_dir.is_dir() or sidecar_dir.stat().st_mode & 0o077:
                    raise Invalid("sidecar directory must have private permissions")
                sidecar_target = private_path(root, f"sidecars/{row['recording_id']}.metadata.json")
                if sidecar_target.exists():
                    raise Invalid("sidecar destination exists; no overwrite")
            row.update({key: str(value) for key, value in actual.items() if key in MANIFEST_FIELDS})
            row.update(private_storage_pointer=pointer, quality_status="needs_review", label_status="unlabelled", data_split="unassigned", retention_status="active")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as out:
                out.write(data)
                out.flush()
                os.fsync(out.fileno())
            if sidecar_target is not None:
                descriptor = os.open(sidecar_target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, "wb") as out:
                    out.write(raw_sidecar)
                    out.flush()
                    os.fsync(out.fileno())
            # A crash here leaves an immutable orphan; subsequent imports refuse
            # to overwrite it. validate reports it for deliberate reconciliation.
            write_csv(root, "WAV_MANIFEST.csv", MANIFEST_FIELDS, recordings + [row])
            audit(root, "imported", recording_id=row["recording_id"], sha256=row["sha256"], source=row["recording_source"], sidecar_sha256=hashlib.sha256(raw_sidecar).hexdigest() if raw_sidecar is not None else None)
            return {"recording": row, "human_verification": "manual_review_required"}
        except (Invalid, OSError) as error:
            audit(root, "import_rejected", reason=str(error) if isinstance(error, Invalid) else "private_io_failure")
            raise


def eligible(consents, recordings, purpose, when):
    accepted, excluded = [], []
    for row in recordings:
        reason = consent_reason(consents[row["consent_id"]], purpose, when)
        if reason is None and timestamp(row["recorded_at"], "recorded_at") > when:
            reason = "recording_not_yet_effective"
        if reason is None and row["quality_status"] != "human_verified":
            reason = "human_review_required"
        if reason:
            excluded.append({"recording_id": row["recording_id"], "reason": reason})
        else:
            accepted.append(row)
    return {"purpose": purpose, "as_of": when.isoformat(), "eligible": accepted, "excluded": excluded}


def report(consents, recordings, when, root=None):
    current = eligible(consents, recordings, "local", when)["eligible"]
    people = {row["speaker_id_pseudonym"] for row in current}
    devices = Counter(row["device_type"] for row in current)
    scenes = Counter(row["scene_id"] for row in current)
    matrix = {scene: {"recordings": scenes[scene], "speakers": len({row["speaker_id_pseudonym"] for row in current if row["scene_id"] == scene})} for scene in SCENES}
    result = {"as_of": when.isoformat(), "imported_recordings": len(recordings), "human_verified_recordings": len(current), "actual_people": len(people), "pending_review_recordings": sum(row["quality_status"] == "needs_review" for row in recordings), "devices": dict(devices), "scenes": dict(scenes), "coverage_matrix": matrix, "eligible_counts": {purpose: len(eligible(consents, recordings, purpose, when)["eligible"]) for purpose in ("local", "team", "cloud")}, "targets_only": {"pilot_recordings": 10, "expanded_recordings_approx": 40, "speakers_min": 3, "speakers_max": 5}, "acceptance": "not_accepted", "acceptance_note": "counts are evidence only; D01 needs actual human review, JZD review additionally requires team consent"}
    if root is not None:
        provenance = sidecar_provenance(root)
        retained = sum(row["recording_id"] in provenance for row in recordings)
        result["sidecar_provenance_counts"] = {"retained_verified": retained, "not_retained_legacy_or_cli": len(recordings) - retained}
    return result


def run(args):
    root, when = args.root, as_of(args.as_of)
    if args.command == "init":
        return init_store(root)
    if args.command == "import":
        return import_recording(root, args, when)
    with locked(root):
        if args.command == "withdraw":
            # Revocation must remain possible even if audio is missing/corrupt.
            consents = validate_consent_rows(read_csv(root, "CONSENT_REGISTER.csv", CONSENT_FIELDS))
            consent = consents.get(identifier(args.consent_id, "consent_id"))
            if consent is None:
                raise Invalid("missing consent_id")
            withdrawn = timestamp(args.withdrawn_at, "withdrawn_at")
            if withdrawn > when:
                raise Invalid("withdrawn_at cannot be after as-of")
            if withdrawn < timestamp(consent["consent_timestamp"], "consent_timestamp"):
                raise Invalid("withdrawn_at precedes consent_timestamp")
            if consent["withdrawn_at"]:
                raise Invalid("consent already withdrawn; preserve first withdrawal")
            consent.update(consent_status="withdrawn", withdrawn_at=withdrawn.isoformat())
            write_csv(root, "CONSENT_REGISTER.csv", CONSENT_FIELDS, list(consents.values()))
            audit(root, "consent_withdrawn", consent_id=args.consent_id)
            return {"withdrawn": args.consent_id, "audio_retained_for_private_lifecycle_action": True}
        consents, recordings = load_store(root)
        if args.command == "recover-sidecar":
            key = identifier(args.recording_id, "recording_id")
            row = next((row for row in recordings if row["recording_id"] == key), None)
            if row is None:
                raise Invalid("unknown recording_id")
            reason = consent_reason(consents[row["consent_id"]], "local", when)
            if reason:
                raise Invalid("consent denied: " + reason)
            raw = sidecar_bytes(args.metadata)
            meta = sidecar_metadata(args.metadata, raw)
            if not all(field in meta for field in ("recording_id", "recorded_at")) or not isinstance(meta.get("inspection"), dict) or not meta["inspection"].get("sha256"):
                raise Invalid("original metadata requires recording_id, recorded_at and inspection sha256")
            actual, _ = inspect_wav(private_path(root, row["private_storage_pointer"]))
            validate_sidecar(meta, row, actual, when)
            directory = private_path(root, "sidecars")
            directory.mkdir(mode=0o700, exist_ok=True)
            if not directory.is_dir() or directory.stat().st_mode & 0o077:
                raise Invalid("sidecar directory must have private permissions")
            target = private_path(root, f"sidecars/{key}.metadata.json")
            if target.exists() or key in sidecar_provenance(root):
                raise Invalid("sidecar already retained; no overwrite")
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as out:
                out.write(raw)
                out.flush()
                os.fsync(out.fileno())
            # A crash before audit leaves an orphan that validation rejects.
            audit(root, "sidecar_recovered", recording_id=key, sidecar_sha256=hashlib.sha256(raw).hexdigest(), source_path=str(args.metadata.resolve()))
            return {"recovered": True, "quality_status": row["quality_status"]}
        if args.command == "verify-human":
            reviewer = identifier(args.reviewer, "reviewer")
            row = next((row for row in recordings if row["recording_id"] == args.recording_id), None)
            if row is None:
                raise Invalid("unknown recording_id")
            if row["recording_source"] not in HUMAN_SOURCES:
                raise Invalid("source not eligible for human verification; unknown/simulator/TTS cannot be promoted")
            reason = consent_reason(consents[row["consent_id"]], "local", when)
            if reason:
                raise Invalid("consent denied: " + reason)
            row["quality_status"] = "human_verified"
            write_csv(root, "WAV_MANIFEST.csv", MANIFEST_FIELDS, recordings)
            audit(root, "human_verified", recording_id=row["recording_id"], reviewer=reviewer)
            return {"recording_id": row["recording_id"], "quality_status": "human_verified", "reviewer": reviewer}
        if args.command == "eligible":
            return eligible(consents, recordings, args.purpose, when)
        if args.command == "report":
            return report(consents, recordings, when, root)
        if args.command == "validate":
            expected = {row["private_storage_pointer"] for row in recordings}
            audio_dir = private_path(root, "audio")
            orphans = [path.name for path in audio_dir.iterdir() if "audio/" + path.name not in expected]
            if orphans:
                raise Invalid("orphan audio files require private manual reconciliation")
            return {"valid": True, "consents": len(consents), "recordings": len(recordings), "as_of": when.isoformat()}
    raise Invalid("unsupported command")


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("init", "import", "validate", "eligible", "report", "withdraw", "verify-human", "recover-sidecar"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, required=True, help="private storage root, outside shared delivery folders")
        command.add_argument("--as-of", help="Shanghai date YYYY-MM-DD or timezone ISO8601; default current Asia/Shanghai time")
        if name == "import":
            command.add_argument("--wav", type=Path, required=True)
            command.add_argument("--metadata", type=Path)
            for field in ("recording_id", "consent_id", "session_id", "scene_id", "recorded_at", "device_type", "recording_source"):
                command.add_argument("--" + field.replace("_", "-"))
            command.add_argument("--speaker-id", dest="speaker_id_pseudonym")
        elif name == "recover-sidecar":
            command.add_argument("--recording-id", required=True)
            command.add_argument("--metadata", type=Path, required=True)
        elif name == "eligible":
            command.add_argument("--purpose", choices=("local", "team", "cloud"), required=True)
        elif name == "withdraw":
            command.add_argument("--consent-id", required=True)
            command.add_argument("--withdrawn-at", required=True)
        elif name == "verify-human":
            command.add_argument("--recording-id", required=True)
            command.add_argument("--reviewer", required=True, help="manual attestation after listening and confirming physical human origin")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        payload = run(args)
    except Invalid as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    except (OSError, UnicodeError, csv.Error):
        print(json.dumps({"error": "private filesystem/CSV operation failed; inspect privately without sharing paths"}), file=sys.stderr)
        return 2
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
