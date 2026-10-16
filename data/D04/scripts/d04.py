#!/usr/bin/env python3
"""Read-only, offline split isolation and externally approved freeze checks."""
import argparse
from collections import Counter
import csv
from datetime import datetime, timezone
from difflib import SequenceMatcher
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys
import unicodedata


SPLIT_FIELDS = "recording_id,speaker_id_pseudonym,session_id,scene_id,dataset_version,split_train_dev_heldout,frozen_at,sha256_audio,sha256_gold,split_review_owner,is_excluded,exclusion_reason".split(",")
GROUP_FIELDS = "recording_id,environment_id,source_group_id,near_duplicate_group_id,source_kind,audio_path,gold_path,gold_review_status,gold_version,text_path".split(",")
EXPOSURE_FIELDS = "recording_id,use,used_at,evidence_ref".split(",")
ACCESS_FIELDS = "access_id,recording_id,accessed_at,actor_id,use,approval_ref,dataset_version".split(",")
DEVELOPMENT_USES = {"development", "regression", "example", "train", "dev", "prompt", "tuning"}
USES = DEVELOPMENT_USES | {"annotation", "independent_review", "heldout_evaluation"}
UNKNOWN = {"", "unknown", "pending", "unassigned", "none", "n/a"}
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,79}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")


def sha256_file(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def parse_timestamp(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed


def normalized_text(value):
    """NFKC/casefold letters and numbers; callers retain original private bytes."""
    return "".join(character for character in unicodedata.normalize("NFKC", value).casefold() if character.isalnum())


def text_duplicate_kind(left, right):
    """Conservative lexical candidate check, not a semantic similarity guarantee."""
    left, right = normalized_text(left), normalized_text(right)
    if left and left == right:
        return "normalized_exact"
    if min(len(left), len(right)) >= 8 and SequenceMatcher(None, left, right, autojunk=False).ratio() >= 0.85:
        return "near_duplicate"
    return None


def add_error(result, code, recording_ids=()):
    safe_ids = {value if isinstance(value, str) and IDENTIFIER.fullmatch(value) else "invalid-id" for value in recording_ids}
    error = {"code": code, "recording_ids": sorted(safe_ids)}
    if error not in result["errors"]:
        result["errors"].append(error)


def read_table(path, fields, result):
    try:
        with Path(path).open(encoding="utf-8-sig", newline="") as stream:
            reader = csv.DictReader(stream)
            if reader.fieldnames != fields:
                add_error(result, "invalid_schema")
                return []
            rows = list(reader)
            if any(None in row or any(value is None for value in row.values()) for row in rows):
                add_error(result, "invalid_schema")
                return []
            return rows
    except (OSError, UnicodeError, csv.Error):
        add_error(result, "unreadable_table")
        return []


def private_file(root, pointer):
    """Only literal relative files under the supplied private root; no symlinks."""
    if not isinstance(pointer, str) or not pointer or "\\" in pointer:
        raise ValueError("unsafe path")
    parts = PurePosixPath(pointer)
    if parts.is_absolute() or any(part in ("", ".", "..") for part in pointer.split("/")):
        raise ValueError("unsafe path")
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("unsafe root")
    current = root
    for part in parts.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("symlink path")
    current.resolve().relative_to(root.resolve())
    if not current.is_file():
        raise FileNotFoundError(pointer)
    return current


def read_json(path, result, error_code):
    try:
        with Path(path).open(encoding="utf-8") as stream:
            value = json.load(stream)
        if not isinstance(value, dict):
            raise ValueError("object required")
        return value
    except (OSError, ValueError, TypeError, UnicodeError):
        add_error(result, error_code)
        return {}


def initial_result(when):
    return {"schema_version": "d04-check-v1", "as_of": when.isoformat(), "status": "empty", "errors": [],
            "coverage": {"recordings": 0, "human_recordings": 0, "speakers": 0, "sessions": 0, "environments": 0, "by_split": {}, "by_scene": {}, "by_source": {}, "excluded": 0, "text_checked": 0},
            "acceptance": "not_accepted", "freeze": {"status": "not_frozen"},
            "limitations": ["Lexical matching does not establish semantic independence; source/near groups and exposure history require independent human review.",
                            "An eligibility JSON is a local D01 evidence snapshot, not identity authentication or permanent consent."]}


def load_plan(splits_path, groups_path, exposure_path, result):
    splits = read_table(splits_path, SPLIT_FIELDS, result)
    groups = read_table(groups_path, GROUP_FIELDS, result)
    exposures = read_table(exposure_path, EXPOSURE_FIELDS, result)
    rows_by_id, groups_by_id = {}, {}
    for row in splits:
        recording_id = row["recording_id"]
        if recording_id in rows_by_id:
            add_error(result, "duplicate_recording", [recording_id])
        rows_by_id[recording_id] = row
        for field in ("recording_id", "speaker_id_pseudonym", "session_id", "scene_id", "dataset_version"):
            if not IDENTIFIER.fullmatch(row[field]) or row[field].casefold() in UNKNOWN:
                add_error(result, "invalid_identifier", [recording_id])
        if row["split_train_dev_heldout"] not in ("train", "dev", "heldout"):
            add_error(result, "invalid_split", [recording_id])
        if row["is_excluded"] not in ("true", "false") or (row["is_excluded"] == "true" and not row["exclusion_reason"].strip()):
            add_error(result, "invalid_exclusion", [recording_id])
        for field in ("sha256_audio", "sha256_gold"):
            if not HASH.fullmatch(row[field]):
                add_error(result, "invalid_hash", [recording_id])
        if row["frozen_at"]:
            try:
                if parse_timestamp(row["frozen_at"]) > parse_timestamp(result["as_of"]):
                    raise ValueError("future freeze")
            except ValueError:
                add_error(result, "invalid_frozen_at", [recording_id])
    versions = {row["dataset_version"] for row in splits}
    if len(versions) > 1:
        add_error(result, "mixed_dataset_versions")
    for group in groups:
        recording_id = group["recording_id"]
        if recording_id in groups_by_id:
            add_error(result, "duplicate_group", [recording_id])
        groups_by_id[recording_id] = group
        if recording_id not in rows_by_id:
            add_error(result, "orphan_group", [recording_id])
        environment = group["environment_id"]
        if environment.casefold() in UNKNOWN or not IDENTIFIER.fullmatch(environment):
            add_error(result, "missing_environment", [recording_id])
        for field in ("source_group_id", "near_duplicate_group_id", "gold_version"):
            if group[field].casefold() in UNKNOWN or not IDENTIFIER.fullmatch(group[field]):
                add_error(result, "missing_provenance_group", [recording_id])
        if group["source_kind"] not in ("human_recording", "derived_audio", "synthetic"):
            add_error(result, "invalid_source_kind", [recording_id])
        if group["gold_review_status"] not in ("unreviewed", "needs_review", "reviewed", "disputed"):
            add_error(result, "invalid_gold_review_status", [recording_id])
    for recording_id in rows_by_id:
        if recording_id not in groups_by_id:
            add_error(result, "missing_group", [recording_id])
    return splits, groups_by_id, exposures


def check_eligibility(rows, groups, eligibility_path, when, explicit_as_of, result):
    human_rows = [row for row in rows if groups.get(row["recording_id"], {}).get("source_kind") in ("human_recording", "derived_audio") and row["is_excluded"] == "false"]
    if not human_rows:
        return
    if eligibility_path is None:
        add_error(result, "local_eligibility_required")
        return
    report = read_json(eligibility_path, result, "local_eligibility_required")
    if report.get("purpose") != "local" or not isinstance(report.get("eligible"), list) or not isinstance(report.get("excluded"), list):
        add_error(result, "local_eligibility_required")
        return
    try:
        reported_at = parse_timestamp(report["as_of"])
        age = (when - reported_at).total_seconds()
        if (explicit_as_of and reported_at != when) or (not explicit_as_of and not 0 <= age <= 300):
            raise ValueError("stale snapshot")
    except (ValueError, TypeError, KeyError, AttributeError):
        add_error(result, "stale_eligibility")
    eligible, excluded = {}, set()
    for row in report["eligible"]:
        if not isinstance(row, dict) or not isinstance(row.get("recording_id"), str) or row["recording_id"] in eligible:
            add_error(result, "invalid_eligibility_report")
            continue
        eligible[row["recording_id"]] = row
    for row in report["excluded"]:
        if not isinstance(row, dict) or not isinstance(row.get("recording_id"), str):
            add_error(result, "invalid_eligibility_report")
            continue
        excluded.add(row["recording_id"])
    for row in human_rows:
        recording_id = row["recording_id"]
        evidence = eligible.get(recording_id)
        if not evidence or recording_id in excluded or evidence.get("quality_status") != "human_verified" or evidence.get("recording_source") not in ("human_recording", "iphone_microphone", "soundcore_microphone"):
            add_error(result, "recording_ineligible", [recording_id])
            continue
        if any(evidence.get(field) != row[field] for field in ("speaker_id_pseudonym", "session_id", "scene_id")) or evidence.get("sha256") != row["sha256_audio"]:
            add_error(result, "eligibility_identity_mismatch", [recording_id])


def check_artifacts(rows, groups, artifact_root, result):
    texts = {}
    if rows and artifact_root is None:
        add_error(result, "artifact_root_required")
        return texts
    for row in rows:
        recording_id = row["recording_id"]
        group = groups.get(recording_id)
        if group is None:
            continue
        for kind in ("audio", "gold"):
            try:
                path = private_file(artifact_root, group[kind + "_path"])
                if sha256_file(path) != row["sha256_" + kind]:
                    add_error(result, kind + "_hash_mismatch", [recording_id])
            except ValueError:
                add_error(result, "unsafe_artifact_path", [recording_id])
            except OSError:
                add_error(result, "missing_artifact", [recording_id])
        if group["text_path"]:
            try:
                texts[recording_id] = private_file(artifact_root, group["text_path"]).read_text(encoding="utf-8")
                if not normalized_text(texts[recording_id]):
                    add_error(result, "empty_reference_text", [recording_id])
            except ValueError:
                add_error(result, "unsafe_artifact_path", [recording_id])
            except (OSError, UnicodeError):
                add_error(result, "unreadable_text", [recording_id])
    return texts


def check_overlap(rows, groups, texts, exposures, result):
    # Excluded development rows remain contamination evidence, never a reset.
    development = [row for row in rows if row["split_train_dev_heldout"] in ("train", "dev")]
    heldout = [row for row in rows if row["split_train_dev_heldout"] == "heldout" and row["is_excluded"] == "false"]
    for candidate in heldout:
        if groups.get(candidate["recording_id"], {}).get("source_kind") == "synthetic":
            add_error(result, "nonhuman_heldout", [candidate["recording_id"]])
        for prior in development:
            ids = [candidate["recording_id"], prior["recording_id"]]
            for field, code in (("speaker_id_pseudonym", "speaker_overlap"), ("session_id", "session_overlap"), ("sha256_audio", "audio_hash_overlap"), ("sha256_gold", "gold_hash_overlap")):
                if candidate[field] and candidate[field] == prior[field]:
                    add_error(result, code, ids)
            left, right = groups.get(ids[0], {}), groups.get(ids[1], {})
            for field, code in (("environment_id", "environment_overlap"), ("source_group_id", "source_overlap"), ("near_duplicate_group_id", "near_duplicate_overlap")):
                if left.get(field) and left.get(field) == right.get(field):
                    add_error(result, code, ids)
            if ids[0] in texts and ids[1] in texts:
                match = text_duplicate_kind(texts[ids[0]], texts[ids[1]])
                if match:
                    add_error(result, "text_" + match + "_overlap", ids)
    by_id = {row["recording_id"]: row for row in rows}
    seen = set()
    for exposure in exposures:
        recording_id = exposure["recording_id"]
        if recording_id not in by_id:
            add_error(result, "unknown_exposure_recording", [recording_id])
            continue
        key = tuple(exposure[field] for field in EXPOSURE_FIELDS)
        if key in seen:
            add_error(result, "duplicate_exposure", [recording_id])
        seen.add(key)
        if exposure["use"] not in USES or not exposure["evidence_ref"].strip():
            add_error(result, "invalid_exposure", [recording_id])
        try:
            if parse_timestamp(exposure["used_at"]) > parse_timestamp(result["as_of"]):
                raise ValueError("future exposure")
        except ValueError:
            add_error(result, "invalid_exposure_time", [recording_id])
        if exposure["use"] not in DEVELOPMENT_USES:
            continue
        for candidate in heldout:
            candidate_id = candidate["recording_id"]
            if candidate_id == recording_id:
                add_error(result, "heldout_previously_exposed", [candidate_id])
                continue
            left, right = groups.get(candidate_id, {}), groups.get(recording_id, {})
            prior = by_id[recording_id]
            family = any(left.get(field) and left.get(field) == right.get(field) for field in ("environment_id", "source_group_id", "near_duplicate_group_id"))
            same_identity = any(candidate[field] == prior[field] for field in ("speaker_id_pseudonym", "session_id", "sha256_audio", "sha256_gold"))
            text_match = candidate_id in texts and recording_id in texts and text_duplicate_kind(texts[candidate_id], texts[recording_id])
            if family or same_identity or text_match:
                add_error(result, "heldout_family_previously_exposed", [candidate_id, recording_id])


def finish_result(result, rows, groups, texts):
    active = [row for row in rows if row["is_excluded"] == "false"]
    count = len(active)
    human_rows = [row for row in active if groups.get(row["recording_id"], {}).get("source_kind") in ("human_recording", "derived_audio")]
    speakers = {row["speaker_id_pseudonym"] for row in human_rows}
    by_split = dict(Counter(row["split_train_dev_heldout"] if row["split_train_dev_heldout"] in ("train", "dev", "heldout") else "invalid-split" for row in active))
    result["coverage"] = {"recordings": count, "human_recordings": len(human_rows), "speakers": len(speakers), "sessions": len({row["session_id"] for row in active}),
                          "environments": len({groups[row["recording_id"]]["environment_id"] for row in active if row["recording_id"] in groups and groups[row["recording_id"]]["environment_id"].casefold() not in UNKNOWN}),
                          "by_split": by_split, "by_scene": dict(Counter(row["scene_id"] if IDENTIFIER.fullmatch(row["scene_id"]) else "invalid-scene" for row in active)),
                          "by_source": dict(Counter(groups.get(row["recording_id"], {}).get("source_kind") if groups.get(row["recording_id"], {}).get("source_kind") in ("human_recording", "derived_audio", "synthetic") else "invalid-source" for row in active)),
                          "excluded": len(rows) - count, "text_checked": sum(row["recording_id"] in texts for row in active)}
    if not count:
        result["status"] = "blocked" if result["errors"] else "empty"
        return result
    sufficient = len(speakers) >= 2 and bool(by_split.get("heldout")) and bool(by_split.get("train", 0) + by_split.get("dev", 0))
    if not sufficient:
        add_error(result, "insufficient_independent_data")
        result["acceptance"] = "exploratory_pilot_only" if all(error["code"] == "insufficient_independent_data" for error in result["errors"]) else "blocked"
    else:
        result["acceptance"] = "blocked" if result["errors"] else "pending_independent_review"
    result["status"] = "blocked" if result["errors"] else "clean"
    return result


def check_plan(splits_path, groups_path, exposure_path, *, artifact_root=None, eligibility_path=None, as_of=None):
    """Read tables/artifacts only. Every error blocks independent held-out use."""
    try:
        when = parse_timestamp(as_of) if as_of else datetime.now(timezone.utc)
        if when > datetime.now(timezone.utc):
            raise ValueError("future as-of")
    except (ValueError, AttributeError, TypeError):
        result = initial_result(datetime.now(timezone.utc))
        add_error(result, "invalid_as_of")
        result["status"] = "blocked"
        return result
    result = initial_result(when)
    rows, groups, exposures = load_plan(splits_path, groups_path, exposure_path, result)
    check_eligibility(rows, groups, eligibility_path, when, as_of is not None, result)
    texts = check_artifacts(rows, groups, artifact_root, result)
    check_overlap(rows, groups, texts, exposures, result)
    return finish_result(result, rows, groups, texts)


def check_access_log(access_log_path, artifact_root, freeze, rows, groups, result):
    if access_log_path is None or artifact_root is None:
        add_error(result, "current_access_log_required")
        return None
    try:
        pointer = Path(access_log_path).absolute().relative_to(Path(artifact_root).absolute()).as_posix()
        ledger_path = private_file(artifact_root, pointer)
        ledger_hash = sha256_file(ledger_path)
    except (OSError, ValueError):
        add_error(result, "current_access_log_required")
        return None
    ledger = read_table(ledger_path, ACCESS_FIELDS, result)
    by_id = {row["recording_id"]: row for row in rows}
    heldout = [row for row in rows if row["split_train_dev_heldout"] == "heldout" and row["is_excluded"] == "false"]
    seen = set()
    for access in ledger:
        recording_id = access["recording_id"]
        if access["access_id"] in seen or any(not IDENTIFIER.fullmatch(access[field]) for field in ("access_id", "actor_id")) or not access["approval_ref"].strip() or access["dataset_version"] != freeze.get("dataset_version"):
            add_error(result, "invalid_access_log", [recording_id])
        seen.add(access["access_id"])
        if recording_id not in by_id:
            add_error(result, "unknown_access_recording", [recording_id])
            continue
        try:
            if not parse_timestamp(freeze["frozen_at"]) <= parse_timestamp(access["accessed_at"]) <= parse_timestamp(result["as_of"]):
                raise ValueError("access outside frozen interval")
        except (ValueError, KeyError, TypeError, AttributeError):
            add_error(result, "invalid_access_time", [recording_id])
        if access["use"] not in USES:
            add_error(result, "invalid_access_log", [recording_id])
        elif access["use"] in DEVELOPMENT_USES:
            prior = by_id[recording_id]
            for candidate in heldout:
                candidate_id = candidate["recording_id"]
                left, right = groups.get(candidate_id, {}), groups.get(recording_id, {})
                same_identity = any(candidate[field] == prior[field] for field in ("speaker_id_pseudonym", "session_id", "sha256_audio", "sha256_gold"))
                same_family = any(left.get(field) and left.get(field) == right.get(field) for field in ("environment_id", "source_group_id", "near_duplicate_group_id"))
                if candidate_id == recording_id or same_identity or same_family:
                    add_error(result, "heldout_access_contamination", [candidate_id, recording_id])
        elif access["use"] == "annotation" and any(row["recording_id"] == recording_id for row in heldout):
            add_error(result, "postfreeze_relabel_requires_new_approval", [recording_id])
    return ledger_hash


def verify_freeze(freeze_path, expected_sha256, splits_path, groups_path, exposure_path, *, artifact_root=None, eligibility_path=None, access_log_path=None, as_of=None):
    """Verify an externally approved immutable record; never create an approval."""
    result = check_plan(splits_path, groups_path, exposure_path, artifact_root=artifact_root, eligibility_path=eligibility_path, as_of=as_of)
    if not isinstance(expected_sha256, str) or not HASH.fullmatch(expected_sha256):
        add_error(result, "trusted_freeze_hash_required")
    else:
        try:
            if sha256_file(freeze_path) != expected_sha256:
                add_error(result, "freeze_hash_mismatch")
        except OSError:
            add_error(result, "unreadable_freeze")
    freeze = read_json(freeze_path, result, "invalid_freeze")
    rows, groups, unused = load_plan(splits_path, groups_path, exposure_path, result)
    access_log_hash = check_access_log(access_log_path, artifact_root, freeze, rows, groups, result)
    heldout = [row for row in rows if row["split_train_dev_heldout"] == "heldout" and row["is_excluded"] == "false"]
    try:
        if set(freeze) != {"schema_version", "dataset_version", "gold_version", "frozen_at", "preparer_id", "tuner_ids", "approval", "files", "artifacts", "gold_reviews"} or freeze["schema_version"] != "d04-freeze-v1":
            raise ValueError("invalid freeze schema")
        if {row["dataset_version"] for row in rows} != {freeze["dataset_version"]} or not IDENTIFIER.fullmatch(freeze["gold_version"]):
            add_error(result, "freeze_version_mismatch")
        frozen_at = parse_timestamp(freeze["frozen_at"])
        approval = freeze["approval"]
        if set(approval) != {"decision", "reviewer_id", "role", "approved_at", "evidence_ref"} or approval["decision"] != "approved" or not approval["evidence_ref"].strip():
            add_error(result, "freeze_approval_required")
        if approval["role"] not in ("user", "independent_reviewer") or not IDENTIFIER.fullmatch(approval["reviewer_id"]) or not IDENTIFIER.fullmatch(freeze["preparer_id"]) or not isinstance(freeze["tuner_ids"], list) or any(not isinstance(value, str) or not IDENTIFIER.fullmatch(value) for value in freeze["tuner_ids"]):
            add_error(result, "freeze_approval_required")
        if approval["role"] == "independent_reviewer" and (approval["reviewer_id"] == freeze["preparer_id"] or approval["reviewer_id"] in freeze["tuner_ids"]):
            add_error(result, "freeze_approval_not_independent")
        if not frozen_at <= parse_timestamp(approval["approved_at"]) <= parse_timestamp(result["as_of"]):
            add_error(result, "invalid_approval_time")
        files = {"splits": splits_path, "groups": groups_path, "exposure": exposure_path}
        if set(freeze["files"]) != set(files):
            add_error(result, "frozen_files_mismatch")
        else:
            for name, path in files.items():
                binding = freeze["files"][name]
                if set(binding) != {"path", "sha256"} or artifact_root is None or private_file(artifact_root, binding["path"]).resolve() != Path(path).resolve() or binding["sha256"] != sha256_file(path):
                    add_error(result, "frozen_files_mismatch")
        expected_artifacts = {}
        for row in rows:
            recording_id = row["recording_id"]
            group = groups.get(recording_id, {})
            text_path = group.get("text_path", "")
            expected_artifacts[recording_id] = {"audio_path": group.get("audio_path", ""), "audio_sha256": row["sha256_audio"], "gold_path": group.get("gold_path", ""), "gold_sha256": row["sha256_gold"], "text_path": text_path, "text_sha256": sha256_file(private_file(artifact_root, text_path)) if text_path else ""}
        if freeze["artifacts"] != expected_artifacts:
            add_error(result, "frozen_inventory_mismatch")
        if set(freeze["gold_reviews"]) != {row["recording_id"] for row in heldout}:
            add_error(result, "gold_review_required")
        for row in heldout:
            recording_id = row["recording_id"]
            group = groups.get(recording_id, {})
            if group.get("source_kind") not in ("human_recording", "derived_audio"):
                add_error(result, "nonhuman_heldout", [recording_id])
            if row["frozen_at"] != freeze["frozen_at"] or row["split_review_owner"] != approval["reviewer_id"] or group.get("gold_version") != freeze["gold_version"]:
                add_error(result, "freeze_identity_mismatch", [recording_id])
            review = freeze["gold_reviews"].get(recording_id, {})
            reviewer_ids = review.get("reviewer_ids", [])
            if group.get("gold_review_status") != "reviewed" or set(review) != {"reviewer_ids", "reviewed_at", "gold_version", "sha256_gold"} or not isinstance(reviewer_ids, list) or len(set(reviewer_ids)) < 2 or any(not isinstance(value, str) or not IDENTIFIER.fullmatch(value) for value in reviewer_ids) or review.get("gold_version") != group.get("gold_version") or review.get("sha256_gold") != row["sha256_gold"]:
                add_error(result, "gold_review_required", [recording_id])
            elif parse_timestamp(review["reviewed_at"]) > frozen_at:
                add_error(result, "gold_review_after_freeze", [recording_id])
    except (ValueError, TypeError, KeyError, AttributeError, OSError):
        add_error(result, "invalid_freeze")
    if not result["errors"] and heldout:
        result["freeze"] = {"status": "verified_approval_record", "sha256": expected_sha256, "frozen_at": freeze["frozen_at"], "reviewer_id": freeze["approval"]["reviewer_id"], "access_log_sha256": access_log_hash, "identity_authentication": "external_approval_log_required"}
        result["acceptance"] = "documented_freeze_verified"
    else:
        result["status"] = "blocked"
        result["acceptance"] = "not_accepted"
    return result


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("check", "verify-freeze"):
        command = commands.add_parser(name)
        command.add_argument("--splits", type=Path, required=True)
        command.add_argument("--groups", type=Path, required=True)
        command.add_argument("--exposure", type=Path, required=True)
        command.add_argument("--artifact-root", type=Path)
        command.add_argument("--eligibility", type=Path)
        command.add_argument("--as-of", help="timezone ISO8601; report snapshot must match exactly")
        if name == "verify-freeze":
            command.add_argument("--freeze", type=Path, required=True)
            command.add_argument("--freeze-sha256", required=True, help="trusted hash obtained independently from approval log")
            command.add_argument("--access-log", type=Path, help="current private append-only access ledger; required for verification")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    options = {"artifact_root": args.artifact_root, "eligibility_path": args.eligibility, "as_of": args.as_of}
    if args.command == "check":
        result = check_plan(args.splits, args.groups, args.exposure, **options)
    else:
        result = verify_freeze(args.freeze, args.freeze_sha256, args.splits, args.groups, args.exposure, access_log_path=args.access_log, **options)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
