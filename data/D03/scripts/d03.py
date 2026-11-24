#!/usr/bin/env python3
"""Offline, source-labelled development corpus checks. Never emits source text."""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import sys

DATA = Path(__file__).resolve().parents[2]
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}\Z")
REQUIRED = {"schema_version", "case_id", "text", "source_type", "source_ref", "source_group_id",
            "near_duplicate_group_id", "purpose", "dataset_version", "revision", "review_status", "categories", "intents"}
HUMAN = {"recording_id", "d02_revision_id", "segment_index", "source_sha256"}
GROUP_KEYS = {"speaker_id_pseudonym", "session_id", "environment_id"}
SOURCES = {"human_transcript", "human_authored", "model_generated"}
CATEGORIES = {"completed_fact", "historical", "plan", "numeric_ambiguity", "correction", "context",
              "multi_intent", "subjective", "non_training", "source_uncertain", "exercise_alias"}
INTENTS = {"record_set", "correct_set", "plan", "subjective_state", "non_training", "context", "UNKNOWN"}


def dependency(task):
    path = DATA / task / "scripts" / (task.lower() + ".py")
    spec = importlib.util.spec_from_file_location("d03_" + task.lower(), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


d04 = dependency("D04")


def fail(result, code, case_ids=()):
    safe = sorted({value if isinstance(value, str) and IDENTIFIER.fullmatch(value) else "invalid-id" for value in case_ids})
    error = {"code": code, "case_ids": safe}
    result["errors"].append(error)


def check_row(row, result, protected=False, human_context=None):
    if not isinstance(row, dict) or not REQUIRED.issubset(row) or set(row) - REQUIRED - HUMAN - GROUP_KEYS:
        fail(result, "invalid_schema")
        return False
    key = row["case_id"]
    errors_before = len(result["errors"])
    for field in ("case_id", "source_group_id", "near_duplicate_group_id", "dataset_version"):
        if not isinstance(row[field], str) or not IDENTIFIER.fullmatch(row[field]):
            fail(result, "invalid_identifier", [key])
    if type(row["schema_version"]) is not int or row["schema_version"] != 1 or type(row["revision"]) is not int or row["revision"] < 1:
        fail(result, "invalid_version", [key])
    for field in ("text", "source_ref"):
        if not isinstance(row[field], str) or not row[field].strip() or len(row[field]) > 10000:
            fail(result, "missing_text_or_provenance", [key])
    if isinstance(row["text"], str) and not d04.normalized_text(row["text"]):
        fail(result, "empty_normalized_text", [key])
    if not isinstance(row["source_type"], str) or row["source_type"] not in SOURCES:
        fail(result, "unknown_source_type", [key])
    purposes = {"heldout"} if protected else {"train", "dev", "test"}
    if not isinstance(row["purpose"], str) or row["purpose"] not in purposes:
        fail(result, "invalid_purpose", [key])
    for field, choices in (("categories", CATEGORIES), ("intents", INTENTS)):
        values = row[field]
        if not isinstance(values, list) or not values or any(not isinstance(value, str) or value not in choices for value in values):
            fail(result, "invalid_" + field, [key])
        elif len(set(values)) != len(values):
            fail(result, "duplicate_" + field, [key])
    if row["source_type"] == "human_transcript" and not protected:
        if not HUMAN.issubset(row) or row["review_status"] != "reviewed":
            fail(result, "reviewed_D02_provenance_required", [key])
        elif not all(isinstance(row[field], str) and IDENTIFIER.fullmatch(row[field]) for field in ("recording_id", "d02_revision_id")) or type(row["segment_index"]) is not int or row["segment_index"] < 1:
            fail(result, "invalid_D02_reference", [key])
        else:
            context_key = (row["recording_id"], row["d02_revision_id"], row["segment_index"])
            evidence = (human_context or {}).get(context_key)
            expected_ref = f"D02:{row['d02_revision_id']}:{row['segment_index']}"
            if (not evidence or evidence["text"] != row["text"] or evidence["sha256"] != row["source_sha256"]
                    or row["source_ref"] != expected_ref or row["source_group_id"] != evidence.get("source_group_id", row["recording_id"])):
                fail(result, "human_transcript_not_current_reviewed_source", [key])
    elif not protected and (row["review_status"] != "draft" or any(row.get(field) not in (None, "") for field in HUMAN)):
        fail(result, "nonhuman_case_must_remain_explicit_draft", [key])
    return len(result["errors"]) == errors_before


def group_identity(row, human_context):
    identity = {field: row.get(field) for field in GROUP_KEYS}
    if row["source_type"] == "human_transcript":
        key = (row.get("recording_id"), row.get("d02_revision_id"), row.get("segment_index"))
        evidence = (human_context or {}).get(key, {})
        identity.update({field: evidence[field] for field in GROUP_KEYS if field in evidence})
    return identity


def validate_cases(cases, protected=None, human_context=None):
    result = {"schema_version": "d03-corpus-v1", "valid": False, "cases": 0, "errors": [],
              "source_counts": {}, "human_transcript_count": 0, "category_counts": {},
              "duplicate_candidates": [], "target_count_range": [100, 150],
              "protection": {"status": "not_supplied" if protected is None else "empty_not_frozen", "protected_cases": 0},
              "acceptance": "development_only_not_frozen", "system_metrics": "not_measured"}
    if not isinstance(cases, list) or (protected is not None and not isinstance(protected, list)):
        fail(result, "cases_must_be_arrays")
        return result
    seen, rows = set(), []
    for row in cases:
        if check_row(row, result, human_context=human_context):
            if row["case_id"] in seen:
                fail(result, "duplicate_case_id", [row["case_id"]])
            seen.add(row["case_id"])
            rows.append(row)
    if len({row["dataset_version"] for row in rows}) > 1:
        fail(result, "mixed_dataset_versions")
    protected_rows = []
    for row in protected or []:
        if check_row(row, result, protected=True):
            protected_rows.append(row)
    if protected_rows:
        result["protection"] = {"status": "checked_supplied_protection_not_freeze_approval", "protected_cases": len(protected_rows)}
    for i, row in enumerate(rows):
        for other in rows[:i]:
            kind = d04.text_duplicate_kind(row["text"], other["text"])
            if kind:
                result["duplicate_candidates"].append({"case_ids": [other["case_id"], row["case_id"]], "kind": kind, "action": "review_without_deleting_original"})
        for protected_row in protected_rows:
            identity = group_identity(row, human_context)
            protected_identity = group_identity(protected_row, None)
            for candidate, candidate_identity in ((row, identity), (protected_row, protected_identity)):
                if candidate["source_type"] == "human_transcript" and not all(
                        isinstance(value, str) and IDENTIFIER.fullmatch(value) and value.casefold() not in {"unknown", "unassigned"}
                        for value in candidate_identity.values()):
                    fail(result, "human_protection_group_evidence_required", [row["case_id"]])
            same_identity = (row["source_type"] == protected_row["source_type"] == "human_transcript"
                             and any(identity[field] and identity[field] == protected_identity[field] for field in GROUP_KEYS))
            same_recording = row.get("recording_id") and row.get("recording_id") == protected_row.get("recording_id")
            if (row["case_id"] == protected_row["case_id"] or row["source_group_id"] == protected_row["source_group_id"]
                    or row["near_duplicate_group_id"] == protected_row["near_duplicate_group_id"]
                    or same_recording or same_identity
                    or d04.text_duplicate_kind(row["text"], protected_row["text"])):
                fail(result, "protected_source_or_text_overlap", [row["case_id"]])
    result.update(cases=len(rows), source_counts=dict(Counter(row["source_type"] for row in rows)),
                  human_transcript_count=sum(row["source_type"] == "human_transcript" for row in rows),
                  category_counts=dict(Counter(category for row in rows for category in row["categories"])))
    result["valid"] = not result["errors"]
    return result


def human_sources(source_root, annotation_root, when, groups_path=None):
    d02 = dependency("D02")
    root = d02.safe_location(annotation_root, directory=True)
    consents, recordings = d02.source_store(source_root, when)
    _, latest, _, _ = d02.load_workspace(root, consents, recordings, when)
    groups = {}
    if groups_path is not None:
        check = {"errors": []}
        for group in d04.read_table(groups_path, d04.GROUP_FIELDS, check):
            if group["recording_id"] in groups or any(not IDENTIFIER.fullmatch(group[field]) for field in ("environment_id", "source_group_id", "near_duplicate_group_id")):
                raise ValueError("invalid or duplicate private group metadata")
            groups[group["recording_id"]] = group
        if check["errors"]:
            raise ValueError("invalid group schema")
    result = {}
    for recording_id, record in latest.items():
        for row in record["annotations"]:
            if row["review_status"] == "reviewed":
                result[(recording_id, record["metadata"]["revision_id"], int(row["segment_index"]))] = {
                    "text": row["reference_text"], "sha256": recordings[recording_id]["sha256"],
                    "speaker_id_pseudonym": recordings[recording_id]["speaker_id_pseudonym"],
                    "session_id": recordings[recording_id]["session_id"],
                    "source_group_id": groups.get(recording_id, {}).get("source_group_id", recording_id),
                    "environment_id": groups.get(recording_id, {}).get("environment_id")}
    return result


def unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def read_cases(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8_000_000:
        raise ValueError("invalid corpus file")
    return [json.loads(line, object_pairs_hook=unique_keys,
                       parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite number")))
            for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check"])
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--protected", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--annotation-root", type=Path)
    parser.add_argument("--groups", type=Path, help="private D04 GROUPS.csv for human environment/source-family checks")
    parser.add_argument("--as-of")
    args = parser.parse_args(argv)
    try:
        cases = read_cases(args.input)
        protected = read_cases(args.protected) if args.protected else None
        context = None
        if args.source_root or args.annotation_root or args.groups:
            if not args.source_root or not args.annotation_root:
                raise ValueError("both source and annotation roots required")
            context = human_sources(args.source_root, args.annotation_root, dependency("D01").as_of(args.as_of), args.groups)
        result = validate_cases(cases, protected, context)
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, AttributeError):
        print(json.dumps({"valid": False, "error": "invalid private corpus/provenance input; inspect locally"}), file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["valid"] else 2


if __name__ == "__main__":
    sys.exit(main())
