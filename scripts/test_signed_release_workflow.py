"""Local regression tests for the iOS signed-release workflow.

Dependency: PyYAML (``python -m pip install PyYAML``).
Run with: ``python -m unittest scripts.test_signed_release_workflow``.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ios-signed-build.yml"
GIT_BASH = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe"
BASH = str(GIT_BASH) if GIT_BASH.is_file() else shutil.which("bash")
PREFERRED_TEMP = Path(r"C:\Users\DreamZL\AppData\Local\Temp\opencode")


def workflow_steps() -> list[dict[str, object]]:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return document["jobs"]["build"]["steps"]


def step_named(name: str) -> dict[str, object]:
    return next(step for step in workflow_steps() if step.get("name") == name)


MOCKS = r'''
gh() {
  printf 'MOCK_GH %s\n' "$*" >&2
  case "$1 $2" in
    'api repos/'*) return "${GH_API_STATUS:-0}" ;;
    'release view') return "${GH_VIEW_STATUS:-0}" ;;
    'release upload') return "${GH_UPLOAD_STATUS:-0}" ;;
    *) printf 'unexpected gh invocation\n' >&2; return 97 ;;
  esac
}
git() {
  printf 'MOCK_GIT %s\n' "$*" >&2
  case "$1" in
    ls-remote) printf '%s' "${MOCK_TAG_REFS:-}" ;;
    rev-parse) printf '%s\n' "${MOCK_HEAD_SHA:-}" ;;
    *) printf 'unexpected git invocation\n' >&2; return 97 ;;
  esac
}
'''


@unittest.skipUnless(BASH, "bash is unavailable; workflow shell tests skipped")
class SignedReleaseWorkflowTests(unittest.TestCase):
    def run_script(
        self,
        script: str,
        *,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        temp_base = PREFERRED_TEMP if PREFERRED_TEMP.is_dir() else None
        with tempfile.TemporaryDirectory(prefix="imusic-workflow-test-", dir=temp_base) as temp_name:
            temp_dir = Path(temp_name)
            runner_temp = temp_dir / "runner-temp"
            runner_temp.mkdir()
            process_env = os.environ.copy()
            process_env.update(env or {})
            process_env.setdefault("GITHUB_REPOSITORY", "example/imusic")
            process_env["GITHUB_ENV"] = (temp_dir / "github-env").as_posix()
            process_env["RUNNER_TEMP"] = runner_temp.as_posix()
            return subprocess.run(
                [BASH or "bash", "-e", "-o", "pipefail", "-c", MOCKS + "\n" + script],
                cwd=ROOT,
                env=process_env,
                text=True,
                encoding="utf-8",
                capture_output=True,
                check=False,
            )

    def test_preflight_rejects_empty_and_malicious_tags_without_gh(self) -> None:
        script = str(step_named("Validate release selection")["run"])
        for tag in ("", "v1.0.0$(echo injected)"):
            with self.subTest(tag=tag):
                result = self.run_script(script, env={"RELEASE_TAG": tag})
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("MOCK_GH", result.stderr)

    def test_preflight_requires_existing_tag_and_release_and_accepts_valid_tag(self) -> None:
        script = str(step_named("Validate release selection")["run"])
        no_tag = self.run_script(script, env={"RELEASE_TAG": "v1.2.3", "GH_API_STATUS": "1"})
        self.assertNotEqual(no_tag.returncode, 0)
        self.assertIn("MOCK_GH api", no_tag.stderr)
        self.assertNotIn("MOCK_GH release view", no_tag.stderr)

        no_release = self.run_script(script, env={"RELEASE_TAG": "v1.2.3", "GH_VIEW_STATUS": "1"})
        self.assertNotEqual(no_release.returncode, 0)
        self.assertIn("MOCK_GH release view v1.2.3", no_release.stderr)

        valid = self.run_script(script, env={"RELEASE_TAG": "v1.2.3"})
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn("MOCK_GH api repos/example/imusic/git/ref/tags/v1.2.3", valid.stderr)
        self.assertIn("MOCK_GH release view v1.2.3 --repo example/imusic", valid.stderr)

    def test_binding_accepts_lightweight_and_annotated_tag_sha(self) -> None:
        script = str(step_named("Bind publish build to remote tag")["run"])
        for refs in (
            "abc123\trefs/tags/v2.3.4\n",
            "tag999\trefs/tags/v2.3.4\nabc123\trefs/tags/v2.3.4^{}\n",
        ):
            with self.subTest(refs=refs):
                result = self.run_script(
                    script + '\ncat "$GITHUB_ENV"',
                    env={"RELEASE_TAG": "v2.3.4", "MOCK_TAG_REFS": refs, "MOCK_HEAD_SHA": "abc123"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("IMUSIC_PUBLISH_SHA=abc123", result.stdout)

    def test_binding_rejects_sha_mismatch(self) -> None:
        script = str(step_named("Bind publish build to remote tag")["run"])
        result = self.run_script(
            script,
            env={
                "RELEASE_TAG": "v2.3.4",
                "MOCK_TAG_REFS": "different\trefs/tags/v2.3.4\n",
                "MOCK_HEAD_SHA": "abc123",
            },
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)

    def test_publish_refuses_moved_tag_and_uploads_valid_tag_safely(self) -> None:
        script = str(step_named("Confirm tag and publish signed IPA")["run"])
        common_env = {"RELEASE_TAG": "v2.3.4", "IMUSIC_PUBLISH_SHA": "abc123"}
        moved = self.run_script(
            script,
            env={**common_env, "MOCK_TAG_REFS": "newsha\trefs/tags/v2.3.4\n"},
        )
        self.assertNotEqual(moved.returncode, 0)
        self.assertIn("Remote tag moved", moved.stderr)
        self.assertNotIn("MOCK_GH release upload", moved.stderr)

        valid = self.run_script(
            script,
            env={**common_env, "MOCK_TAG_REFS": "abc123\trefs/tags/v2.3.4\n"},
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertIn(
            "MOCK_GH release upload v2.3.4 iMusic-signed.ipa --clobber --repo example/imusic",
            valid.stderr,
        )

    def test_workflow_security_and_cleanup_invariants(self) -> None:
        steps = workflow_steps()
        for step in steps:
            run_script = step.get("run", "")
            self.assertNotIn("${{ inputs.", run_script, step.get("name"))

        publish_test = step_named("Test iOS 27 feature and UI targets")
        import_signing = step_named("Import signing assets and validate profiles")
        self.assertLess(steps.index(publish_test), steps.index(import_signing))
        self.assertNotIn("-skip-testing", str(publish_test.get("run", "")))
        self.assertNotIn("continue-on-error", publish_test)
        self.assertEqual(publish_test.get("if"), "${{ inputs.publish_release }}")

        ipa_verification = str(step_named("Verify signed IPA")["run"])
        for field in (
            "actual_marketing_version",
            "actual_build_version",
            "actual_bundle_id",
        ):
            self.assertIn(field, ipa_verification)
        self.assertIn("actual_marketing_version\" !=", ipa_verification)
        self.assertIn("actual_build_version\" !=", ipa_verification)
        self.assertIn("actual_bundle_id\" !=", ipa_verification)

        cleanup = step_named("Restore signing environment")
        self.assertEqual(cleanup.get("if"), "${{ always() }}")

    def run_cleanup_with_mocks(
        self,
        *,
        profile_existed: str = "",
        profile_uuid: str = "",
        created_keychain: str = "",
        backup_exists: bool = False,
        cp_status: str = "0",
        security_status: str = "0",
    ) -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
        temp_base = PREFERRED_TEMP if PREFERRED_TEMP.is_dir() else None
        with tempfile.TemporaryDirectory(prefix="imusic-cleanup-test-", dir=temp_base) as temp_name:
            temp_dir = Path(temp_name)
            runner_temp = temp_dir / "runner-temp"
            runner_temp.mkdir()
            event_log = temp_dir / "mock-events"

            home = temp_dir / "home"
            profile_dir = home / "Library" / "MobileDevice" / "Provisioning Profiles"
            profile_dir.mkdir(parents=True)
            installed_profile = profile_dir / f"{profile_uuid}.mobileprovision" if profile_uuid else None
            if installed_profile is not None:
                installed_profile.write_text("installed-original", encoding="utf-8")
            if backup_exists:
                (runner_temp / "imusic-original-profile.mobileprovision").write_text("backup", encoding="utf-8")

            process_env = os.environ.copy()
            process_env.update({
                "HOME": home.as_posix(),
                "RUNNER_TEMP": runner_temp.as_posix(),
                "GITHUB_ENV": (temp_dir / "github-env").as_posix(),
                "IMUSIC_PROFILE_EXISTED": profile_existed,
                "IMUSIC_PROFILE_UUID": profile_uuid,
                "IMUSIC_CREATED_KEYCHAIN": created_keychain,
                "IMUSIC_KEYCHAIN_SEARCH_LIST_BACKUP": "",
                "MOCK_EVENT_LOG": event_log.as_posix(),
                "MOCK_CP_STATUS": cp_status,
                "MOCK_SECURITY_STATUS": security_status,
            })
            mocks = r'''security() {
  printf 'security %s\n' "$*" >> "$MOCK_EVENT_LOG"
  return "${MOCK_SECURITY_STATUS:-0}"
}
cp() {
  printf 'cp %s\n' "$*" >> "$MOCK_EVENT_LOG"
  return "${MOCK_CP_STATUS:-0}"
}
rm() {
  printf 'rm %s\n' "$*" >> "$MOCK_EVENT_LOG"
  return 0
}
'''
            script = mocks + "\n" + str(step_named("Restore signing environment")["run"])
            result = subprocess.run(
                [BASH or "bash", "-e", "-o", "pipefail", "-c", script],
                cwd=ROOT,
                env=process_env,
                text=True,
                encoding="utf-8",
                capture_output=True,
                check=False,
            )
            events = event_log.read_text(encoding="utf-8").splitlines() if event_log.exists() else []
            installed_content = installed_profile.read_text(encoding="utf-8") if installed_profile else ""
            # Return only values that remain meaningful after TemporaryDirectory cleanup.
            self._cleanup_installed_content = installed_content
            self._cleanup_events = events
            return result, runner_temp, events

    def test_cleanup_failure_still_removes_sensitive_files_and_keeps_recovery_backup(self) -> None:
        result, _, events = self.run_cleanup_with_mocks(
            profile_existed="true",
            profile_uuid="profile-123",
            created_keychain="created.keychain-db",
            backup_exists=True,
            cp_status="1",
            security_status="1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(line.startswith("rm -f ") and "imusic-signing.p12" in line for line in events))
        self.assertFalse(any("imusic-original-profile.mobileprovision" in line for line in events if line.startswith("rm ")))
        self.assertTrue(any(line == "security delete-keychain created.keychain-db" for line in events))

    def test_missing_profile_backup_preserves_installed_profile(self) -> None:
        result, _, events = self.run_cleanup_with_mocks(
            profile_existed="true", profile_uuid="profile-123", backup_exists=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Original profile backup is missing", result.stderr)
        self.assertEqual(self._cleanup_installed_content, "installed-original")
        self.assertFalse(any(line.startswith("rm ") and "profile-123.mobileprovision" in line for line in events))

    def test_cleanup_does_not_delete_unowned_keychain(self) -> None:
        result, _, events = self.run_cleanup_with_mocks()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(line.startswith("security delete-keychain") for line in events))


if __name__ == "__main__":
    unittest.main()
