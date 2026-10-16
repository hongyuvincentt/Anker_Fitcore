#!/usr/bin/env python3
"""Offline D05 evaluation; Python 3.9+, standard library, no provider calls."""
import argparse
import csv
from datetime import datetime
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys


SCHEMA_VERSION = "d05.input.v1"
METRICS_VERSION = "d05.metrics.v1"
MODES = ("synthetic", "text_simulation", "replay", "real_audio")
SOURCES = ("synthetic_fixture", "human_written", "model_generated", "human_audio", "recorded_replay")
FLAGS = ("asr_transcription_error", "asr_numeric_error", "semantic_error", "fact_engine_error")
FACT_FIELDS = {"exercise", "weight_kg", "reps", "temporal_modality", "time", "target"}
CSV_COLUMNS = ("dataset_version", "source_commit", "evaluation_time", "model_provider",
               "mode_mock_replay_real", "split", "sample_count", "correct_auto_commit",
               "wrong_commit", "missed_fact", "defer_pending", "asr_error", "semantic_error",
               "fact_engine_error", "latency_p50_ms", "latency_p95_ms", "cost_if_verified",
               "reviewer", "notes")


def fields(value, required, optional=(), where="object"):
    if not isinstance(value, dict):
        raise ValueError(where + " must be an object")
    missing = set(required) - value.keys()
    extra = value.keys() - set(required) - set(optional)
    if missing or extra:
        raise ValueError("%s has missing fields %s or unknown fields %s" % (where, sorted(missing), sorted(extra)))


def text(value, where):
    if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
        raise ValueError(where + " must be a nonempty single-line string")


def number(value, where, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(where + " must be a finite nonnegative number")
    if integer and (not isinstance(value, int)):
        raise ValueError(where + " must be an integer")


def json_value(value, where):
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError(where + " contains a nonfinite number")
    if isinstance(value, dict):
        for key, item in value.items():
            text(key, where + " key")
            json_value(item, where)
    elif isinstance(value, list):
        for item in value:
            json_value(item, where)
    elif value is not None and not isinstance(value, (str, int, float, bool)):
        raise ValueError(where + " is not JSON data")


def validate_fact(item, where):
    fields(item, {"fact_id", "fact"}, where=where)
    text(item["fact_id"], where + ".fact_id")
    value = item["fact"]
    fields(value, FACT_FIELDS, where=where + ".fact")
    for key in ("exercise", "weight_kg", "reps", "temporal_modality"):
        if value[key] is None:
            continue
        if key == "weight_kg":
            number(value[key], key)
        elif key == "reps":
            number(value[key], key, integer=True)
        else:
            text(value[key], key)
    if value["temporal_modality"] not in ("completed", "historical", "planned", "unknown", None):
        raise ValueError("invalid temporal_modality")
    if value["temporal_modality"] == "completed" and value["exercise"] is None:
        raise ValueError("completed facts require an exercise; unknown gold must remain unreviewed")
    json_value(value["time"], where + ".time")
    json_value(value["target"], where + ".target")


def cost_amount(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise ValueError("cost amount must be a decimal number or decimal string")
    try:
        amount = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError("invalid cost amount") from exc
    if not amount.is_finite() or amount < 0:
        raise ValueError("cost amount must be finite and nonnegative")
    return amount


def validate_record(record):
    fields(record, {"schema_version", "case_id", "recording_id", "version_ref", "mode", "source",
                    "gold_status", "expected_facts", "actual", "adjudication", "slices"},
           {"latency", "cost"}, "case")
    if record["schema_version"] != SCHEMA_VERSION:
        raise ValueError("unsupported record schema_version")
    for key in ("case_id", "recording_id", "version_ref"):
        text(record[key], key)
    if record["mode"] not in MODES or record["source"] not in SOURCES:
        raise ValueError("invalid mode or source")
    if (record["mode"] == "synthetic") != (record["source"] == "synthetic_fixture"):
        raise ValueError("synthetic records require synthetic mode and source together")
    if record["mode"] == "real_audio" and record["source"] != "human_audio":
        raise ValueError("real_audio requires human_audio source")
    if record["gold_status"] not in ("reviewed", "unreviewed", "disputed"):
        raise ValueError("invalid gold_status")
    if not isinstance(record["expected_facts"], list) or not isinstance(record["actual"], list):
        raise ValueError("expected_facts and actual must be arrays")
    gold_ids = set()
    for item in record["expected_facts"]:
        validate_fact(item, "expected fact")
        if record["gold_status"] == "reviewed" and item["fact"]["temporal_modality"] in ("unknown", None):
            raise ValueError("reviewed gold requires a resolved temporal_modality; keep unresolved gold unreviewed or disputed")
        if item["fact_id"] in gold_ids:
            raise ValueError("duplicate expected fact_id")
        gold_ids.add(item["fact_id"])
    for item in record["actual"]:
        if not isinstance(item, dict):
            raise ValueError("actual decision must be an object")
        if item.get("decision") == "COMMIT":
            fields(item, {"decision", "origin", "fact_id", "fact"}, where="COMMIT")
            validate_fact({"fact_id": item["fact_id"], "fact": item["fact"]}, "committed fact")
        else:
            fields(item, {"decision", "origin"}, where="decision")
        if item["decision"] not in ("COMMIT", "DEFER", "REJECT") or item["origin"] not in ("auto", "manual"):
            raise ValueError("invalid decision or origin")
    adjudication = record["adjudication"]
    fields(adjudication, {"status"}, {"reviewer_id", *FLAGS}, "adjudication")
    if adjudication["status"] not in ("reviewed", "unreviewed"):
        raise ValueError("invalid adjudication status")
    if adjudication["status"] == "reviewed":
        text(adjudication.get("reviewer_id"), "adjudication reviewer_id")
    for flag in FLAGS:
        value = adjudication.get(flag)
        if value is not None and type(value) is not bool:
            raise ValueError(flag + " must be boolean or null")
        if value is not None and adjudication["status"] != "reviewed":
            raise ValueError("error flags require explicit manual adjudication")
    fields(record["slices"], {"device", "speaker", "noise", "action", "numeric_ambiguity"}, where="slices")
    for key, value in record["slices"].items():
        text(value, "slice " + key)
    if record.get("latency") is not None:
        fields(record["latency"], {"ms", "evidence_ref"}, where="latency")
        number(record["latency"]["ms"], "latency.ms")
        text(record["latency"]["evidence_ref"], "latency.evidence_ref")
    if record.get("cost") is not None:
        cost = record["cost"]
        fields(cost, {"status"}, {"amount", "currency", "evidence_ref", "evidence_sha256"}, "cost")
        if cost["status"] not in ("verified", "unverified"):
            raise ValueError("invalid cost status")
        if "amount" in cost:
            cost_amount(cost["amount"])
        if "currency" in cost and (not isinstance(cost["currency"], str) or not re.fullmatch(r"[A-Z]{3}", cost["currency"])):
            raise ValueError("cost currency must be a three-letter uppercase currency code")
        if cost["status"] == "verified":
            if "amount" not in cost or "currency" not in cost:
                raise ValueError("verified cost requires amount and currency")
            text(cost.get("evidence_ref"), "verified cost evidence_ref")
            if record["mode"] != "synthetic" and not re.fullmatch(r"[0-9a-fA-F]{64}", str(cost.get("evidence_sha256", ""))):
                raise ValueError("non-synthetic verified cost requires evidence_sha256")


def validate_manifest(manifest):
    fields(manifest, {"schema_version", "evaluation_time", "runs"}, where="manifest")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise ValueError("unsupported manifest schema_version")
    if manifest["evaluation_time"] is not None:
        text(manifest["evaluation_time"], "evaluation_time")
        try:
            instant = datetime.fromisoformat(manifest["evaluation_time"].replace("Z", "+00:00"))
        except ValueError as exc:
            raise ValueError("evaluation_time must be ISO8601 with timezone") from exc
        if instant.tzinfo is None:
            raise ValueError("evaluation_time requires timezone")
    if not isinstance(manifest["runs"], dict):
        raise ValueError("runs must be a version_ref object")
    for ref, run in manifest["runs"].items():
        text(ref, "version_ref")
        fields(run, {"source_commit", "dataset_version", "model_provider", "model_version", "schema_version", "environment"},
               {"mode", "split", "reviewer"}, "run")
        for key in ("source_commit", "dataset_version", "model_provider", "model_version"):
            text(run[key], "run." + key)
        if run["schema_version"] != SCHEMA_VERSION:
            raise ValueError("unsupported run schema_version")
        if "mode" in run and run["mode"] not in MODES:
            raise ValueError("invalid manifest mode")
        if not isinstance(run["environment"], dict) or not run["environment"]:
            raise ValueError("run.environment must pin nonempty environment details")
        for key, value in run["environment"].items():
            text(key, "environment key"); text(value, "environment value")


def verify_commit(run, mode, source_repo):
    commit = run["source_commit"]
    if mode == "synthetic" and commit.startswith("synthetic:") and len(commit) > 10:
        return "synthetic_reference_not_a_git_commit"
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", commit):
        raise ValueError("non-synthetic source_commit must be a full Git SHA")
    if source_repo is None:
        raise ValueError("source_repo is required to verify the source commit")
    try:
        result = subprocess.run(["git", "-C", str(source_repo), "rev-parse", "--verify", commit + "^{commit}"],
                                capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValueError("could not verify source commit locally") from exc
    if result.returncode or result.stdout.strip().lower() != commit.lower():
        raise ValueError("source commit does not resolve to that exact commit in source_repo")
    return "verified_local_git_object"


def ratio(numerator, denominator, unit, unknown=0):
    return {"status": "unmeasured" if not denominator else ("partial" if unknown else "measured"),
            "value": numerator / denominator if denominator else None, "numerator": numerator,
            "denominator": denominator, "unit": unit, "unknown_count": unknown}


def verify_cost_evidence(cost, evidence_root):
    """Verify operator-supplied local evidence integrity, not independent billing."""
    if evidence_root is None:
        raise ValueError("evidence_root is required for non-synthetic verified cost")
    root = Path(evidence_root).resolve()
    relative = Path(cost["evidence_ref"])
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("cost evidence_ref must be a relative path within evidence_root")
    path = (root / relative).resolve()
    if root not in path.parents or not path.is_file():
        raise ValueError("cost evidence is missing or outside evidence_root")
    try:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise ValueError("cost evidence could not be read") from exc
    if digest != cost["evidence_sha256"].lower():
        raise ValueError("cost evidence_sha256 does not match local evidence")


def summarize_cost(records):
    subtotals = {}
    observed = 0
    evidence = []
    for record in records:
        cost = record.get("cost")
        if cost and cost["status"] == "verified":
            currency = cost["currency"]
            subtotals[currency] = subtotals.get(currency, Decimal(0)) + cost_amount(cost["amount"])
            observed += 1
            evidence.append({"case_id": record["case_id"], "evidence_ref": cost["evidence_ref"]})
    complete = bool(records) and observed == len(records) and len(subtotals) == 1
    currency = next(iter(subtotals)) if len(subtotals) == 1 else None
    return {"status": "measured" if complete else ("partial" if observed else "unmeasured"),
            "total": str(subtotals[currency]) if complete else None, "currency": currency,
            "verified_subtotals": {key: str(subtotals[key]) for key in sorted(subtotals)},
            "verified_count": observed, "utterance_count": len(records),
            "missing_or_unverified_count": len(records) - observed, "evidence": evidence,
            "scope": "operator-supplied evidence integrity only; no independent billing or invoice completeness verification"}


def facts_equal(actual, gold):
    # JSON numbers have no weight representation distinction; bools were rejected.
    if actual["weight_kg"] != gold["weight_kg"]:
        return False
    actual_other = {key: value for key, value in actual.items() if key != "weight_kg"}
    gold_other = {key: value for key, value in gold.items() if key != "weight_kg"}
    return json.dumps(actual_other, sort_keys=True, ensure_ascii=False) == json.dumps(gold_other, sort_keys=True, ensure_ascii=False)


def summarize_group(records, run, mode, ref, commit_status):
    counts = {"utterances": len(records), "reviewed_gold_utterances": 0, "excluded_gold_utterances": 0,
              "expected_completed_facts": 0, "actual_auto_commits": 0, "scored_auto_commits": 0,
              "excluded_auto_commits_unreviewed_gold": 0, "manual_commits": 0,
              "correct_auto_commits": 0, "wrong_auto_commits": 0, "missed_completed_facts": 0,
              "pending_utterances": 0}
    failures = []
    for record in records:
        actual = record["actual"]
        auto = [item for item in actual if item["decision"] == "COMMIT" and item["origin"] == "auto"]
        counts["actual_auto_commits"] += len(auto)
        counts["manual_commits"] += sum(item["decision"] == "COMMIT" and item["origin"] == "manual" for item in actual)
        pending = any(item["decision"] == "DEFER" and item["origin"] == "auto" for item in actual)
        counts["pending_utterances"] += pending
        correct = wrong = missed = 0
        if record["gold_status"] == "reviewed":
            counts["reviewed_gold_utterances"] += 1
            remaining = [item for item in record["expected_facts"] if item["fact"]["temporal_modality"] == "completed"]
            counts["expected_completed_facts"] += len(remaining)
            counts["scored_auto_commits"] += len(auto)
            for item in auto:
                matched = next((index for index, gold in enumerate(remaining)
                                if item["fact_id"] == gold["fact_id"] and facts_equal(item["fact"], gold["fact"])), None)
                if matched is None:
                    wrong += 1
                else:
                    correct += 1
                    remaining.pop(matched)
            missed = len(remaining)
        else:
            counts["excluded_gold_utterances"] += 1
            counts["excluded_auto_commits_unreviewed_gold"] += len(auto)
        counts["correct_auto_commits"] += correct
        counts["wrong_auto_commits"] += wrong
        counts["missed_completed_facts"] += missed
        flags = {key: record["adjudication"].get(key) for key in FLAGS}
        if wrong or missed or pending or any(value is True for value in flags.values()):
            failures.append({"case_id": record["case_id"], "recording_id": record["recording_id"],
                             "slices": record["slices"], "gold_status": record["gold_status"],
                             "wrong_commit_count": wrong, "missed_fact_count": missed,
                             "pending": pending, "adjudicated_errors": flags})
    metrics = {
        "correct_auto_commit": ratio(counts["correct_auto_commits"], counts["expected_completed_facts"], "completed_fact"),
        "wrong_commit": ratio(counts["wrong_auto_commits"], counts["scored_auto_commits"], "auto_commit"),
        "missed_fact": ratio(counts["missed_completed_facts"], counts["expected_completed_facts"], "completed_fact"),
        "defer_pending": ratio(counts["pending_utterances"], len(records), "utterance")}
    for key in ("correct_auto_commit", "wrong_commit", "missed_fact"):
        metrics[key]["excluded_gold_utterances"] = counts["excluded_gold_utterances"]
        if counts["excluded_gold_utterances"] and metrics[key]["status"] == "measured":
            metrics[key]["status"] = "partial"
    for key in FLAGS:
        known = [record["adjudication"].get(key) for record in records if record["adjudication"].get(key) is not None]
        metrics[key] = ratio(sum(value is True for value in known), len(known), "adjudicated_utterance", len(records) - len(known))
    observations = sorted(record["latency"]["ms"] for record in records if record.get("latency") is not None)
    for percentile in (50, 95):
        metrics["latency_p%d_ms" % percentile] = {
            "status": "unmeasured" if not observations else ("measured" if len(observations) == len(records) else "partial"),
            "value": observations[math.ceil(percentile * len(observations) / 100) - 1] if observations else None,
            "unit": "ms", "observation_count": len(observations), "missing_count": len(records) - len(observations),
            "method": "nearest_rank", "percentile": percentile}
    return {"version_ref": ref, "mode": mode, "run": run, "source_commit_status": commit_status,
            "synthetic_only": mode == "synthetic", "acceptance": "synthetic_calculation_only" if mode == "synthetic" else "exploratory_not_independent",
            "counts": counts, "metrics": metrics, "cost": summarize_cost(records), "failures": failures,
            "cases": [{"case_id": r["case_id"], "recording_id": r["recording_id"], "source": r["source"], "version_ref": r["version_ref"]} for r in records],
            "notes": ["Unreviewed/disputed gold is excluded from all fact accuracy denominators.",
                      "DEFER uses utterances; correct/missed uses completed facts; wrong COMMIT uses scored automatic commits.",
                      "No independent held-out acceptance is inferred from supplied audit metadata."]}


def evaluate(records, manifest, group_report=False, d04_audit=None, source_repo=None, evidence_root=None):
    """Return JSON-safe results; reject invalid input before writing any artifact."""
    validate_manifest(manifest)
    records = list(records)
    seen = set()
    groups = {}
    for record in records:
        validate_record(record)
        if record["mode"] != "synthetic" and (record.get("cost") or {}).get("status") == "verified":
            verify_cost_evidence(record["cost"], evidence_root)
        if record["case_id"] in seen:
            raise ValueError("duplicate case_id")
        seen.add(record["case_id"])
        if record["version_ref"] not in manifest["runs"]:
            raise ValueError("unknown version_ref")
        run = manifest["runs"][record["version_ref"]]
        if "mode" in run and run["mode"] != record["mode"]:
            raise ValueError("record mode conflicts with run mode")
        groups.setdefault((record["mode"], record["version_ref"]), []).append(record)
    if len(groups) > 1 and not group_report:
        raise ValueError("mixed modes/version_ref require explicit group_report")
    if records and manifest["evaluation_time"] is None:
        raise ValueError("nonempty evaluation requires evaluation_time")
    if not groups:
        if len(manifest["runs"]) > 1 and not group_report:
            raise ValueError("multiple empty versions require explicit group_report")
        for ref, run in manifest["runs"].items():
            mode = run.get("mode", "synthetic" if run["source_commit"].startswith("synthetic:") else "unmeasured")
            groups[(mode, ref)] = []
        if not groups:
            groups[("unmeasured", None)] = []
    results = []
    for (mode, ref), cases in sorted(groups.items(), key=lambda pair: str(pair[0])):
        run = manifest["runs"].get(ref)
        status = verify_commit(run, mode, source_repo) if cases else "unmeasured_no_cases"
        results.append(summarize_group(cases, run, mode, ref, status))
    return {"schema_version": "d05.report.v1", "metrics_version": METRICS_VERSION,
            "evaluator_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "runtime": {"python": sys.version.split()[0], "implementation": sys.implementation.name},
            "evaluation_time": manifest["evaluation_time"], "group_report": group_report,
            "independent_held_out_verified": False,
            "d04_audit_context": {"supplied": d04_audit is not None, "trusted_for_acceptance": False},
            "groups": results}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def parse_json(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite JSON number")))


def metric_display(metric):
    if metric["value"] is None:
        return "UNMEASURED"
    if "numerator" in metric:
        return "%g%% (%d/%d %s; %s)" % (100 * metric["value"], metric["numerator"], metric["denominator"], metric["unit"], metric["status"])
    return "%g ms (n=%d; %s)" % (metric["value"], metric["observation_count"], metric["status"])


def markdown_report(report):
    lines = ["# D05 offline evaluation", "", "Metrics version: `" + METRICS_VERSION + "`.", "",
             "Independent held-out acceptance: **not verified**. Actual system metrics require real logs and review."]
    for group in report["groups"]:
        lines += ["", "## " + str(group["version_ref"]) + " / " + group["mode"], "", "Acceptance: **" + group["acceptance"] + "**."]
        if group["synthetic_only"]:
            lines += ["", "**SYNTHETIC CALCULATION TEST ONLY — these are not real system metrics.**"]
        lines += ["", "| Metric | Result |", "| --- | --- |"]
        lines += ["| " + key + " | " + metric_display(value) + " |" for key, value in group["metrics"].items()]
        cost = group["cost"]
        cost_text = cost["total"] + " " + cost["currency"] if cost["total"] is not None else cost["status"].upper() + " (no verified total)"
        lines += ["| cost_if_verified | " + cost_text + " |", "", "Counts, exclusions, pinned versions, verified subtotals and anonymous failure slices: `report.json`."]
    lines += ["", "Report publication requires the responsible human's approval; no approval is generated here.", ""]
    return "\n".join(lines)


def write_results(report, output):
    output = Path(output)
    if output.exists():
        raise ValueError("output must be a new directory; existing artifacts are never overwritten")
    output.mkdir(parents=True, mode=0o700)
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    (output / "report.md").write_text(markdown_report(report), encoding="utf-8")
    with (output / "EVAL_RESULTS.csv").open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for group in report["groups"]:
            run = group["run"] or {}
            row = {key: run.get(key, "UNMEASURED") for key in ("dataset_version", "source_commit", "model_provider", "split", "reviewer")}
            row.update({"evaluation_time": report["evaluation_time"] or "UNMEASURED", "mode_mock_replay_real": group["mode"],
                        "sample_count": group["counts"]["utterances"], "notes": group["acceptance"] + "; see report.json denominators, versions and cost evidence"})
            for key in ("correct_auto_commit", "wrong_commit", "missed_fact", "defer_pending", "semantic_error", "fact_engine_error", "latency_p50_ms", "latency_p95_ms"):
                row[key] = metric_display(group["metrics"][key])
            row["asr_error"] = metric_display(group["metrics"]["asr_transcription_error"])
            cost = group["cost"]
            row["cost_if_verified"] = cost["total"] + " " + cost["currency"] if cost["total"] is not None else cost["status"].upper()
            writer.writerow(row)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("evaluate", help="evaluate offline JSONL records")
    command.add_argument("--input", required=True, type=Path)
    command.add_argument("--manifest", required=True, type=Path)
    command.add_argument("--output", required=True, type=Path)
    command.add_argument("--source-repo", type=Path)
    command.add_argument("--group-report", action="store_true")
    command.add_argument("--d04-audit", type=Path)
    command.add_argument("--evidence-root", type=Path, help="private local root for operator-supplied cost evidence")
    args = parser.parse_args(argv)
    try:
        manifest = parse_json(args.manifest.read_text(encoding="utf-8-sig"))
        records = []
        for line_number, raw in enumerate(args.input.read_text(encoding="utf-8-sig").splitlines(), 1):
            if not raw.strip():
                continue
            try:
                records.append(parse_json(raw))
            except ValueError as exc:
                raise ValueError("input line %d: %s" % (line_number, exc)) from exc
        audit = parse_json(args.d04_audit.read_text(encoding="utf-8-sig")) if args.d04_audit else None
        report = evaluate(records, manifest, args.group_report, audit, args.source_repo, args.evidence_root)
        report["input_sha256"] = hashlib.sha256(args.input.read_bytes()).hexdigest()
        report["manifest_sha256"] = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
        if args.d04_audit:
            report["d04_audit_context"]["sha256"] = hashlib.sha256(args.d04_audit.read_bytes()).hexdigest()
        write_results(report, args.output)
    except (ValueError, OSError) as exc:
        parser.exit(2, "D05 validation failed: " + str(exc) + "\n")
    print("D05 offline report written; independent acceptance not verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
