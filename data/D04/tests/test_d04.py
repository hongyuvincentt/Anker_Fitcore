"""Only temporary synthetic bytes and invented identifiers are used here."""
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "d04.py"
NOW = "2026-10-16T00:00:00+08:00"
FIELDS = "recording_id,speaker_id_pseudonym,session_id,scene_id,dataset_version,split_train_dev_heldout,frozen_at,sha256_audio,sha256_gold,split_review_owner,is_excluded,exclusion_reason".split(",")
GROUPS = "recording_id,environment_id,source_group_id,near_duplicate_group_id,source_kind,audio_path,gold_path,gold_review_status,gold_version,text_path".split(",")
EXPOSURE = "recording_id,use,used_at,evidence_ref".split(",")
ACCESS = "access_id,recording_id,accessed_at,actor_id,use,approval_ref,dataset_version".split(",")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def csv_write(path, fields, rows):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "D04 implementation is not present")
        spec = importlib.util.spec_from_file_location("d04", SCRIPT)
        self.d04 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.d04)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.splits = self.root / "SPLITS.csv"
        self.groups = self.root / "GROUPS.csv"
        self.history = self.root / "EXPOSURE.csv"
        self.eligibility = self.root / "eligibility.json"
        self.rows = []
        self.group_rows = []
        self.exposure_rows = []
        self.add_row("dev", "speaker-dev", "session-dev", "room-dev", "dev")
        self.add_row("heldout", "speaker-future", "session-heldout", "room-heldout", "heldout")
        self.save()

    def add_row(self, recording_id, speaker, session, environment, split):
        audio = self.root / (recording_id + ".wav")
        gold = self.root / (recording_id + ".gold")
        audio.write_bytes(("synthetic-audio-" + recording_id).encode())
        gold.write_bytes(("synthetic-gold-" + recording_id).encode())
        self.rows.append(dict(zip(FIELDS, [recording_id, speaker, session, "ordinary", "v1", split, "", digest(audio), digest(gold), "", "false", ""])))
        self.group_rows.append(dict(zip(GROUPS, [recording_id, environment, "source-" + recording_id, "near-" + recording_id, "human_recording", audio.name, gold.name, "reviewed", "gold-v1", ""])))

    def save(self):
        csv_write(self.splits, FIELDS, self.rows)
        csv_write(self.groups, GROUPS, self.group_rows)
        csv_write(self.history, EXPOSURE, self.exposure_rows)
        eligible = []
        for row, group in zip(self.rows, self.group_rows):
            eligible.append({"recording_id": row["recording_id"], "speaker_id_pseudonym": row["speaker_id_pseudonym"], "session_id": row["session_id"], "scene_id": row["scene_id"], "sha256": row["sha256_audio"], "quality_status": "human_verified", "recording_source": "human_recording"})
        self.eligibility.write_text(json.dumps({"purpose": "local", "as_of": NOW, "eligible": eligible, "excluded": []}), encoding="utf-8")

    def check(self, **kwargs):
        return self.d04.check_plan(self.splits, self.groups, self.history, artifact_root=self.root, eligibility_path=self.eligibility, as_of=NOW, **kwargs)

    def codes(self, result):
        return {error["code"] for error in result["errors"]}

    def freeze(self):
        for row in self.rows:
            if row["split_train_dev_heldout"] == "heldout":
                row["frozen_at"] = NOW
                row["split_review_owner"] = "independent-reviewer"
        self.save()
        document = {
            "schema_version": "d04-freeze-v1", "dataset_version": "v1", "gold_version": "gold-v1", "frozen_at": NOW,
            "preparer_id": "collector", "tuner_ids": ["developer"],
            "approval": {"decision": "approved", "reviewer_id": "independent-reviewer", "role": "independent_reviewer", "approved_at": NOW, "evidence_ref": "private-approval-log-1"},
            "files": {"splits": {"path": self.splits.name, "sha256": digest(self.splits)}, "groups": {"path": self.groups.name, "sha256": digest(self.groups)}, "exposure": {"path": self.history.name, "sha256": digest(self.history)}},
            "artifacts": {row["recording_id"]: {"audio_path": group["audio_path"], "audio_sha256": row["sha256_audio"], "gold_path": group["gold_path"], "gold_sha256": row["sha256_gold"], "text_path": "", "text_sha256": ""} for row, group in zip(self.rows, self.group_rows)},
            "gold_reviews": {"heldout": {"reviewer_ids": ["annotator", "independent-reviewer"], "reviewed_at": NOW, "gold_version": "gold-v1", "sha256_gold": self.rows[1]["sha256_gold"]}},
        }
        path = self.root / "freeze.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        csv_write(self.root / "ACCESS_LOG.csv", ACCESS, [])
        return path, document

    def verify(self, path, expected_hash=None):
        return self.d04.verify_freeze(path, expected_hash or digest(path), self.splits, self.groups, self.history, artifact_root=self.root, eligibility_path=self.eligibility, access_log_path=self.root / "ACCESS_LOG.csv", as_of=NOW)

    def test_clean_groups_are_reviewable_but_never_auto_frozen(self):
        result = self.check()
        self.assertEqual(result["status"], "clean")
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["coverage"]["speakers"], 2)
        self.assertEqual(result["acceptance"], "pending_independent_review")
        self.assertEqual(result["freeze"]["status"], "not_frozen")

    def test_empty_original_templates_are_not_a_frozen_dataset(self):
        self.rows, self.group_rows = [], []
        self.save()
        result = self.check()
        self.assertEqual(result["status"], "empty")
        self.assertEqual(result["coverage"]["recordings"], 0)
        self.assertEqual(result["acceptance"], "not_accepted")

    def test_single_speaker_only_is_exploratory(self):
        self.rows, self.group_rows = self.rows[:1], self.group_rows[:1]
        self.save()
        result = self.check()
        self.assertEqual(result["acceptance"], "exploratory_pilot_only")
        self.assertIn("insufficient_independent_data", self.codes(result))

    def test_train_and_dev_share_development_groups(self):
        self.add_row("train", "speaker-dev", "session-dev", "room-dev", "train")
        self.save()
        self.assertEqual(self.check()["errors"], [])

    def test_speaker_session_environment_overlap_each_blocks_heldout(self):
        for field, target in (("speaker_id_pseudonym", "speaker_overlap"), ("session_id", "session_overlap")):
            with self.subTest(field=field):
                original = self.rows[1][field]
                self.rows[1][field] = self.rows[0][field]
                self.save()
                self.assertIn(target, self.codes(self.check()))
                self.rows[1][field] = original
        self.group_rows[1]["environment_id"] = self.group_rows[0]["environment_id"]
        self.save()
        self.assertIn("environment_overlap", self.codes(self.check()))

    def test_semantic_scene_does_not_make_real_environments_overlap(self):
        self.assertEqual(self.rows[0]["scene_id"], self.rows[1]["scene_id"])
        self.assertNotIn("environment_overlap", self.codes(self.check()))

    def test_unknown_environment_and_missing_mapping_block(self):
        self.group_rows[1]["environment_id"] = "UNKNOWN"
        self.save()
        self.assertIn("missing_environment", self.codes(self.check()))
        self.group_rows = self.group_rows[:1]
        self.save()
        self.assertIn("missing_group", self.codes(self.check()))

    def test_shared_source_or_near_group_blocks(self):
        for field, code in (("source_group_id", "source_overlap"), ("near_duplicate_group_id", "near_duplicate_overlap")):
            with self.subTest(field=field):
                original = self.group_rows[1][field]
                self.group_rows[1][field] = self.group_rows[0][field]
                self.save()
                self.assertIn(code, self.codes(self.check()))
                self.group_rows[1][field] = original

    def test_shared_audio_and_gold_hashes_block(self):
        for column, path_field, code in (("sha256_audio", "audio_path", "audio_hash_overlap"), ("sha256_gold", "gold_path", "gold_hash_overlap")):
            with self.subTest(column=column):
                old = self.rows[1][column]
                target = self.root / self.group_rows[1][path_field]
                old_bytes = target.read_bytes()
                target.write_bytes((self.root / self.group_rows[0][path_field]).read_bytes())
                self.rows[1][column] = self.rows[0][column]
                self.save()
                self.assertIn(code, self.codes(self.check()))
                self.rows[1][column] = old
                target.write_bytes(old_bytes)

    def test_actual_text_near_duplicates_block_without_manual_group_match(self):
        for index, text in enumerate(("卧推四十公斤完成了十次", "卧推四十公斤完成了九次")):
            path = self.root / (str(index) + ".txt")
            path.write_text(text, encoding="utf-8")
            self.group_rows[index]["text_path"] = path.name
        self.save()
        self.assertIn("text_near_duplicate_overlap", self.codes(self.check()))

    def test_text_matcher_handles_unicode_and_punctuation(self):
        self.assertEqual(self.d04.text_duplicate_kind(" AＢ， c！", "ab c"), "normalized_exact")
        self.assertEqual(self.d04.text_duplicate_kind("bench press forty kilograms ten times", "bench press forty kilograms nine times"), "near_duplicate")
        self.assertIsNone(self.d04.text_duplicate_kind("abc", "xyz"))

    def test_development_regression_example_exposure_blocks_heldout(self):
        for usage in ("development", "regression", "example", "train", "dev", "prompt", "tuning"):
            with self.subTest(usage=usage):
                self.exposure_rows = [{"recording_id": "heldout", "use": usage, "used_at": NOW, "evidence_ref": "local-log"}]
                self.save()
                self.assertIn("heldout_previously_exposed", self.codes(self.check()))

    def test_development_exposure_of_derived_family_also_blocks(self):
        self.add_row("ancestor", "other-speaker", "other-session", "other-room", "dev")
        self.rows[2]["is_excluded"] = "true"
        self.rows[2]["exclusion_reason"] = "earlier development example"
        self.group_rows[2]["source_group_id"] = self.group_rows[1]["source_group_id"]
        self.exposure_rows = [{"recording_id": "ancestor", "use": "example", "used_at": NOW, "evidence_ref": "local-log"}]
        self.save()
        self.assertIn("heldout_family_previously_exposed", self.codes(self.check()))

    def retained_development_exposure(self, shared_field):
        self.add_row("previously-exposed", "history-speaker", "history-session", "history-room", "heldout")
        prior, candidate = self.rows[-1], self.rows[1]
        prior["is_excluded"] = "true"
        prior["exclusion_reason"] = "development material retained as excluded history"
        if shared_field == "environment_id":
            self.group_rows[-1][shared_field] = self.group_rows[1][shared_field]
        else:
            prior[shared_field] = candidate[shared_field]
        self.exposure_rows = [{"recording_id": prior["recording_id"], "use": "example", "used_at": NOW, "evidence_ref": "historical-development-log"}]
        self.save()

    def test_excluded_relabelled_development_history_blocks_same_speaker(self):
        self.retained_development_exposure("speaker_id_pseudonym")
        self.assertIn("heldout_family_previously_exposed", self.codes(self.check()))

    def test_excluded_relabelled_development_history_blocks_same_session(self):
        self.retained_development_exposure("session_id")
        self.assertIn("heldout_family_previously_exposed", self.codes(self.check()))

    def test_excluded_relabelled_development_history_blocks_same_environment(self):
        self.retained_development_exposure("environment_id")
        self.assertIn("heldout_family_previously_exposed", self.codes(self.check()))

    def test_approval_record_cannot_freeze_excluded_development_identity_overlap(self):
        self.retained_development_exposure("speaker_id_pseudonym")
        path, document = self.freeze()
        result = self.verify(path)
        self.assertIn("heldout_family_previously_exposed", self.codes(result))
        self.assertEqual(result["freeze"]["status"], "not_frozen")

    def test_actual_artifacts_hashes_and_local_eligibility_are_required(self):
        (self.root / "heldout.wav").write_bytes(b"tampered")
        self.assertIn("audio_hash_mismatch", self.codes(self.check()))
        self.eligibility.write_text(json.dumps({"purpose": "team", "as_of": NOW, "eligible": [], "excluded": []}), encoding="utf-8")
        self.assertIn("local_eligibility_required", self.codes(self.check()))

    def test_missing_or_stale_eligibility_never_accepted(self):
        result = self.d04.check_plan(self.splits, self.groups, self.history, artifact_root=self.root, as_of=NOW)
        self.assertIn("local_eligibility_required", self.codes(result))
        report = json.loads(self.eligibility.read_text())
        report["as_of"] = "2026-10-15T12:00:00+08:00"
        self.eligibility.write_text(json.dumps(report), encoding="utf-8")
        self.assertIn("stale_eligibility", self.codes(self.check()))

    def test_future_as_of_cannot_validate_forecast_consent(self):
        result = self.d04.check_plan(self.splits, self.groups, self.history, artifact_root=self.root, eligibility_path=self.eligibility, as_of="2099-01-01T00:00:00+00:00")
        self.assertIn("invalid_as_of", self.codes(result))

    def test_supplied_reference_text_cannot_be_empty(self):
        path = self.root / "empty.txt"
        path.write_text(" \n", encoding="utf-8")
        self.group_rows[1]["text_path"] = path.name
        self.save()
        self.assertIn("empty_reference_text", self.codes(self.check()))

    def test_unreviewed_real_recording_or_changed_identity_is_ineligible(self):
        report = json.loads(self.eligibility.read_text())
        report["eligible"][1]["quality_status"] = "needs_review"
        self.eligibility.write_text(json.dumps(report), encoding="utf-8")
        self.assertIn("recording_ineligible", self.codes(self.check()))
        report["eligible"][1]["quality_status"] = "human_verified"
        report["eligible"][1]["speaker_id_pseudonym"] = "wrong-person"
        self.eligibility.write_text(json.dumps(report), encoding="utf-8")
        self.assertIn("eligibility_identity_mismatch", self.codes(self.check()))

    def test_unsafe_or_symlink_artifact_paths_rejected(self):
        for pointer in ("../outside.wav", str(self.root / "heldout.wav")):
            with self.subTest(pointer=pointer):
                self.group_rows[1]["audio_path"] = pointer
                self.save()
                self.assertIn("unsafe_artifact_path", self.codes(self.check()))
        (self.root / "alias.wav").symlink_to(self.root / "heldout.wav")
        self.group_rows[1]["audio_path"] = "alias.wav"
        self.save()
        self.assertIn("unsafe_artifact_path", self.codes(self.check()))

    def test_schema_duplicate_mapping_or_unknown_exposure_rejected(self):
        csv_write(self.splits, FIELDS[:-1], [{key: value for key, value in row.items() if key != FIELDS[-1]} for row in self.rows])
        self.assertIn("invalid_schema", self.codes(self.check()))
        self.save()
        self.group_rows.append(dict(self.group_rows[0]))
        self.save()
        self.assertIn("duplicate_group", self.codes(self.check()))
        self.group_rows.pop()
        self.exposure_rows = [{"recording_id": "missing", "use": "example", "used_at": NOW, "evidence_ref": "log"}]
        self.save()
        self.assertIn("unknown_exposure_recording", self.codes(self.check()))

    def test_freeze_requires_external_trusted_hash_and_approval(self):
        path, document = self.freeze()
        self.assertEqual(self.verify(path)["freeze"]["status"], "verified_approval_record")
        result = self.d04.verify_freeze(path, "", self.splits, self.groups, self.history, artifact_root=self.root, eligibility_path=self.eligibility, as_of=NOW)
        self.assertIn("trusted_freeze_hash_required", self.codes(result))
        document["approval"]["decision"] = "pending"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertIn("freeze_approval_required", self.codes(self.verify(path)))

    def test_self_approval_or_no_independent_gold_review_blocks_freeze(self):
        path, document = self.freeze()
        document["approval"]["reviewer_id"] = "collector"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertIn("freeze_approval_not_independent", self.codes(self.verify(path)))
        document["approval"]["reviewer_id"] = "independent-reviewer"
        document["gold_reviews"]["heldout"]["reviewer_ids"] = ["annotator", "annotator"]
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertIn("gold_review_required", self.codes(self.verify(path)))

    def test_metadata_and_artifact_tampering_detected(self):
        path, document = self.freeze()
        original = digest(path)
        document["dataset_version"] = "v2"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertIn("freeze_hash_mismatch", self.codes(self.verify(path, original)))
        path, document = self.freeze()
        (self.root / "heldout.gold").write_bytes(b"changed")
        self.assertIn("gold_hash_mismatch", self.codes(self.verify(path)))

    def test_frozen_inventory_cannot_add_remove_or_redirect_artifacts(self):
        for change in ("missing", "extra", "redirect"):
            with self.subTest(change=change):
                path, document = self.freeze()
                if change == "missing":
                    document["artifacts"].pop("heldout")
                elif change == "extra":
                    document["artifacts"]["new"] = document["artifacts"]["dev"]
                else:
                    document["artifacts"]["heldout"]["audio_path"] = "dev.wav"
                path.write_text(json.dumps(document), encoding="utf-8")
                self.assertIn("frozen_inventory_mismatch", self.codes(self.verify(path)))

    def test_current_consent_is_rechecked_after_freeze(self):
        path, document = self.freeze()
        report = json.loads(self.eligibility.read_text())
        report["eligible"] = report["eligible"][:1]
        report["excluded"] = [{"recording_id": "heldout", "reason": "withdrawn"}]
        self.eligibility.write_text(json.dumps(report), encoding="utf-8")
        result = self.verify(path)
        self.assertIn("recording_ineligible", self.codes(result))
        self.assertEqual(result["freeze"]["status"], "not_frozen")

    def test_cli_is_offline_json_and_does_not_modify_inputs(self):
        paths = [self.splits, self.groups, self.history, self.eligibility, self.root / "heldout.wav", self.root / "heldout.gold"]
        before = {str(path): digest(path) for path in paths}
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "check", "--splits", str(self.splits), "--groups", str(self.groups), "--exposure", str(self.history), "--artifact-root", str(self.root), "--eligibility", str(self.eligibility), "--as-of", NOW], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "clean")
        self.assertEqual(before, {str(path): digest(path) for path in paths})

    def test_invalid_identifier_is_not_echoed_as_private_content(self):
        self.rows[1]["recording_id"] = "private sample sentence with spaces"
        self.save()
        result = self.check()
        self.assertIn("invalid_identifier", self.codes(result))
        self.assertNotIn("private sample sentence", json.dumps(result))

    def test_invalid_coverage_categories_do_not_echo_private_content(self):
        self.rows[1]["scene_id"] = "private sample sentence scene"
        self.rows[1]["split_train_dev_heldout"] = "private sample sentence split"
        self.group_rows[1]["source_kind"] = "private sample sentence source"
        self.save()
        result = self.check()
        self.assertTrue(result["errors"])
        self.assertNotIn("private sample sentence", json.dumps(result))

    def test_a_synthetic_heldout_is_not_human_independent_evidence(self):
        self.group_rows[1]["source_kind"] = "synthetic"
        self.save()
        result = self.check()
        self.assertIn("nonhuman_heldout", self.codes(result))
        self.assertEqual(result["acceptance"], "blocked")

    def test_synthetic_development_speaker_cannot_make_human_coverage_sufficient(self):
        self.group_rows[0]["source_kind"] = "synthetic"
        self.save()
        result = self.check()
        self.assertEqual(result["coverage"]["speakers"], 1)
        self.assertEqual(result["coverage"]["human_recordings"], 1)
        self.assertEqual(result["acceptance"], "exploratory_pilot_only")

    def test_freeze_rejects_a_future_or_unreviewed_gold_record(self):
        path, document = self.freeze()
        document["gold_reviews"]["heldout"]["reviewed_at"] = "2026-10-17T12:00:00+08:00"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertIn("gold_review_after_freeze", self.codes(self.verify(path)))
        self.group_rows[1]["gold_review_status"] = "needs_review"
        self.save()
        self.assertIn("gold_review_required", self.codes(self.verify(path)))

    def test_original_split_template_header_is_unchanged(self):
        original = Path(__file__).resolve().parents[3] / "reference" / "task-package" / "templates" / "SPLITS.csv"
        delivered = SCRIPT.parents[1] / "templates" / "SPLITS.csv"
        self.assertTrue(delivered.is_file())
        self.assertEqual(delivered.read_bytes(), original.read_bytes())

    def test_freeze_requires_current_access_ledger(self):
        path, document = self.freeze()
        result = self.d04.verify_freeze(path, digest(path), self.splits, self.groups, self.history, artifact_root=self.root, eligibility_path=self.eligibility, as_of=NOW)
        self.assertIn("current_access_log_required", self.codes(result))

    def test_cli_rejects_development_use_recorded_after_freeze(self):
        path, document = self.freeze()
        ledger = self.root / "ACCESS_LOG.csv"
        csv_write(ledger, ACCESS, [{"access_id": "access-1", "recording_id": "heldout", "accessed_at": NOW, "actor_id": "developer", "use": "prompt", "approval_ref": "private-log", "dataset_version": "v1"}])
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "verify-freeze", "--freeze", str(path), "--freeze-sha256", digest(path), "--splits", str(self.splits), "--groups", str(self.groups), "--exposure", str(self.history), "--artifact-root", str(self.root), "--eligibility", str(self.eligibility), "--as-of", NOW, "--access-log", str(ledger)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("heldout_access_contamination", self.codes(json.loads(result.stdout)))


if __name__ == "__main__":
    unittest.main()
