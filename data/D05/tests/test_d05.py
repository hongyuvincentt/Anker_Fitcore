"""Synthetic, temporary records only; no real transcripts, audio, or gold."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "d05.py"
if SCRIPT.exists():
    SPEC = importlib.util.spec_from_file_location("d05", SCRIPT)
    d05 = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(d05)
else:
    d05 = None


def fact(fact_id="set-1", reps=8, **changes):
    value = {"exercise": "synthetic_squat", "weight_kg": 20, "reps": reps,
             "temporal_modality": "completed", "time": None, "target": None}
    value.update(changes)
    return {"fact_id": fact_id, "fact": value}


def commit(fact_id="set-1", reps=8, origin="auto", **changes):
    return dict(fact(fact_id, reps, **changes), decision="COMMIT", origin=origin)


def manifest():
    return {"schema_version": "d05.input.v1", "evaluation_time": "2026-10-16T00:00:00Z",
            "runs": {"fixture-v1": {"source_commit": "synthetic:fixture-v1",
                     "dataset_version": "synthetic-fixture-v1", "model_provider": "none",
                     "model_version": "not_used", "schema_version": "d05.input.v1",
                     "environment": {"python": "3.9+", "platform": "synthetic"}}}}


def record(case_id="case-1"):
    return {"schema_version": "d05.input.v1", "case_id": case_id,
            "recording_id": "synthetic-recording-" + case_id, "version_ref": "fixture-v1",
            "mode": "synthetic", "source": "synthetic_fixture", "gold_status": "reviewed",
            "expected_facts": [fact()], "actual": [commit()],
            "adjudication": {"status": "unreviewed"},
            "slices": {"device": "synthetic", "speaker": "synthetic", "noise": "clean",
                       "action": "synthetic_squat", "numeric_ambiguity": "none"}}


class D05Tests(unittest.TestCase):
    def evaluate(self, records, meta=None, **kwargs):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        return d05.evaluate(records, meta or manifest(), **kwargs)

    def metrics(self, records, **kwargs):
        return self.evaluate(records, **kwargs)["groups"][0]["metrics"]

    def test_correct_auto_commit_counts_completed_facts(self):
        m = self.metrics([record()])
        self.assertEqual((m["correct_auto_commit"]["numerator"], m["correct_auto_commit"]["denominator"]), (1, 1))
        self.assertEqual(m["correct_auto_commit"]["value"], 1)
        self.assertEqual(m["wrong_commit"]["value"], 0)

    def test_wrong_commit_is_wrong_and_gold_remains_missed(self):
        r = record(); r["actual"] = [commit(reps=9)]
        m = self.metrics([r])
        self.assertEqual(m["wrong_commit"]["value"], 1)
        self.assertEqual(m["missed_fact"]["value"], 1)

    def test_duplicate_auto_commit_is_extra_wrong(self):
        r = record(); r["actual"].append(commit())
        m = self.metrics([r])
        self.assertEqual((m["correct_auto_commit"]["numerator"], m["wrong_commit"]["numerator"], m["wrong_commit"]["denominator"]), (1, 1, 2))
        self.assertEqual(m["missed_fact"]["numerator"], 0)

    def test_multiple_facts_and_extra_commit_have_different_denominators(self):
        r = record(); r["expected_facts"].append(fact("set-2", 5))
        r["actual"].append(commit("set-3", 7))
        m = self.metrics([r])
        self.assertEqual(m["correct_auto_commit"]["value"], 0.5)
        self.assertEqual(m["wrong_commit"]["value"], 0.5)
        self.assertEqual(m["missed_fact"]["value"], 0.5)

    def test_missing_auto_fact_is_omission(self):
        r = record(); r["actual"] = []
        m = self.metrics([r])
        self.assertEqual(m["missed_fact"]["value"], 1)
        self.assertIsNone(m["wrong_commit"]["value"])

    def test_manual_commit_is_excluded_and_cannot_rescue_auto_omission(self):
        r = record(); r["actual"] = [commit(origin="manual")]
        report = self.evaluate([r]); g = report["groups"][0]
        self.assertEqual(g["metrics"]["correct_auto_commit"]["numerator"], 0)
        self.assertEqual(g["metrics"]["missed_fact"]["numerator"], 1)
        self.assertEqual(g["counts"]["manual_commits"], 1)

    def test_pending_counts_utterances_once_not_facts(self):
        r = record(); r["actual"] = [{"decision": "DEFER", "origin": "auto"}] * 2
        r2 = record("case-2"); r2["actual"] = [{"decision": "REJECT", "origin": "auto"}]
        m = self.metrics([r, r2])
        self.assertEqual((m["defer_pending"]["numerator"], m["defer_pending"]["denominator"]), (1, 2))

    def test_unreviewed_gold_is_excluded_not_assumed_wrong(self):
        r = record(); r["gold_status"] = "unreviewed"; r["actual"] = [commit(reps=9)]
        g = self.evaluate([r])["groups"][0]
        self.assertEqual(g["counts"]["excluded_auto_commits_unreviewed_gold"], 1)
        self.assertEqual(g["metrics"]["wrong_commit"]["status"], "unmeasured")

    def test_reviewed_gold_with_unresolved_modality_is_rejected(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        for modality in ("unknown", None):
            with self.subTest(modality=modality):
                r = record()
                r["expected_facts"].append(fact("unresolved-set", temporal_modality=modality))
                with self.assertRaisesRegex(ValueError, "reviewed gold.*temporal_modality"):
                    self.evaluate([r])

    def test_unresolved_unreviewed_gold_remains_visibly_excluded(self):
        for modality in ("unknown", None):
            with self.subTest(modality=modality):
                r = record(); r["gold_status"] = "unreviewed"
                r["expected_facts"].append(fact("unresolved-set", temporal_modality=modality))
                g = self.evaluate([r])["groups"][0]
                self.assertEqual(g["counts"]["excluded_gold_utterances"], 1)
                self.assertEqual(g["metrics"]["correct_auto_commit"]["status"], "unmeasured")

    def test_resolved_planned_and_historical_gold_remain_valid(self):
        for modality in ("planned", "historical"):
            with self.subTest(modality=modality):
                r = record(); r["expected_facts"].append(fact("noncompleted-set", temporal_modality=modality))
                m = self.metrics([r])
                self.assertEqual(m["correct_auto_commit"]["denominator"], 1)
                self.assertEqual(m["correct_auto_commit"]["value"], 1)

    def test_noncompleted_gold_is_not_an_expected_completed_fact(self):
        r = record(); r["expected_facts"] = [fact(temporal_modality="planned")]
        r["actual"] = [commit(temporal_modality="planned")]
        m = self.metrics([r])
        self.assertIsNone(m["correct_auto_commit"]["value"])
        self.assertEqual(m["wrong_commit"]["value"], 1)

    def test_stable_fact_identity_and_exact_target_are_required(self):
        for field, value in [("fact_id", "different-set"), ("target", {"fact_id": "other"}),
                             ("time", {"session": "other"}), ("exercise", "other")]:
            with self.subTest(field=field):
                r = record()
                if field == "fact_id": r["actual"][0][field] = value
                else: r["actual"][0]["fact"][field] = value
                self.assertEqual(self.metrics([r])["wrong_commit"]["value"], 1)

    def test_empty_input_all_rates_latency_cost_unmeasured(self):
        report = self.evaluate([])
        g = report["groups"][0]
        self.assertEqual(g["counts"]["utterances"], 0)
        self.assertTrue(all(v["status"] == "unmeasured" for v in g["metrics"].values()))
        self.assertIsNone(g["cost"]["total"])

    def test_unknown_adjudication_is_distinct_from_false(self):
        r = record(); r["adjudication"] = {"status": "reviewed", "reviewer_id": "synthetic-reviewer", "asr_numeric_error": False}
        m = self.metrics([r])
        self.assertEqual(m["asr_numeric_error"]["value"], 0)
        self.assertEqual(m["semantic_error"]["status"], "unmeasured")
        self.assertEqual(m["semantic_error"]["unknown_count"], 1)

    def test_layered_errors_use_only_explicit_reviewed_flags(self):
        r = record(); r["adjudication"] = {"status": "reviewed", "reviewer_id": "synthetic-reviewer", "asr_transcription_error": True, "asr_numeric_error": True, "semantic_error": False, "fact_engine_error": True}
        r2 = record("case-2")
        m = self.metrics([r, r2])
        self.assertEqual((m["asr_numeric_error"]["numerator"], m["asr_numeric_error"]["denominator"], m["asr_numeric_error"]["unknown_count"]), (1, 1, 1))
        self.assertEqual(m["asr_numeric_error"]["status"], "partial")

    def test_nearest_rank_latency_percentiles_match_manual_calculation(self):
        records = []
        for i, ms in enumerate([1, 2, 3, 4, 100]):
            r = record("case-" + str(i)); r["latency"] = {"ms": ms, "evidence_ref": "synthetic:clock"}; records.append(r)
        m = self.metrics(records)
        self.assertEqual(m["latency_p50_ms"]["value"], 3)
        self.assertEqual(m["latency_p95_ms"]["value"], 100)
        self.assertEqual(m["latency_p95_ms"]["observation_count"], 5)
        self.assertEqual(m["latency_p95_ms"]["method"], "nearest_rank")

    def test_partial_latency_includes_coverage(self):
        r = record(); r["latency"] = {"ms": 0, "evidence_ref": "synthetic:clock"}
        m = self.metrics([r, record("case-2")])
        self.assertEqual(m["latency_p50_ms"]["status"], "partial")
        self.assertEqual(m["latency_p50_ms"]["observation_count"], 1)
        self.assertEqual(m["latency_p50_ms"]["missing_count"], 1)

    def test_verified_complete_cost_has_total_and_evidence(self):
        records = [record(), record("case-2")]
        for r, amount in zip(records, ["0.10", "0.20"]):
            r["cost"] = {"status": "verified", "amount": amount, "currency": "USD", "evidence_ref": "synthetic:bill"}
        c = self.evaluate(records)["groups"][0]["cost"]
        self.assertEqual(c["status"], "measured")
        self.assertEqual(c["total"], "0.30")
        self.assertEqual(c["currency"], "USD")

    def test_partial_cost_does_not_present_subtotal_as_total(self):
        r = record(); r["cost"] = {"status": "verified", "amount": "0", "currency": "USD", "evidence_ref": "synthetic:bill"}
        c = self.evaluate([r, record("case-2")])["groups"][0]["cost"]
        self.assertEqual(c["status"], "partial")
        self.assertIsNone(c["total"])
        self.assertEqual(c["verified_subtotals"]["USD"], "0")
        self.assertEqual(c["missing_or_unverified_count"], 1)

    def test_unverified_cost_does_not_count_even_with_amount(self):
        r = record(); r["cost"] = {"status": "unverified", "amount": "2", "currency": "USD"}
        c = self.evaluate([r])["groups"][0]["cost"]
        self.assertEqual(c["status"], "unmeasured")
        self.assertEqual(c["verified_subtotals"], {})

    def test_mixed_currencies_are_never_added(self):
        records = [record(), record("case-2")]
        for r, currency in zip(records, ["USD", "CNY"]):
            r["cost"] = {"status": "verified", "amount": "1", "currency": currency, "evidence_ref": "synthetic:bill"}
        c = self.evaluate(records)["groups"][0]["cost"]
        self.assertIsNone(c["total"])
        self.assertEqual(c["verified_subtotals"], {"CNY": "1", "USD": "1"})

    def test_duplicate_case_ids_rejected(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([record(), record()])

    def test_duplicate_gold_fact_ids_rejected(self):
        r = record(); r["expected_facts"].append(fact())
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([r])

    def test_invalid_numbers_rejected(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        for field, value in [("latency", math.nan), ("latency", -1), ("latency", True), ("weight_kg", math.inf), ("weight_kg", -1), ("reps", -1), ("reps", 1.5), ("cost", "NaN"), ("cost", "-1")]:
            with self.subTest(field=field, value=value):
                r = record()
                if field == "latency": r["latency"] = {"ms": value, "evidence_ref": "synthetic:clock"}
                elif field == "cost": r["cost"] = {"status": "verified", "amount": value, "currency": "USD", "evidence_ref": "synthetic:bill"}
                else: r["expected_facts"][0]["fact"][field] = value
                with self.assertRaises(ValueError): self.evaluate([r])

    def test_unreviewed_error_flags_cannot_claim_adjudication(self):
        r = record(); r["adjudication"]["semantic_error"] = False
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([r])

    def test_unknown_fields_rejected_to_prevent_silent_schema_loss(self):
        r = record(); r["actual"][0]["fact"]["weight_lb"] = 42
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([r])

    def test_mixed_modes_rejected_without_explicit_groups(self):
        r2 = record("case-2"); r2["mode"] = "text_simulation"; r2["source"] = "human_written"
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([record(), r2])

    def test_mixed_versions_rejected_without_explicit_groups(self):
        meta = manifest(); meta["runs"]["fixture-v2"] = copy.deepcopy(meta["runs"]["fixture-v1"])
        r2 = record("case-2"); r2["version_ref"] = "fixture-v2"
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([record(), r2], meta)
        self.assertEqual(len(self.evaluate([record(), r2], meta, group_report=True)["groups"]), 2)

    def test_unknown_version_and_schema_rejected(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        for field, value in [("version_ref", "missing"), ("schema_version", "v0")]:
            r = record(); r[field] = value
            with self.assertRaises(ValueError): self.evaluate([r])

    def test_fake_commit_rejected_for_real_audio(self):
        r = record(); r["mode"] = "real_audio"; r["source"] = "human_audio"
        meta = manifest(); meta["runs"]["fixture-v1"]["source_commit"] = "a" * 40
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError): self.evaluate([r], meta, source_repo=tmp)

    def test_fact_metric_status_is_partial_when_gold_is_excluded(self):
        r = record("case-2"); r["gold_status"] = "disputed"
        m = self.metrics([record(), r])
        self.assertEqual(m["correct_auto_commit"]["status"], "partial")
        self.assertEqual(m["correct_auto_commit"]["excluded_gold_utterances"], 1)

    def test_incomplete_completed_gold_cannot_be_scored_as_correct(self):
        r = record(); r["expected_facts"][0]["fact"]["exercise"] = None
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([r])

    def test_non_synthetic_verified_cost_requires_local_evidence_hash(self):
        r = record(); r["mode"] = "text_simulation"; r["source"] = "human_written"
        r["cost"] = {"status": "verified", "amount": "1", "currency": "USD", "evidence_ref": "bill.txt"}
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaisesRegex(ValueError, "evidence_sha256"):
            self.evaluate([r])

    def test_evidence_hash_and_path_must_match_local_file(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        self.assertTrue(hasattr(d05, "verify_cost_evidence"), "local cost evidence checking is not implemented")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "bill.txt").write_text("synthetic billing evidence", encoding="utf-8")
            import hashlib
            cost = {"evidence_ref": "bill.txt", "evidence_sha256": hashlib.sha256((root / "bill.txt").read_bytes()).hexdigest()}
            self.assertIsNone(d05.verify_cost_evidence(cost, root))
            cost["evidence_sha256"] = "0" * 64
            with self.assertRaises(ValueError): d05.verify_cost_evidence(cost, root)
            cost["evidence_ref"] = "../outside.txt"
            with self.assertRaises(ValueError): d05.verify_cost_evidence(cost, root)

    def test_supplied_passing_audit_never_grants_independent_acceptance(self):
        report = self.evaluate([record()], d04_audit={"passed": True, "frozen": True})
        self.assertFalse(report["independent_held_out_verified"])
        self.assertFalse(report["d04_audit_context"]["trusted_for_acceptance"])

    def test_empty_public_manifest_is_unmeasured_not_synthetic_measurement(self):
        report = self.evaluate([], {"schema_version": "d05.input.v1", "evaluation_time": None, "runs": {}})
        self.assertEqual(report["groups"][0]["mode"], "unmeasured")
        self.assertEqual(report["groups"][0]["counts"]["utterances"], 0)

    def test_boolean_and_number_in_structured_target_do_not_match(self):
        r = record(); r["expected_facts"][0]["fact"]["target"] = {"index": 1}
        r["actual"][0]["fact"]["target"] = {"index": True}
        self.assertEqual(self.metrics([r])["wrong_commit"]["value"], 1)

    def test_equal_numeric_weight_representations_match(self):
        r = record(); r["actual"][0]["fact"]["weight_kg"] = 20.0
        self.assertEqual(self.metrics([r])["correct_auto_commit"]["value"], 1)

    def test_reps_float_is_not_a_valid_integer(self):
        r = record(); r["actual"][0]["fact"]["reps"] = 8.0
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaises(ValueError): self.evaluate([r])

    def test_report_pins_evaluator_bytes_and_actual_runtime(self):
        import hashlib
        report = self.evaluate([record()])
        self.assertIn("evaluator_sha256", report)
        self.assertEqual(report["evaluator_sha256"], hashlib.sha256(SCRIPT.read_bytes()).hexdigest())
        self.assertEqual(report["runtime"]["python"], sys.version.split()[0])

    def test_malformed_enums_raise_validation_error(self):
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        for field in ["mode", "source", "gold_status"]:
            r = record(); r[field] = []
            with self.subTest(field=field), self.assertRaises(ValueError): self.evaluate([r])

    def test_null_cost_is_valid_and_unknown_in_non_synthetic_record(self):
        r = record(); r["mode"] = "text_simulation"; r["source"] = "human_written"; r["cost"] = None
        self.assertIsNotNone(d05, "D05 evaluator is not implemented")
        with self.assertRaisesRegex(ValueError, "source_commit"):
            self.evaluate([r])

    def test_cli_does_not_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "cases.jsonl").write_text("", encoding="utf-8")
            (root / "run.json").write_text(json.dumps(manifest()), encoding="utf-8")
            (root / "out").mkdir(); (root / "out" / "keep.txt").write_text("keep", encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "evaluate", "--input", str(root / "cases.jsonl"), "--manifest", str(root / "run.json"), "--output", str(root / "out")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual((root / "out" / "keep.txt").read_text(), "keep")

    def test_synthetic_report_is_labeled_and_not_independent(self):
        report = self.evaluate([record()])
        self.assertTrue(report["groups"][0]["synthetic_only"])
        self.assertEqual(report["groups"][0]["acceptance"], "synthetic_calculation_only")

    def test_failures_keep_anonymous_ids_and_slice_labels(self):
        r = record(); r["actual"] = [commit(reps=9)]
        f = self.evaluate([r])["groups"][0]["failures"][0]
        self.assertEqual(f["case_id"], "case-1")
        self.assertEqual(f["recording_id"], "synthetic-recording-case-1")
        self.assertEqual(f["slices"]["noise"], "clean")
        self.assertEqual(f["wrong_commit_count"], 1)

    def test_cli_empty_workspace_outputs_json_csv_and_markdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "cases.jsonl").write_text("", encoding="utf-8")
            (directory / "run.json").write_text(json.dumps(manifest()), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "evaluate", "--input", str(directory / "cases.jsonl"), "--manifest", str(directory / "run.json"), "--output", str(directory / "out")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads((directory / "out" / "report.json").read_text())
            self.assertEqual(payload["groups"][0]["metrics"]["correct_auto_commit"]["status"], "unmeasured")
            csv_text = (directory / "out" / "EVAL_RESULTS.csv").read_text(encoding="utf-8-sig")
            self.assertIn("dataset_version,source_commit,evaluation_time", csv_text)
            self.assertIn("UNMEASURED", csv_text)
            self.assertTrue((directory / "out" / "report.md").exists())

    def test_cli_invalid_json_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "cases.jsonl").write_text('{"schema_version":"d05.input.v1","schema_version":"bad"}\n', encoding="utf-8")
            (directory / "run.json").write_text(json.dumps(manifest()), encoding="utf-8")
            result = subprocess.run([sys.executable, str(SCRIPT), "evaluate", "--input", str(directory / "cases.jsonl"), "--manifest", str(directory / "run.json"), "--output", str(directory / "out")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("duplicate JSON key", result.stderr)
            self.assertFalse((directory / "out").exists())


if __name__ == "__main__":
    unittest.main()
