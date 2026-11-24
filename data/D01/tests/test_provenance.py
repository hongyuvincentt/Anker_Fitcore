"""Regression tests: all metadata, consent and audio are temporary synthetic fixtures."""
import hashlib
import json
from pathlib import Path
import unittest

import test_d01 as fixtures


class ProvenanceTest(unittest.TestCase):
    setUp = fixtures.CollectionTest.setUp
    make_wav = fixtures.CollectionTest.make_wav
    write_csv = fixtures.CollectionTest.write_csv
    rows = fixtures.CollectionTest.rows
    grant = fixtures.CollectionTest.grant
    call = fixtures.CollectionTest.call
    import_audio = fixtures.CollectionTest.import_audio

    def metadata(self, **changes):
        values = {
            "schema_version": 1, "recording_id": "TEST-R01", "utterance_id": "TEST-R01",
            "file_name": "TEST-R01.wav", "recorded_at": "2026-10-16T10:00:00+08:00",
            "completed_at": "2026-10-16T10:00:01+08:00", "device_type": "iphone",
            "recording_source": "iphone_microphone", "is_simulated": False,
            "local_recording_consent": True,
            "inspection": {"sample_rate": 16000, "channels": 1, "bits_per_sample": 16,
                           "frame_count": 3200, "duration_seconds": .2,
                           "size_bytes": self.wav.stat().st_size,
                           "sha256": hashlib.sha256(self.wav.read_bytes()).hexdigest()},
        }
        values.update(changes)
        path = self.base / "synthetic.metadata.json"
        path.write_text(json.dumps(values, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    def test_recover_original_preserves_bytes_manifest_and_review_status(self):
        self.grant()
        self.import_audio("--recording-source", "iphone_microphone")
        original_manifest = (self.root / "WAV_MANIFEST.csv").read_bytes()
        sidecar = self.metadata()
        result = self.call("recover-sidecar", "--recording-id", "TEST-R01", "--metadata", sidecar)
        self.assertTrue(result["recovered"])
        self.assertEqual((self.root / "sidecars/TEST-R01.metadata.json").read_bytes(), sidecar.read_bytes())
        self.assertEqual((self.root / "WAV_MANIFEST.csv").read_bytes(), original_manifest)
        self.assertEqual(self.call("report")["sidecar_provenance_counts"]["retained_verified"], 1)
        event = json.loads((self.root / "audit.jsonl").read_text().splitlines()[-1])
        self.assertEqual(event["event"], "sidecar_recovered")
        self.assertEqual(event["source_path"], str(sidecar.resolve()))
        self.assertTrue(event["at"])
        self.call("recover-sidecar", "--recording-id", "TEST-R01", "--metadata", sidecar, ok=False)

    def test_recover_rejects_missing_or_conflicting_original_evidence(self):
        self.grant()
        self.import_audio("--recording-source", "iphone_microphone")
        for changes in ({"recording_id": "OTHER"}, {"recorded_at": "2026-10-16T11:00:00+08:00"}, {"inspection": {}}, {"inspection": {"sha256": "0" * 64}}):
            with self.subTest(changes=changes):
                self.call("recover-sidecar", "--recording-id", "TEST-R01", "--metadata", self.metadata(**changes), ok=False)
                self.assertFalse((self.root / "sidecars/TEST-R01.metadata.json").exists())

    def test_recover_requires_current_local_consent(self):
        self.grant()
        self.import_audio("--recording-source", "iphone_microphone")
        self.grant(consent_status="withdrawn", withdrawn_at="2026-10-16T10:01:00+08:00")
        self.call("recover-sidecar", "--recording-id", "TEST-R01", "--metadata", self.metadata(), ok=False)

    def test_supplied_sidecar_is_retained_exactly_and_privately(self):
        self.grant()
        sidecar = self.metadata()
        original = sidecar.read_bytes()
        self.import_audio("--metadata", sidecar)
        retained = self.root / "sidecars/TEST-R01.metadata.json"
        self.assertTrue(retained.is_file(), "supplied provenance must be retained")
        self.assertEqual(retained.read_bytes(), original)
        self.assertEqual(retained.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.rows("WAV_MANIFEST.csv")[0]["quality_status"], "needs_review")
        self.assertEqual(self.call("report")["sidecar_provenance_counts"]["retained_verified"], 1)

    def test_wrong_utterance_id_and_file_name_are_rejected(self):
        self.grant()
        for changes in ({"utterance_id": "OTHER"}, {"file_name": "OTHER.wav"}):
            with self.subTest(changes=changes):
                result = self.import_audio("--metadata", self.metadata(**changes), ok=False)
                self.assertIn("metadata", result["error"])
                self.assertEqual(self.rows("WAV_MANIFEST.csv"), [])

    def test_completion_before_start_or_in_future_is_rejected(self):
        self.grant()
        for completed in ("2026-10-16T09:59:00+08:00", "2026-10-17T00:00:00+08:00"):
            with self.subTest(completed=completed):
                result = self.import_audio("--metadata", self.metadata(completed_at=completed), ok=False)
                self.assertIn("completed_at", result["error"])

    def test_sidecar_symlink_is_rejected(self):
        self.grant()
        link = self.base / "linked.metadata.json"
        link.symlink_to(self.metadata())
        self.assertIn("sidecar", self.import_audio("--metadata", link, ok=False)["error"])

    def test_retained_sidecar_edit_is_detected(self):
        self.grant()
        self.import_audio("--metadata", self.metadata())
        retained = self.root / "sidecars/TEST-R01.metadata.json"
        self.assertTrue(retained.exists(), "retention is required before mutation test")
        retained.write_bytes(retained.read_bytes() + b"\n")
        self.assertIn("sidecar", self.call("validate", ok=False)["error"])

    def test_legacy_cli_import_reports_missing_sidecar_without_fabricating_one(self):
        self.grant()
        self.import_audio()
        result = self.call("report")
        self.assertEqual(result["sidecar_provenance_counts"]["not_retained_legacy_or_cli"], 1)
        self.assertFalse((self.root / "sidecars/TEST-R01.metadata.json").exists())
        self.assertEqual(self.call("validate")["recordings"], 1)

    def test_changed_consent_start_cannot_retroactively_authorise_earlier_audio(self):
        self.grant()
        self.import_audio()
        self.grant(consent_timestamp="2026-10-16T11:00:00+08:00")
        self.assertIn("consent_timestamp", self.call("validate", ok=False)["error"])

    def test_simulator_metadata_cannot_be_reclassified_by_manifest_edit(self):
        self.grant()
        self.import_audio("--metadata", self.metadata(is_simulated=True))
        row = self.rows("WAV_MANIFEST.csv")[0]
        row["recording_source"] = "iphone_microphone"
        self.write_csv("WAV_MANIFEST.csv", fixtures.MANIFEST, [row])
        self.assertIn("source", self.call("validate", ok=False)["error"])

    def test_orphan_sidecar_is_not_treated_as_trusted_legacy_provenance(self):
        self.grant()
        self.import_audio()
        directory = self.root / "sidecars"
        directory.mkdir(mode=0o700)
        (directory / "TEST-R01.metadata.json").write_bytes(self.metadata().read_bytes())
        self.assertIn("sidecar", self.call("validate", ok=False)["error"])


if __name__ == "__main__":
    unittest.main()
