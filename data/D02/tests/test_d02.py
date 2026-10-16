"""Offline workflow tests. Every recording/consent/text is temporary synthetic data."""
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import wave


BASE = Path(__file__).resolve().parents[1]
SCRIPT = BASE / "scripts" / "d02.py"
CONSENT = "consent_id,speaker_id_pseudonym,consent_timestamp,recording_allowed,internal_team_use_allowed,aws_model_processing_allowed,share_scope,retention_until,withdrawal_method,consent_status,withdrawn_at,verification_reviewer,notes_no_pii".split(",")
MANIFEST = "recording_id,speaker_id_pseudonym,consent_id,session_id,scene_id,recorded_at,device_type,recording_source,sample_rate_hz,channels,bits_per_sample,duration_sec,size_bytes,sha256,private_storage_pointer,quality_status,label_status,data_split,retention_status".split(",")
FIELDS = "recording_id,segment_index,reference_text,asr_hypothesis_separate,intent,exercise,weight_kg,reps,set_index,tense_or_modality,is_correction,target_set_reference,subjective_state,ambiguity_type,gold_decision,annotator_id_pseudonym,reviewer_id_pseudonym,review_status,gold_version,evidence_reference,change_reason".split(",")


def write_csv(path, fields, rows):
    with path.open("w", encoding="utf-8-sig", newline="") as out:
        writer = csv.DictWriter(out, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


class AnnotationWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="d02-synthetic-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir(mode=0o700)
        (self.source / "audio").mkdir(mode=0o700)
        self.audio = self.source / "audio" / "TEST-R01.wav"
        with wave.open(str(self.audio), "wb") as out:
            out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            out.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(i * .17))) for i in range(3200)))
        self.sha = hashlib.sha256(self.audio.read_bytes()).hexdigest()
        self.consent = dict.fromkeys(CONSENT, "")
        self.consent.update(consent_id="TEST-C01", speaker_id_pseudonym="TEST-S01", consent_timestamp="2026-10-01T10:00:00+08:00", recording_allowed="true", internal_team_use_allowed="false", aws_model_processing_allowed="false", share_scope="local", retention_until="2026-10-31", withdrawal_method="synthetic-only", consent_status="granted", verification_reviewer="TEST-OWNER")
        self.recording = dict.fromkeys(MANIFEST, "")
        self.recording.update(recording_id="TEST-R01", speaker_id_pseudonym="TEST-S01", consent_id="TEST-C01", session_id="TEST-SESSION", scene_id="ordinary", recorded_at="2026-10-15T10:00:00+08:00", device_type="synthetic_fixture", recording_source="human_recording", sample_rate_hz="16000", channels="1", bits_per_sample="16", duration_sec="0.2", size_bytes=str(self.audio.stat().st_size), sha256=self.sha, private_storage_pointer="audio/TEST-R01.wav", quality_status="human_verified", label_status="unlabelled", data_split="unassigned", retention_status="active")
        self.save_source()
        self.root = self.base / "annotations"
        self.input = self.base / "input.csv"
        self.meta_file = self.base / "revision.json"
        self.rows = [dict(zip(FIELDS, ["TEST-R01", "1", "SYNTHETIC ONLY", "", "record_set", "squat", "20", "8", "1", "completed", "false", "UNKNOWN", "UNKNOWN", "none", "COMMIT", "TEST-LHY", "", "draft", "v1", "audio:TEST-R01#t=0,0.2", "initial synthetic test draft"]))]
        self.meta = {"schema_version": 1, "recording_id": "TEST-R01", "revision_id": "REV-1", "parent_revision_id": None, "actor_id_pseudonym": "TEST-LHY", "at": "2026-10-16T10:00:00+08:00", "event": "draft", "reason": "synthetic test only", "source_listened": True, "source_sha256": self.sha, "segments": [{"segment_index": 1, "start_sec": 0, "end_sec": 0.2, "context": [], "correction_target": "UNKNOWN"}], "adjudicator_id_pseudonym": ""}

    def save_source(self):
        write_csv(self.source / "CONSENT_REGISTER.csv", CONSENT, [self.consent])
        write_csv(self.source / "WAV_MANIFEST.csv", MANIFEST, [self.recording])

    def call(self, command, *args, ok=True):
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), command, "--root", str(self.root), "--source-root", str(self.source), "--as-of", "2026-10-16", *map(str, args)], text=True, capture_output=True)
        self.assertEqual(process.returncode, 0 if ok else 2, process.stdout + process.stderr)
        try:
            return json.loads(process.stdout if ok else process.stderr)
        except ValueError:
            self.fail("CLI requires sanitized JSON results/errors: " + process.stderr)

    def init(self):
        return self.call("init", "--local-annotator", "TEST-LHY")

    def revise(self, ok=True, expected="NONE"):
        write_csv(self.input, FIELDS, self.rows)
        self.meta_file.write_text(json.dumps(self.meta), encoding="utf-8")
        return self.call("revise", "--input", self.input, "--metadata", self.meta_file, "--expected-revision", expected, ok=ok)

    def test_init_is_empty_private_and_refuses_overwrite(self):
        result = self.init()
        self.assertEqual(result["annotations"], 0)
        with (self.root / "reference" / "ANNOTATIONS.csv").open(encoding="utf-8-sig", newline="") as inp:
            reader = csv.DictReader(inp)
            self.assertEqual(reader.fieldnames, FIELDS)
            self.assertEqual(list(reader), [])
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertIn("exists", self.call("init", "--local-annotator", "TEST-LHY", ok=False)["error"])

    def test_queue_does_not_promote_pending_source_or_print_private_content(self):
        self.init()
        self.recording["quality_status"] = "needs_review"
        self.save_source()
        result = self.call("queue")
        self.assertEqual(result["eligible_recordings"], 0)
        self.assertEqual(result["excluded"][0]["reason"], "human_review_required")
        self.assertNotIn(str(self.source), json.dumps(result))
        self.assertIn("eligible", self.revise(ok=False)["error"])
        self.assertEqual(self.recording["quality_status"], "needs_review")

    def test_local_draft_and_unknown_remain_unreviewed(self):
        self.init()
        self.rows[0].update(weight_kg="UNKNOWN", reps="UNKNOWN", ambiguity_type="numeric_unclear", gold_decision="DEFER", review_status="needs_review")
        result = self.revise()
        self.assertEqual(result["segments"], 1)
        checked = self.call("validate")
        self.assertEqual(checked["draft_segments"], 1)
        self.assertEqual(checked["reviewed_segments"], 0)
        self.assertEqual(checked["frozen_segments"], 0)
        self.assertEqual(self.audio.read_bytes()[:4], b"RIFF")

    def test_multi_action_and_correction_preserve_context_and_target(self):
        self.init()
        second = dict(self.rows[0], segment_index="2", intent="correct_set", is_correction="true", target_set_reference="TEST-R01:1", gold_decision="CORRECT", reps="6")
        self.rows.append(second)
        self.meta["segments"].append({"segment_index": 2, "start_sec": 0, "end_sec": 0.2, "context": ["TEST-R01:1"], "correction_target": "TEST-R01:1"})
        self.revise()
        self.assertEqual(self.call("validate")["segments"], 2)

    def test_future_or_hypothetical_correction_cannot_be_final_correction(self):
        self.init()
        self.rows.append(dict(self.rows[0], segment_index="2", intent="correct_set", is_correction="true", target_set_reference="TEST-R01:1", gold_decision="CORRECT"))
        self.meta["segments"].append({"segment_index": 2, "start_sec": 0, "end_sec": 0.2, "context": ["TEST-R01:1"], "correction_target": "TEST-R01:1"})
        for modality in ("planned", "hypothetical", "UNKNOWN"):
            self.rows[1]["tense_or_modality"] = modality
            with self.subTest(modality=modality):
                self.assertIn("correction", self.revise(ok=False)["error"])

    def test_unknown_correction_target_cannot_commit(self):
        self.init()
        self.rows[0].update(intent="correct_set", is_correction="true", gold_decision="CORRECT")
        self.assertIn("correction", self.revise(ok=False)["error"])
        self.rows[0].update(gold_decision="DEFER", ambiguity_type="target_unclear", review_status="needs_review")
        self.revise()

    def test_later_revision_cannot_invalidate_another_recordings_correction_target(self):
        self.init()
        original_rows, original_meta = json.loads(json.dumps(self.rows)), json.loads(json.dumps(self.meta))
        self.revise()
        other_audio = self.source / "audio" / "TEST-R02.wav"
        other_audio.write_bytes(self.audio.read_bytes()[:-2] + struct.pack("<h", 123))
        other_sha = hashlib.sha256(other_audio.read_bytes()).hexdigest()
        other_recording = dict(self.recording, recording_id="TEST-R02", sha256=other_sha, private_storage_pointer="audio/TEST-R02.wav")
        write_csv(self.source / "WAV_MANIFEST.csv", MANIFEST, [self.recording, other_recording])
        self.rows[0].update(recording_id="TEST-R02", intent="correct_set", is_correction="true", target_set_reference="TEST-R01:1", gold_decision="CORRECT", evidence_reference="audio:TEST-R02#t=0,0.2")
        self.meta.update(recording_id="TEST-R02", revision_id="REV-2", source_sha256=other_sha)
        self.meta["segments"][0]["correction_target"] = "TEST-R01:1"
        self.revise()
        self.rows, self.meta = original_rows, original_meta
        self.rows[0].update(intent="plan", tense_or_modality="planned", gold_decision="DEFER", gold_version="v2")
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-1", event="revise")
        self.assertIn("correction", self.revise(ok=False, expected="REV-1")["error"])

    def test_plan_history_and_nontraining_never_commit(self):
        self.init()
        for modality, intent in (("planned", "plan"), ("historical", "record_set"), ("non_training", "non_training")):
            self.rows[0].update(tense_or_modality=modality, intent=intent)
            with self.subTest(modality=modality):
                self.assertIn("COMMIT", self.revise(ok=False)["error"])

    def test_plan_history_subjective_nontraining_and_context_can_be_saved_without_commit(self):
        self.init()
        cases = (("planned", "plan", "DEFER", "none"), ("historical", "record_set", "DEFER", "none"), ("subjective", "subjective_state", "IGNORE", "none"), ("non_training", "non_training", "IGNORE", "none"), ("context", "context", "DEFER", "context_missing"))
        for index, (modality, intent, decision, ambiguity) in enumerate(cases, 1):
            self.rows[0].update(tense_or_modality=modality, intent=intent, gold_decision=decision, ambiguity_type=ambiguity, weight_kg="UNKNOWN", reps="UNKNOWN", set_index="UNKNOWN", gold_version="v" + str(index))
            self.meta.update(revision_id="REV-" + str(index), parent_revision_id=None if index == 1 else "REV-" + str(index - 1), event="draft" if index == 1 else "revise")
            with self.subTest(modality=modality):
                self.revise(expected="NONE" if index == 1 else "REV-" + str(index - 1))
        self.assertEqual(self.call("validate")["draft_segments"], 1)

    def test_duplicate_segment_and_header_mismatch_rejected(self):
        self.init()
        self.rows.append(dict(self.rows[0]))
        self.assertIn("duplicate", self.revise(ok=False)["error"])
        write_csv(self.input, FIELDS[:-1], [])
        self.meta_file.write_text(json.dumps(self.meta), encoding="utf-8")
        self.assertIn("header", self.call("revise", "--input", self.input, "--metadata", self.meta_file, "--expected-revision", "NONE", ok=False)["error"])

    def test_missing_or_unlistened_reference_and_asr_copy_field_rejected(self):
        self.init()
        self.rows[0]["reference_text"] = ""
        self.assertIn("reference_text", self.revise(ok=False)["error"])
        self.rows[0]["reference_text"] = "SYNTHETIC ONLY"
        self.meta["source_listened"] = False
        self.assertIn("listened", self.revise(ok=False)["error"])
        self.meta["source_listened"] = True
        self.rows[0]["asr_hypothesis_separate"] = "SYNTHETIC ASR"
        self.assertIn("ASR", self.revise(ok=False)["error"])

    def test_bad_numbers_empty_unknown_and_malformed_segment_ids_rejected(self):
        self.init()
        for field, value in (("weight_kg", "NaN"), ("reps", "1.5"), ("weight_kg", ""), ("segment_index", "01"), ("intent", "made_up")):
            original = self.rows[0][field]
            self.rows[0][field] = value
            with self.subTest(field=field, value=value):
                self.revise(ok=False)
            self.rows[0][field] = original

    def test_context_and_evidence_time_must_match_original_audio(self):
        self.init()
        self.meta["segments"][0]["context"] = ["TEST-R01:99"]
        self.assertIn("context", self.revise(ok=False)["error"])
        self.meta["segments"][0]["context"] = []
        self.meta["segments"][0]["end_sec"] = 1
        self.assertIn("time", self.revise(ok=False)["error"])

    def test_wrong_schema_source_hash_and_missing_attestation_fields_rejected(self):
        self.init()
        for field, value in (("schema_version", 2), ("source_sha256", "0" * 64), ("source_listened", "true"), ("reason", ""), ("segments", []), ("at", "2026-11-01T10:00:00+08:00")):
            original = self.meta[field]
            self.meta[field] = value
            with self.subTest(field=field):
                self.revise(ok=False)
            self.meta[field] = original

    def test_bad_csv_row_width_rejected_before_any_revision_write(self):
        self.init()
        write_csv(self.input, FIELDS, self.rows)
        with self.input.open("a", encoding="utf-8") as out:
            out.write("too,few,columns\n")
        self.meta_file.write_text(json.dumps(self.meta), encoding="utf-8")
        result = self.call("revise", "--input", self.input, "--metadata", self.meta_file, "--expected-revision", "NONE", ok=False)
        self.assertIn("width", result["error"])
        self.assertEqual(list((self.root / "revisions").iterdir()), [])

    def test_stale_parent_duplicate_revision_and_tampered_snapshot_blocked(self):
        self.init()
        self.revise()
        self.assertIn("conflict", self.revise(ok=False)["error"])
        self.meta.update(parent_revision_id="REV-1", event="revise")
        self.assertIn("revision_id", self.revise(ok=False, expected="REV-1")["error"])
        artifact = self.root / "revisions" / "REV-1.json"
        artifact.chmod(0o600)
        artifact.write_text("{}", encoding="utf-8")
        self.assertIn("hash", self.call("validate", ok=False)["error"])

    def test_source_hash_and_later_withdrawal_or_expiry_rechecked(self):
        self.init()
        self.revise()
        for changes in ({"withdrawn_at": "2026-10-16T11:00:00+08:00"}, {"retention_until": "2026-10-15"}, {"consent_status": "withdrawn"}):
            original = dict(self.consent)
            self.consent.update(changes)
            self.save_source()
            with self.subTest(changes=changes):
                result = self.call("validate")
                self.assertEqual(result["segments"], 0)
                self.assertEqual(result["excluded_recordings"], 1)
                self.assertEqual(result["excluded"][0]["recording_id"], "TEST-R01")
            self.consent = original
        self.save_source()
        self.audio.write_bytes(self.audio.read_bytes()[:-2])
        self.call("validate", ok=False)

    def test_recording_and_revision_chronology_rejected(self):
        self.init()
        for recorded_at in ("2026-09-30T10:00:00+08:00", "2026-11-01T10:00:00+08:00"):
            self.recording["recorded_at"] = recorded_at
            self.save_source()
            self.revise(ok=False)
        self.recording["recorded_at"] = "2026-10-15T10:00:00+08:00"
        self.save_source()
        self.meta["at"] = "2026-10-14T10:00:00+08:00"
        self.revise(ok=False)

    def review_metadata(self, event="review"):
        self.meta.update(revision_id="REV-2", parent_revision_id="REV-1", actor_id_pseudonym="TEST-JZD", event=event, at="2026-10-16T11:00:00+08:00")
        self.rows[0].update(reviewer_id_pseudonym="TEST-JZD", review_status="reviewed" if event == "review" else "disputed")

    def test_review_requires_independent_actor_and_current_team_consent(self):
        self.init()
        self.revise()
        self.review_metadata()
        self.assertIn("team", self.revise(ok=False, expected="REV-1")["error"])
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.meta["actor_id_pseudonym"] = "TEST-LHY"
        self.rows[0]["reviewer_id_pseudonym"] = "TEST-LHY"
        self.assertIn("independent", self.revise(ok=False, expected="REV-1")["error"])
        self.meta["actor_id_pseudonym"] = "TEST-JZD"
        self.rows[0]["reviewer_id_pseudonym"] = "TEST-JZD"
        self.revise(expected="REV-1")
        self.assertEqual(self.call("validate")["reviewed_segments"], 1)
        self.consent["internal_team_use_allowed"] = "false"
        self.save_source()
        checked = self.call("validate")
        self.assertEqual(checked["reviewed_segments"], 0)
        self.assertEqual(checked["excluded"][0]["purpose"], "team")

    def add_independent_second_source(self):
        audio = self.source / "audio" / "TEST-R02.wav"
        audio.write_bytes(self.audio.read_bytes()[:-2] + struct.pack("<h", 321))
        sha = hashlib.sha256(audio.read_bytes()).hexdigest()
        consent = dict(self.consent, consent_id="TEST-C02", speaker_id_pseudonym="TEST-S02", withdrawn_at="", consent_status="granted", retention_until="2026-10-31")
        recording = dict(self.recording, recording_id="TEST-R02", consent_id="TEST-C02", speaker_id_pseudonym="TEST-S02", sha256=sha, private_storage_pointer="audio/TEST-R02.wav")
        write_csv(self.source / "CONSENT_REGISTER.csv", CONSENT, [self.consent, consent])
        write_csv(self.source / "WAV_MANIFEST.csv", MANIFEST, [self.recording, recording])
        return consent, recording

    def test_withdrawn_history_does_not_block_unrelated_queue_draft_or_active_api(self):
        self.init()
        self.revise()
        saved = (self.root / "revisions" / "REV-1.json").read_bytes()
        self.consent.update(consent_status="withdrawn", withdrawn_at="2026-10-16T11:00:00+08:00")
        _, other = self.add_independent_second_source()
        queued = self.call("queue")
        self.assertEqual([row["recording_id"] for row in queued["queue"]], ["TEST-R02"])
        self.assertEqual(queued["excluded"][0]["recording_id"], "TEST-R01")
        self.assertEqual(self.call("validate")["segments"], 0)
        self.rows[0].update(recording_id="TEST-R02", evidence_reference="audio:TEST-R02#t=0,0.2")
        self.meta.update(recording_id="TEST-R02", revision_id="REV-2", source_sha256=other["sha256"])
        self.revise()
        result = self.call("validate")
        self.assertEqual(result["segments"], 1)
        self.assertEqual(result["retained_history_recordings"], 2)
        self.assertEqual(result["excluded_recordings"], 1)
        self.assertEqual((self.root / "revisions" / "REV-1.json").read_bytes(), saved)
        with (self.root / "reference" / "ANNOTATIONS.csv").open(encoding="utf-8-sig", newline="") as inp:
            self.assertEqual([row["recording_id"] for row in csv.DictReader(inp)], ["TEST-R02"])
        spec = importlib.util.spec_from_file_location("d02_test_active_api", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        when = module.d01.as_of("2026-10-16")
        consents, recordings = module.source_store(self.source, when)
        _, latest, ids, rows = module.load_workspace(self.root, consents, recordings, when)
        self.assertEqual(set(latest), {"TEST-R02"})
        self.assertEqual({row["recording_id"] for row in rows}, {"TEST-R02"})
        self.assertEqual(ids, {"REV-1", "REV-2"})

    def test_revoked_team_review_is_auditable_but_not_active_or_queued(self):
        self.init()
        self.revise()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.review_metadata()
        self.revise(expected="REV-1")
        saved = (self.root / "revisions" / "REV-2.json").read_bytes()
        self.consent["internal_team_use_allowed"] = "false"
        self.add_independent_second_source()
        queued = self.call("queue")
        self.assertEqual([row["recording_id"] for row in queued["queue"]], ["TEST-R02"])
        self.assertEqual(queued["excluded"][0]["purpose"], "team")
        self.assertEqual(self.call("validate")["reviewed_segments"], 0)
        self.assertEqual((self.root / "revisions" / "REV-2.json").read_bytes(), saved)

    def test_withdrawn_asr_history_does_not_block_unrelated_annotations(self):
        self.init()
        self.revise()
        artifact = self.base / "asr.json"
        artifact.write_text(json.dumps({"schema_version": 1, "artifact_id": "ASR-1", "recording_id": "TEST-R01", "source_sha256": self.sha, "hypothesis": "SYNTHETIC ASR ONLY", "origin": "offline_import", "model_version": "TEST-MODEL"}), encoding="utf-8")
        self.call("attach-asr", "--input", artifact)
        self.consent.update(consent_status="withdrawn", withdrawn_at="2026-10-16T11:00:00+08:00")
        self.add_independent_second_source()
        result = self.call("validate")
        self.assertEqual(result["asr_artifacts"], 0)
        self.assertEqual(result["excluded_asr_artifacts"], 1)
        self.assertEqual(self.call("queue")["queue"][0]["recording_id"], "TEST-R02")

    def test_context_dependent_content_is_excluded_when_its_source_is_withdrawn(self):
        self.init()
        self.revise()
        other_consent, other = self.add_independent_second_source()
        self.rows[0].update(recording_id="TEST-R02", evidence_reference="audio:TEST-R02#t=0,0.2")
        self.meta.update(recording_id="TEST-R02", revision_id="REV-2", source_sha256=other["sha256"])
        self.meta["segments"][0]["context"] = ["TEST-R01:1"]
        self.revise()
        self.consent.update(consent_status="withdrawn", withdrawn_at="2026-10-16T11:00:00+08:00")
        write_csv(self.source / "CONSENT_REGISTER.csv", CONSENT, [self.consent, other_consent])
        checked = self.call("validate")
        self.assertEqual(checked["segments"], 0)
        self.assertEqual(checked["excluded_recordings"], 2)
        self.assertEqual(checked["excluded"][1]["reason"], "referenced_source_excluded")
        self.assertEqual(self.call("queue")["queue"], [])

    def test_excluded_history_still_requires_immutable_hash_integrity(self):
        self.init()
        self.revise()
        self.consent.update(consent_status="withdrawn", withdrawn_at="2026-10-16T11:00:00+08:00")
        self.add_independent_second_source()
        snapshot = self.root / "revisions" / "REV-1.json"
        snapshot.chmod(0o600)
        snapshot.write_text("{}", encoding="utf-8")
        self.assertIn("hash", self.call("queue", ok=False)["error"])

    def test_review_and_dispute_cannot_drop_semantic_context_metadata(self):
        self.init()
        self.rows.append(dict(self.rows[0], segment_index="2", exercise="deadlift"))
        self.meta["segments"].append({"segment_index": 2, "start_sec": 0, "end_sec": 0.2, "context": ["TEST-R01:1"], "correction_target": "UNKNOWN"})
        self.revise()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        for event, status in (("review", "reviewed"), ("dispute", "disputed")):
            self.review_metadata(event)
            for row in self.rows:
                row.update(reviewer_id_pseudonym="TEST-JZD", review_status=status)
            self.meta["segments"][1]["context"] = []
            with self.subTest(event=event):
                self.assertIn("evidence", self.revise(ok=False, expected="REV-1")["error"])

    def test_resolve_cannot_change_semantic_context_metadata(self):
        self.init()
        self.rows.append(dict(self.rows[0], segment_index="2", exercise="deadlift"))
        self.meta["segments"].append({"segment_index": 2, "start_sec": 0, "end_sec": 0.2, "context": ["TEST-R01:1"], "correction_target": "UNKNOWN"})
        self.revise()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.review_metadata("dispute")
        for row in self.rows:
            row.update(reviewer_id_pseudonym="TEST-JZD", review_status="disputed")
        self.revise(expected="REV-1")
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-2", event="resolve", actor_id_pseudonym="TEST-OWNER", adjudicator_id_pseudonym="TEST-OWNER", at="2026-10-16T12:00:00+08:00")
        self.meta["segments"][1]["context"] = []
        for row in self.rows:
            row.update(reviewer_id_pseudonym="TEST-OWNER", review_status="reviewed")
        self.assertIn("evidence", self.revise(ok=False, expected="REV-2")["error"])

    def test_reviewer_cannot_silently_change_content(self):
        self.init()
        self.revise()
        self.review_metadata()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.rows[0]["reps"] = "9"
        self.assertIn("content", self.revise(ok=False, expected="REV-1")["error"])

    def test_review_claim_without_review_event_rejected(self):
        self.init()
        self.rows[0].update(review_status="reviewed", reviewer_id_pseudonym="TEST-JZD")
        self.assertIn("review", self.revise(ok=False)["error"])

    def test_new_draft_version_preserves_reviewed_revision(self):
        self.init()
        self.revise()
        self.review_metadata()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.revise(expected="REV-1")
        snapshot = (self.root / "revisions" / "REV-2.json").read_bytes()
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-2", actor_id_pseudonym="TEST-LHY", event="revise", at="2026-10-16T12:00:00+08:00")
        self.rows[0].update(reps="9", reviewer_id_pseudonym="", review_status="draft", gold_version="v2")
        self.revise(expected="REV-2")
        self.assertEqual((self.root / "revisions" / "REV-2.json").read_bytes(), snapshot)
        self.assertEqual(self.call("validate")["reviewed_segments"], 0)

    def test_dispute_requires_explicit_independent_adjudication(self):
        self.init()
        self.revise()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.review_metadata("dispute")
        self.revise(expected="REV-1")
        self.assertEqual(self.call("validate")["disputed_segments"], 1)
        self.assertEqual(self.call("queue")["queue"][0]["disputed_segment_indices"], ["1"])
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-2", event="review", at="2026-10-16T12:00:00+08:00")
        self.rows[0]["review_status"] = "reviewed"
        self.assertIn("resolve", self.revise(ok=False, expected="REV-2")["error"])
        self.meta.update(event="resolve", actor_id_pseudonym="TEST-OWNER", adjudicator_id_pseudonym="TEST-OWNER")
        self.rows[0]["reviewer_id_pseudonym"] = "TEST-OWNER"
        self.revise(expected="REV-2")
        self.assertEqual(self.call("validate")["disputed_segments"], 0)

    def test_dispute_cannot_be_cleared_by_new_draft(self):
        self.init()
        self.revise()
        self.consent["internal_team_use_allowed"] = "true"
        self.save_source()
        self.review_metadata("dispute")
        self.revise(expected="REV-1")
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-2", event="revise", actor_id_pseudonym="TEST-LHY", at="2026-10-16T12:00:00+08:00")
        self.rows[0].update(review_status="draft", reviewer_id_pseudonym="", gold_version="v2")
        self.assertIn("resolve", self.revise(ok=False, expected="REV-2")["error"])

    def test_old_gold_version_cannot_be_reused_for_changed_content(self):
        self.init()
        self.revise()
        self.meta.update(revision_id="REV-2", parent_revision_id="REV-1", event="revise", at="2026-10-16T11:00:00+08:00")
        self.rows[0].update(gold_version="v2", reps="9")
        self.revise(expected="REV-1")
        self.meta.update(revision_id="REV-3", parent_revision_id="REV-2", at="2026-10-16T12:00:00+08:00")
        self.rows[0].update(gold_version="v1", reps="10")
        self.assertIn("gold_version", self.revise(ok=False, expected="REV-2")["error"])

    def test_revision_cannot_drop_an_existing_action(self):
        self.init()
        self.rows.append(dict(self.rows[0], segment_index="2", exercise="deadlift"))
        self.meta["segments"].append({"segment_index": 2, "start_sec": 0, "end_sec": 0.2, "context": [], "correction_target": "UNKNOWN"})
        self.revise()
        self.meta.update(revision_id="REV-2", parent_revision_id="REV-1", event="revise", at="2026-10-16T11:00:00+08:00")
        self.rows = [dict(self.rows[0], gold_version="v2")]
        self.meta["segments"] = self.meta["segments"][:1]
        self.assertIn("drop", self.revise(ok=False, expected="REV-1")["error"])

    def test_separate_asr_artifact_is_hash_bound_and_never_reference(self):
        self.init()
        self.revise()
        asr_input = self.base / "asr.json"
        asr_input.write_text(json.dumps({"schema_version": 1, "artifact_id": "ASR-1", "recording_id": "TEST-R01", "source_sha256": self.sha, "hypothesis": "SYNTHETIC ASR ONLY", "origin": "offline_import", "model_version": "TEST-MODEL"}), encoding="utf-8")
        self.call("attach-asr", "--input", asr_input)
        self.assertEqual(self.call("validate")["asr_artifacts"], 1)
        with (self.root / "reference" / "ANNOTATIONS.csv").open(encoding="utf-8-sig", newline="") as inp:
            row = list(csv.DictReader(inp))[0]
            self.assertEqual(row["reference_text"], "SYNTHETIC ONLY")
            self.assertEqual(row["asr_hypothesis_separate"], "")

    def test_symlink_escape_and_repo_private_roots_rejected_without_path_leak(self):
        self.init()
        self.input.symlink_to(self.audio)
        self.meta_file.write_text(json.dumps(self.meta), encoding="utf-8")
        error = self.call("revise", "--input", self.input, "--metadata", self.meta_file, "--expected-revision", "NONE", ok=False)["error"]
        self.assertNotIn(str(self.base), error)
        self.assertIn("symlink", error)
        self.root = BASE / "forbidden-private-workspace"
        self.assertIn("repository", self.call("init", "--local-annotator", "TEST-LHY", ok=False)["error"])

    def test_source_root_alias_symlink_rejected(self):
        self.init()
        alias = self.base / "source-link"
        alias.symlink_to(self.source, target_is_directory=True)
        self.source = alias
        self.assertIn("symlink", self.call("queue", ok=False)["error"])

    def test_malformed_metadata_csv_width_and_projection_tampering_rejected(self):
        self.init()
        write_csv(self.input, FIELDS, self.rows)
        self.meta_file.write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
        self.call("revise", "--input", self.input, "--metadata", self.meta_file, "--expected-revision", "NONE", ok=False)
        self.revise()
        projection = self.root / "reference" / "ANNOTATIONS.csv"
        projection.write_text("bad,header\n", encoding="utf-8")
        self.call("validate", ok=False)


if __name__ == "__main__":
    unittest.main()
