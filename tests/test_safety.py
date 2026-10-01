"""Safety regression tests. All storage/backup commands are shell mocks."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "proxmox-offline-backup.sh").read_text()
FUNCTIONS = SCRIPT[SCRIPT.index("log() {"):SCRIPT.index("\ntrap cleanup EXIT")]


class SafetyTests(unittest.TestCase):
    def shell(self, body, setup=""):
        script = """set -Eeuo pipefail
LOG_FILE=/dev/null
MOUNTED_BY_SCRIPT=true
STORAGE_ENABLED_BY_SCRIPT=true
MARKER_FILE=""
PVE_STORAGE=test
MOUNT_POINT=/mock
BACKUP_DEVICE=/dev/mock1
DISK_CHECK_REQUIRED=true
CURRENT_STAGE=test
CURRENT_VM=100
DRY_RUN=false
""" + FUNCTIONS + "\n" + """
pvesm() { echo DISABLE; }
sync() { echo SYNC; }
umount() { echo UNMOUNT; }
check_disk_unmounted() { return 0; }
""" + setup + "\n" + body
        return subprocess.run(["bash"], input=script, text=True, capture_output=True)

    def test_source_has_linux_line_endings_and_valid_syntax(self):
        for name in ("proxmox-offline-backup.sh", "config.example"):
            self.assertNotIn(b"\r", (ROOT / name).read_bytes())
            result = subprocess.run(["bash", "-n", str(ROOT / name)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_broken_log_does_not_prevent_cleanup(self):
        result = self.shell("trap cleanup EXIT\nexit 0", "LOG_FILE=/dev/null/nonexistent")
        self.assertEqual(result.returncode, 0, result.stderr)
        for action in ("DISABLE", "SYNC", "UNMOUNT"):
            self.assertIn(action, result.stdout)

    def test_failed_log_write_does_not_duplicate_message(self):
        result = self.shell('log INFO unique-message', 'LOG_FILE=/dev/null/nonexistent')
        self.assertEqual((result.stdout + result.stderr).count('unique-message'), 1)
        self.assertIn('Log file unavailable', result.stderr)

    def test_sync_failure_still_unmounts_and_never_reports_safe(self):
        result = self.shell("trap cleanup EXIT\nexit 0", "sync() { echo SYNC_FAILED; return 7; }")
        self.assertEqual(result.returncode, 90)
        self.assertIn("UNMOUNT", result.stdout)
        self.assertNotIn("SAFE TO DISCONNECT", result.stdout)

    def test_disable_failure_still_unmounts(self):
        result = self.shell("trap cleanup EXIT\nexit 31", "pvesm() { return 5; }")
        self.assertEqual(result.returncode, 31)
        self.assertIn("UNMOUNT", result.stdout)
        self.assertIn("DO NOT disconnect", result.stdout)

    def test_unmount_failure_never_reports_safe(self):
        result = self.shell("trap cleanup EXIT\nexit 0", "umount() { return 1; }")
        self.assertEqual(result.returncode, 90)
        self.assertNotIn("SAFE TO DISCONNECT", result.stdout)

    def test_remaining_mount_never_reports_safe(self):
        result = self.shell("trap cleanup EXIT\nexit 0", "check_disk_unmounted() { return 1; }")
        self.assertEqual(result.returncode, 90)
        self.assertNotIn("SAFE TO DISCONNECT", result.stdout)

    def test_logged_command_keeps_original_failure(self):
        result = self.shell('run_logged bash -c "echo diagnostic >&2; exit 7"')
        self.assertEqual(result.returncode, 7)
        self.assertIn("diagnostic", result.stdout)

    def test_verification_detects_decompression_failure(self):
        result = self.shell('run_logged verify_archive ignored',
                            'zstd() { return 9; }\nvma() { cat >/dev/null; return 0; }')
        self.assertEqual(result.returncode, 9)

    def test_disk_check_catches_sibling_partition(self):
        body = FUNCTIONS + """
lsblk() {
    if [[ "$*" == *NAME* ]]; then printf '/dev/mock1\n/dev/mock\n';
    else printf '8:0\n8:1\n8:2\n'; fi
}
findmnt() { printf '8:2 /other-partition\n'; }
check_disk_unmounted
"""
        result = self.shell(body)
        self.assertEqual(result.returncode, 1)
        self.assertIn("/other-partition", result.stdout)

    def test_disk_inspection_failure_is_not_success(self):
        result = self.shell(FUNCTIONS + '\nlsblk() { return 1; }\ncheck_disk_unmounted')
        self.assertEqual(result.returncode, 1)

    def test_lock_excludes_second_process(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = str(Path(directory) / "lock")
            result = subprocess.run(
                ["bash", "-c", 'exec 9>"$1"; flock -n 9; '
                 'flock -n "$1" true; status=$?; test "$status" = 1', "test", lock],
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
