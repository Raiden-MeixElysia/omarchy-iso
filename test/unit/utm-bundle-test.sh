#!/bin/bash
#
# Unit tests for the UTM SE appliance builder's static inputs: the config.plist
# template must be a valid plist once omarchy-utm-make substitutes its
# placeholders, and the package lists must name real packages.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

template="$ROOT/builder/utm/config.plist"
render="$ROOT/builder/utm/render"

placeholders=$(grep -o '@@[A-Z_]*@@' "$template" | sort -u | tr '\n' ' ')
[[ $placeholders == "@@DISK_UUID@@ @@MAC@@ @@VERSION@@ @@VM_UUID@@ " ]] ||
  fail "the template carries exactly the placeholders the build fills" "$placeholders"
pass "the template carries exactly the placeholders the build fills"

rendered=$("$render" 11111111-2222-3333-4444-555555555555 66666666-7777-8888-9999-000000000000 02:00:00:00:00:01 4.0.2)
python3 - "$rendered" <<'PY' || fail "the rendered config.plist parses, names the disk it ships, and declares nothing iOS rejects"
import plistlib, sys
config = plistlib.loads(sys.argv[1].encode())
assert "@@" not in sys.argv[1]
assert config["ConfigurationVersion"] == 4
assert config["Information"]["UUID"] == "11111111-2222-3333-4444-555555555555"
assert config["Drive"][0]["Identifier"] == "66666666-7777-8888-9999-000000000000"
assert config["Drive"][0]["ImageName"] == "66666666-7777-8888-9999-000000000000.qcow2"
assert config["Network"][0]["MacAddress"] == "02:00:00:00:00:01"
assert "4.0.2" in config["Information"]["Notes"]
assert config["System"]["Architecture"] == "aarch64"
assert config["QEMU"]["Hypervisor"] is False
assert config["System"]["MemorySize"] == 2048
# UTM on iOS has no Ptty serial mode and decodes strictly, so the bundle ships no serial device.
assert config["Serial"] == []
PY
pass "the rendered config.plist parses, names the disk it ships, and declares nothing iOS rejects"

base=""
for candidate in "$ROOT/../omarchy" "$ROOT/../omacom/omarchy"; do
  if [[ -f $candidate/install/omarchy-base.packages ]]; then
    base="$candidate/install/omarchy-base.packages"
    break
  fi
done
if [[ -z $base ]]; then
  pass "no omarchy checkout beside this one; skipping the drop list check"
  exit 0
fi
missing=$(grep -v '^#\|^$' "$ROOT/builder/utm-se-drop.packages" | grep -vxF -f <(sed -e 's/[[:space:]]*#.*$//' -e '/^$/d' "$base") || true)
[[ -z $missing ]] || fail "every dropped package is one the base list ships" "$missing"
pass "every dropped package is one the base list ships"
