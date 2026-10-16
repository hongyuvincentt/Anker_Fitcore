#!/usr/bin/env python3
"""Private, offline D02 annotation revisions. No recording/model/cloud calls."""
import argparse
from contextlib import contextmanager
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import tempfile


BASE = Path(__file__).resolve().parents[1]
REPOSITORY = next((p for p in BASE.parents if (p / "docs" / "DATA_SCOPE.md").exists() or (p / ".git").exists()), BASE)
DEPENDENCY = BASE.parent / "D01" / "scripts" / "d01.py"
if not DEPENDENCY.exists():
    DEPENDENCY = BASE / "dependencies" / "D01" / "scripts" / "d01.py"
spec = importlib.util.spec_from_file_location("d02_d01", DEPENDENCY)
d01 = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(d01)
except OSError:
    print(json.dumps({"error": "public D01 dependency missing; see README"}), file=sys.stderr)
    sys.exit(2)

Invalid = d01.Invalid
FIELDS = "recording_id,segment_index,reference_text,asr_hypothesis_separate,intent,exercise,weight_kg,reps,set_index,tense_or_modality,is_correction,target_set_reference,subjective_state,ambiguity_type,gold_decision,annotator_id_pseudonym,reviewer_id_pseudonym,review_status,gold_version,evidence_reference,change_reason".split(",")
META_FIELDS = {"schema_version", "recording_id", "revision_id", "parent_revision_id", "actor_id_pseudonym", "at", "event", "reason", "source_listened", "source_sha256", "segments", "adjudicator_id_pseudonym"}
INTENTS = {"record_set", "correct_set", "plan", "subjective_state", "non_training", "context", "UNKNOWN"}
MODALITIES = {"completed", "historical", "planned", "hypothetical", "subjective", "non_training", "context", "UNKNOWN"}
STATUSES = {"draft", "needs_review", "disputed", "reviewed"}
DECISIONS = {"COMMIT", "CORRECT", "DEFER", "IGNORE", "UNKNOWN"}
CONTENT_FIELDS = [f for f in FIELDS if f not in {"reviewer_id_pseudonym", "review_status", "change_reason"}]
MAX_INPUT = 2_000_000


def safe_location(path, directory=False):
    """Reject repo storage, traversal and symlinks, including parent components."""
    path = Path(path).expanduser().absolute()
    if ".." in path.parts:
        raise Invalid("unsafe path traversal")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise Invalid("symlink input/root rejected; use canonical private paths")
    try:
        path.resolve().relative_to(REPOSITORY.resolve())
    except ValueError:
        pass
    else:
        raise Invalid("private input/root must be outside repository")
    if directory:
        d01.check_root(path)
    return path


def private(root, name):
    return d01.private_path(root, name)


def exact_fields(value, fields, label):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise Invalid(label + " fields/schema mismatch")


def reject_duplicate_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise Invalid("duplicate JSON key")
        value[key] = item
    return value


def read_json(path):
    if not path.is_file() or path.stat().st_size > MAX_INPUT:
        raise Invalid("JSON input missing/too large")
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=reject_duplicate_keys,
                          parse_constant=lambda value: (_ for _ in ()).throw(Invalid("nonfinite JSON number")))
    except (ValueError, UnicodeError):
        raise Invalid("invalid private JSON input") from None


def annotations(path):
    if not path.is_file() or path.stat().st_size > MAX_INPUT:
        raise Invalid("annotation CSV missing/too large")
    with path.open(encoding="utf-8-sig", newline="") as inp:
        reader = csv.DictReader(inp)
        if reader.fieldnames != FIELDS:
            raise Invalid("ANNOTATIONS.csv header mismatch")
        rows = list(reader)
    if any(None in row or any(value is None for value in row.values()) for row in rows):
        raise Invalid("annotation CSV row width mismatch")
    return rows


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("utf-8")


def immutable(path, data):
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Invalid("revision_id/artifact_id already exists; no overwrite") from None
    with os.fdopen(descriptor, "wb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    path.chmod(0o400)


def project(root, rows):
    destination = private(root, "reference/ANNOTATIONS.csv")
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8-sig", newline="", dir=destination.parent, prefix=".d02-", delete=False) as out:
        temporary = Path(out.name)
        writer = csv.DictWriter(out, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temporary, destination)


@contextmanager
def locked(root):
    safe_location(root, directory=True)
    path = private(root, ".d02.lock")
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise Invalid("workspace locked; inspect .d02.lock privately after interruption") from None
    os.close(descriptor)
    try:
        yield
    finally:
        path.unlink()


def init(root, local_annotator):
    safe_location(root)
    d01.identifier(local_annotator, "local_annotator")
    if root.exists():
        raise Invalid("private root already exists; no overwrite")
    root.mkdir(mode=0o700, parents=True)
    for name in ("reference", "revisions", "asr", "inputs"):
        (root / name).mkdir(mode=0o700)
    immutable(root / "CONFIG.json", json_bytes({"schema_version": 1, "local_annotator_id_pseudonym": local_annotator}))
    immutable(root / "HISTORY.jsonl", b"")
    # The index is append-only through this tool; saved snapshots remain read-only.
    (root / "HISTORY.jsonl").chmod(0o600)
    project(root, [])
    return {"initialized": True, "annotations": 0, "reviewed_segments": 0, "frozen_segments": 0}


def source_store(source_root, when):
    safe_location(source_root, directory=True)
    consents, recordings = d01.load_store(source_root)
    for row in recordings:
        recorded = d01.timestamp(row["recorded_at"], "recorded_at")
        if recorded > when or recorded < d01.timestamp(consents[row["consent_id"]]["consent_timestamp"], "consent_timestamp"):
            raise Invalid("recording time invalid relative to consent/as-of")
    return consents, {row["recording_id"]: row for row in recordings}


def require_source(recording_id, consents, recordings, purpose, when):
    row = recordings.get(recording_id)
    if row is None:
        raise Invalid("recording_id missing from D01 source")
    result = d01.eligible(consents, [row], purpose, when)
    if not result["eligible"]:
        raise Invalid("source not eligible for " + purpose + ": " + result["excluded"][0]["reason"])
    return row


def number(value, field, integer=False):
    if value == "UNKNOWN":
        return
    pattern = r"[1-9][0-9]*" if integer else r"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?"
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise Invalid(field + " must be canonical positive number or UNKNOWN")
    try:
        if Decimal(value) <= 0:
            raise Invalid(field + " must be positive or UNKNOWN")
    except InvalidOperation:
        raise Invalid("invalid numeric field") from None


def segment_key(row):
    return row["recording_id"] + ":" + row["segment_index"]


def revision_purpose(meta, config):
    return "team" if meta["actor_id_pseudonym"] != config["local_annotator_id_pseudonym"] or meta["event"] in {"review", "dispute", "resolve"} else "local"


def validate_revision(record, previous, all_rows, config, consents, recordings, when, check_current=True):
    exact_fields(record, {"metadata", "annotations"}, "revision snapshot")
    meta, rows = record["metadata"], record["annotations"]
    exact_fields(meta, META_FIELDS, "revision metadata")
    if type(meta["schema_version"]) is not int or meta["schema_version"] != 1:
        raise Invalid("unsupported revision schema_version")
    for field in ("recording_id", "revision_id", "actor_id_pseudonym"):
        d01.identifier(meta[field], field)
    if not isinstance(rows, list) or not rows:
        raise Invalid("revision needs nonempty annotations")
    if meta["source_listened"] is not True:
        raise Invalid("source_listened must explicitly attest actual original-audio listening")
    if not isinstance(meta["reason"], str) or not meta["reason"].strip():
        raise Invalid("revision reason required")
    event = meta["event"]
    if event not in {"draft", "revise", "review", "dispute", "resolve"}:
        raise Invalid("invalid revision event")
    actor = meta["actor_id_pseudonym"]
    # Any second person accesses the recording under team consent, even for a draft.
    source = recordings.get(meta["recording_id"])
    if source is None:
        raise Invalid("recording_id missing from D01 source")
    if check_current:
        require_source(meta["recording_id"], consents, recordings, revision_purpose(meta, config), when)
    if meta["source_sha256"] != source["sha256"]:
        raise Invalid("source audio hash mismatch")
    at = d01.timestamp(meta["at"], "revision at")
    if at > when or at < d01.timestamp(source["recorded_at"], "recorded_at"):
        raise Invalid("revision time invalid relative to original audio/as-of")
    if previous is None:
        if meta["parent_revision_id"] is not None or event != "draft":
            raise Invalid("first revision must be draft with null parent")
    else:
        old_meta = previous["metadata"]
        if meta["parent_revision_id"] != old_meta["revision_id"]:
            raise Invalid("revision parent conflict")
        if at < d01.timestamp(old_meta["at"], "parent at"):
            raise Invalid("revision time precedes parent")
        if event == "draft":
            raise Invalid("existing recording requires revise/review/dispute/resolve event")
    keys = set()
    versions = set()
    for row in rows:
        exact_fields(row, FIELDS, "annotation")
        if any(not isinstance(v, str) or v != v.strip() or "\x00" in v for v in row.values()):
            raise Invalid("annotation fields must be strings without surrounding whitespace/NUL")
        if row["recording_id"] != meta["recording_id"]:
            raise Invalid("one revision must contain one recording_id")
        if not re.fullmatch(r"[1-9][0-9]*", row["segment_index"]):
            raise Invalid("segment_index must be canonical positive integer")
        key = segment_key(row)
        if key in keys:
            raise Invalid("duplicate recording_id/segment_index")
        keys.add(key)
        for field in ("reference_text", "exercise", "subjective_state", "ambiguity_type", "change_reason"):
            if not row[field]:
                raise Invalid(field + " required; use UNKNOWN where unresolved")
        if row["asr_hypothesis_separate"]:
            raise Invalid("ASR hypothesis must remain in separate ASR artifact")
        if row["intent"] not in INTENTS or row["tense_or_modality"] not in MODALITIES:
            raise Invalid("invalid intent/tense_or_modality")
        if row["review_status"] not in STATUSES or row["gold_decision"] not in DECISIONS:
            raise Invalid("invalid review_status/gold_decision")
        if row["is_correction"] not in {"true", "false", "UNKNOWN"}:
            raise Invalid("is_correction must be true/false/UNKNOWN")
        for field in ("weight_kg", "reps", "set_index"):
            number(row[field], field, integer=field != "weight_kg")
        d01.identifier(row["annotator_id_pseudonym"], "annotator_id_pseudonym")
        d01.identifier(row["gold_version"], "gold_version")
        versions.add(row["gold_version"])
        if row["gold_decision"] == "COMMIT":
            if row["tense_or_modality"] != "completed" or row["intent"] != "record_set" or row["is_correction"] != "false":
                raise Invalid("COMMIT requires unambiguous current completed record_set")
            if any(row[f] == "UNKNOWN" for f in ("exercise", "weight_kg", "reps", "set_index")) or row["ambiguity_type"] != "none":
                raise Invalid("COMMIT cannot contain UNKNOWN/ambiguity")
        if row["gold_decision"] == "CORRECT" and (row["is_correction"] != "true" or row["target_set_reference"] == "UNKNOWN" or row["intent"] != "correct_set" or row["tense_or_modality"] not in {"completed", "historical"}):
            raise Invalid("correction requires explicit known target and factual completed/historical modality")
        if row["reference_text"] == "UNKNOWN" and (row["gold_decision"] not in {"DEFER", "UNKNOWN"} or row["review_status"] == "reviewed"):
            raise Invalid("UNKNOWN reference needs unresolved review")
        if event in {"draft", "revise"}:
            if row["review_status"] not in {"draft", "needs_review"} or row["reviewer_id_pseudonym"]:
                raise Invalid("draft/revise cannot claim completed review")
            if row["annotator_id_pseudonym"] != actor:
                raise Invalid("draft annotator must match actual actor")
        else:
            if actor == row["annotator_id_pseudonym"]:
                raise Invalid("review requires independent actor; no self-signing")
            wanted = "disputed" if event == "dispute" else "reviewed"
            if row["reviewer_id_pseudonym"] != actor or row["review_status"] != wanted:
                raise Invalid("review event requires actual reviewer and matching status")
    if len(versions) != 1:
        raise Invalid("one recording revision needs one gold_version")
    if previous:
        old_rows = previous["annotations"]
        if any(row["review_status"] == "disputed" for row in old_rows) and event not in {"resolve", "dispute"}:
            raise Invalid("disputed revision requires explicit resolve adjudication")
        if not {segment_key(row) for row in old_rows}.issubset(keys):
            raise Invalid("revision cannot silently drop prior segments/actions")
        if event in {"review", "dispute", "resolve"}:
            if [[row[f] for f in CONTENT_FIELDS] for row in rows] != [[row[f] for f in CONTENT_FIELDS] for row in old_rows]:
                raise Invalid("review cannot change content; create a new draft version")
            if meta["segments"] != previous["metadata"]["segments"] or meta["source_sha256"] != previous["metadata"]["source_sha256"]:
                raise Invalid("review cannot change semantic evidence; create a new draft version")
        elif versions == {row["gold_version"] for row in old_rows}:
            raise Invalid("revise requires new gold_version; old revision remains immutable")
        if event == "review" and any(row["review_status"] == "disputed" for row in old_rows):
            raise Invalid("disputed revision requires explicit resolve adjudication")
        if event == "resolve":
            if not any(row["review_status"] == "disputed" for row in old_rows):
                raise Invalid("resolve requires parent dispute")
            if meta["adjudicator_id_pseudonym"] != actor or actor == previous["metadata"]["actor_id_pseudonym"]:
                raise Invalid("resolve requires explicit independent adjudicator")
    if event != "resolve" and meta["adjudicator_id_pseudonym"]:
        raise Invalid("adjudicator reserved for resolve")
    segments = meta["segments"]
    if not isinstance(segments, list) or len(segments) != len(rows):
        raise Invalid("segment evidence must cover every annotation")
    by_index = {row["segment_index"]: row for row in rows}
    seen = set()
    known = {segment_key(row): row for row in all_rows}
    known.update({segment_key(row): row for row in rows})
    for segment in segments:
        exact_fields(segment, {"segment_index", "start_sec", "end_sec", "context", "correction_target"}, "segment evidence")
        if type(segment["segment_index"]) is not int:
            raise Invalid("segment evidence index must be integer")
        index = str(segment["segment_index"])
        if index in seen or index not in by_index:
            raise Invalid("duplicate/missing segment evidence")
        seen.add(index)
        start, end = segment["start_sec"], segment["end_sec"]
        if any(type(v) not in (int, float) or not math.isfinite(v) for v in (start, end)) or not 0 <= start < end <= float(source["duration_sec"]) + 0.000001:
            raise Invalid("segment evidence time outside original audio")
        row = by_index[index]
        match = re.fullmatch(r"audio:([A-Za-z0-9_-]+)#t=([0-9.]+),([0-9.]+)", row["evidence_reference"])
        if not match or match[1] != meta["recording_id"]:
            raise Invalid("evidence_reference must identify original audio segment")
        try:
            if abs(float(match[2]) - start) > 0.000001 or abs(float(match[3]) - end) > 0.000001:
                raise Invalid("evidence time mismatch")
        except ValueError:
            raise Invalid("invalid evidence time") from None
        context = segment["context"]
        if not isinstance(context, list) or any(not isinstance(key, str) for key in context) or len(set(context)) != len(context) or any(key not in known or key == segment_key(row) for key in context):
            raise Invalid("context must reference distinct existing other segments")
        target = segment["correction_target"]
        if target != row["target_set_reference"]:
            raise Invalid("correction target relation mismatch")
        if target != "UNKNOWN":
            if row["is_correction"] != "true" or target not in known or target == segment_key(row):
                raise Invalid("correction target must reference existing other fact")
            target_row = known[target]
            if target_row["intent"] != "record_set" or target_row["tense_or_modality"] not in {"completed", "historical"}:
                raise Invalid("correction target must be completed/historical fact")
        elif row["is_correction"] == "true" and (row["gold_decision"] not in {"DEFER", "UNKNOWN"} or row["ambiguity_type"] == "none"):
            raise Invalid("unknown correction target requires ambiguity and DEFER/UNKNOWN")


def claim_version(record, versions):
    meta = record["metadata"]
    key = (meta["recording_id"], record["annotations"][0]["gold_version"])
    if meta["event"] in {"draft", "revise"} and key in versions:
        raise Invalid("gold_version already used; choose a new version")
    versions.add(key)


def validate_latest_relations(latest):
    known = {segment_key(row): row for record in latest.values() for row in record["annotations"]}
    for record in latest.values():
        for segment in record["metadata"]["segments"]:
            if any(key not in known for key in segment["context"]):
                raise Invalid("latest context relation missing")
            target = segment["correction_target"]
            if target != "UNKNOWN" and (target not in known or known[target]["intent"] != "record_set" or known[target]["tense_or_modality"] not in {"completed", "historical"}):
                raise Invalid("latest correction target is missing/not a completed or historical fact")


def load_history(root, consents, recordings, when):
    """Validate retained audit integrity without treating current grants as past grants."""
    config = read_json(private(root, "CONFIG.json"))
    exact_fields(config, {"schema_version", "local_annotator_id_pseudonym"}, "workspace config")
    if type(config["schema_version"]) is not int or config["schema_version"] != 1:
        raise Invalid("unsupported workspace schema")
    d01.identifier(config["local_annotator_id_pseudonym"], "local_annotator")
    latest, ids, versions = {}, set(), set()
    history = private(root, "HISTORY.jsonl")
    if history.stat().st_size > MAX_INPUT * 20:
        raise Invalid("revision history too large")
    with history.open(encoding="utf-8") as inp:
        for line in inp:
            if not line.strip():
                raise Invalid("blank revision history entry")
            try:
                entry = json.loads(line, object_pairs_hook=reject_duplicate_keys)
            except ValueError:
                raise Invalid("invalid revision history JSON") from None
            exact_fields(entry, {"revision_id", "sha256"}, "history entry")
            revision_id = d01.identifier(entry["revision_id"], "revision_id")
            if revision_id in ids:
                raise Invalid("duplicate revision_id in history")
            ids.add(revision_id)
            path = private(root, "revisions/" + revision_id + ".json")
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
                raise Invalid("revision snapshot hash mismatch/missing")
            record = read_json(path)
            exact_fields(record, {"metadata", "annotations"}, "revision snapshot")
            meta = record["metadata"]
            exact_fields(meta, META_FIELDS, "revision metadata")
            if meta["revision_id"] != revision_id:
                raise Invalid("revision_id index mismatch")
            previous = latest.get(meta["recording_id"])
            validate_revision(record, previous, [row for item in latest.values() for row in item["annotations"]], config, consents, recordings, when, check_current=False)
            claim_version(record, versions)
            latest[meta["recording_id"]] = record
    expected = {key + ".json" for key in ids}
    if {p.name for p in private(root, "revisions").iterdir()} != expected:
        raise Invalid("orphan revision files require private reconciliation")
    rows = annotations(private(root, "reference/ANNOTATIONS.csv"))
    projected_ids = {row["recording_id"] for row in rows}
    # This is a derived cache: consent may have removed complete recording groups.
    # Content edits or partial groups still conflict with immutable current heads.
    if not projected_ids.issubset(latest) or rows != [row for key in sorted(projected_ids) for row in latest[key]["annotations"]]:
        raise Invalid("reference projection conflicts with immutable revision history")
    validate_latest_relations(latest)
    return config, latest, ids


def active_workspace(config, latest, consents, recordings, when):
    active, excluded = {}, {}
    for recording_id, record in latest.items():
        purpose = revision_purpose(record["metadata"], config)
        check = d01.eligible(consents, [recordings[recording_id]], purpose, when)
        if check["excluded"]:
            excluded[recording_id] = {**check["excluded"][0], "purpose": purpose}
        else:
            active[recording_id] = record
    # Context and correction references cannot keep withdrawn content in active use.
    while True:
        dependent = []
        for recording_id, record in active.items():
            references = [key for segment in record["metadata"]["segments"] for key in segment["context"] + ([segment["correction_target"]] if segment["correction_target"] != "UNKNOWN" else [])]
            if any(key.split(":", 1)[0] not in active for key in references):
                dependent.append(recording_id)
        if not dependent:
            break
        for recording_id in dependent:
            del active[recording_id]
            excluded[recording_id] = {"recording_id": recording_id, "purpose": revision_purpose(latest[recording_id]["metadata"], config), "reason": "referenced_source_excluded"}
    rows = [row for key in sorted(active) for row in active[key]["annotations"]]
    return active, rows, [excluded[key] for key in sorted(excluded)]


def load_workspace(root, consents, recordings, when):
    """Return current eligible heads/rows only; retained revision IDs remain auditable."""
    config, latest, ids = load_history(root, consents, recordings, when)
    active, rows, _ = active_workspace(config, latest, consents, recordings, when)
    return config, active, ids, rows


ASR_FIELDS = {"schema_version", "artifact_id", "recording_id", "source_sha256", "hypothesis", "origin", "model_version"}


def validate_asr(value, consents, recordings, when, check_current=True):
    exact_fields(value, ASR_FIELDS, "ASR artifact")
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise Invalid("unsupported ASR schema")
    d01.identifier(value["artifact_id"], "artifact_id")
    d01.identifier(value["recording_id"], "recording_id")
    if value["origin"] != "offline_import" or not isinstance(value["hypothesis"], str) or not value["hypothesis"].strip() or not isinstance(value["model_version"], str) or not value["model_version"].strip():
        raise Invalid("ASR requires offline_import origin, hypothesis and model_version")
    source = recordings.get(value["recording_id"])
    if source is None:
        raise Invalid("ASR recording_id missing from D01 source")
    if check_current:
        require_source(value["recording_id"], consents, recordings, "local", when)
    if value["source_sha256"] != source["sha256"]:
        raise Invalid("ASR source hash mismatch")


def asr_count(root, consents, recordings, when):
    count, excluded = 0, 0
    for path in private(root, "asr").iterdir():
        path = private(root, "asr/" + path.name)
        value = read_json(path)
        validate_asr(value, consents, recordings, when, check_current=False)
        if path.name != value["artifact_id"] + ".json":
            raise Invalid("ASR artifact filename mismatch")
        if d01.eligible(consents, [recordings[value["recording_id"]]], "local", when)["eligible"]:
            count += 1
        else:
            excluded += 1
    return count, excluded


def run(args):
    root = safe_location(args.root)
    when = d01.as_of(args.as_of)
    consents, recordings = source_store(args.source_root, when)
    if args.command == "init":
        return init(root, args.local_annotator)
    with locked(root):
        config, history_latest, ids = load_history(root, consents, recordings, when)
        latest, rows, excluded = active_workspace(config, history_latest, consents, recordings, when)
        artifacts, excluded_artifacts = asr_count(root, consents, recordings, when)
        project(root, rows)
        if args.command == "queue":
            result = d01.eligible(consents, list(recordings.values()), args.purpose, when)
            combined = {item["recording_id"]: {**item, "purpose": args.purpose} for item in result["excluded"]}
            combined.update({item["recording_id"]: item for item in excluded})
            eligible = [row for row in result["eligible"] if row["recording_id"] not in combined]
            return {"purpose": args.purpose, "as_of": when.isoformat(), "eligible_recordings": len(eligible), "queue": [{"recording_id": row["recording_id"], "segments": sum(item["recording_id"] == row["recording_id"] for item in rows), "latest_revision_id": latest[row["recording_id"]]["metadata"]["revision_id"] if row["recording_id"] in latest else None, "disputed_segment_indices": [item["segment_index"] for item in rows if item["recording_id"] == row["recording_id"] and item["review_status"] == "disputed"]} for row in eligible], "excluded_recordings": len(combined), "excluded": [combined[key] for key in sorted(combined)]}
        if args.command == "revise":
            supplied_rows = annotations(safe_location(args.input))
            meta = read_json(safe_location(args.metadata))
            exact_fields(meta, META_FIELDS, "revision metadata")
            recording_id = d01.identifier(meta["recording_id"], "recording_id")
            previous = history_latest.get(recording_id)
            head = previous["metadata"]["revision_id"] if previous else "NONE"
            if args.expected_revision != head or meta["parent_revision_id"] != (head if previous else None):
                raise Invalid("revision parent conflict; reload current head")
            revision_id = d01.identifier(meta["revision_id"], "revision_id")
            if revision_id in ids:
                raise Invalid("revision_id already exists; no overwrite")
            record = {"metadata": meta, "annotations": supplied_rows}
            validate_revision(record, previous, rows, config, consents, recordings, when)
            versions = set()
            for old_id in ids:
                old = read_json(private(root, "revisions/" + old_id + ".json"))
                versions.add((old["metadata"]["recording_id"], old["annotations"][0]["gold_version"]))
            claim_version(record, versions)
            validate_latest_relations({**history_latest, recording_id: record})
            data = json_bytes(record)
            immutable(private(root, "revisions/" + revision_id + ".json"), data)
            with private(root, "HISTORY.jsonl").open("a", encoding="utf-8") as out:
                out.write(json.dumps({"revision_id": revision_id, "sha256": hashlib.sha256(data).hexdigest()}) + "\n")
                out.flush()
                os.fsync(out.fileno())
            history_latest[recording_id] = record
            latest, rows, excluded = active_workspace(config, history_latest, consents, recordings, when)
            project(root, rows)
            return {"saved": True, "revision_id": revision_id, "segments": len(supplied_rows), "frozen_segments": 0}
        if args.command == "attach-asr":
            value = read_json(safe_location(args.input))
            validate_asr(value, consents, recordings, when)
            immutable(private(root, "asr/" + value["artifact_id"] + ".json"), json_bytes(value))
            return {"attached": True, "artifact_id": value["artifact_id"], "reference_unchanged": True}
        return {"valid": True, "as_of": when.isoformat(), "recordings": len(latest), "segments": len(rows), "retained_history_recordings": len(history_latest), "excluded_recordings": len(excluded), "excluded": excluded, "revisions": len(ids), "draft_segments": sum(row["review_status"] in {"draft", "needs_review"} for row in rows), "reviewed_segments": sum(row["review_status"] == "reviewed" for row in rows), "disputed_segments": sum(row["review_status"] == "disputed" for row in rows), "frozen_segments": 0, "asr_artifacts": artifacts, "excluded_asr_artifacts": excluded_artifacts, "acceptance": "human_acceptance_pending"}


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("init", "queue", "revise", "validate", "attach-asr"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, required=True, help="canonical private D02 root outside repository")
        command.add_argument("--source-root", type=Path, required=True, help="canonical private D01 root; read-only")
        command.add_argument("--as-of", help="audit date/time; default current Asia/Shanghai time")
        if name == "init":
            command.add_argument("--local-annotator", required=True)
        elif name == "queue":
            command.add_argument("--purpose", choices=("local", "team", "cloud"), default="local")
        elif name in {"revise", "attach-asr"}:
            command.add_argument("--input", type=Path, required=True)
            if name == "revise":
                command.add_argument("--metadata", type=Path, required=True)
                command.add_argument("--expected-revision", required=True, help="current revision id, or NONE for first draft")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        result = run(args)
    except Invalid as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2
    except (OSError, UnicodeError, csv.Error, ValueError, TypeError, KeyError, OverflowError):
        print(json.dumps({"error": "private input/filesystem operation failed; inspect privately without sharing content/paths"}), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
