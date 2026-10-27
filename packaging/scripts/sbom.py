#!/usr/bin/env python3
"""Emit a CycloneDX 1.5 SBOM for the roomy CLI from RoomyCore/Package.resolved.

Usage: packaging/scripts/sbom.py <version> > dist/roomy-<version>.cdx.json
No third-party Python needed; this is deliberately simple so it runs in CI anywhere.
"""
import json, sys, uuid, datetime, pathlib

root = pathlib.Path(__file__).resolve().parents[2]
version = sys.argv[1] if len(sys.argv) > 1 else "0.0.0"
resolved = json.loads((root / "RoomyCore" / "Package.resolved").read_text())
pins = resolved.get("pins") or resolved.get("object", {}).get("pins", [])

components = []
for pin in pins:
    ident = pin.get("identity") or pin.get("package", "").lower()
    loc = pin.get("location") or pin.get("repositoryURL", "")
    state = pin.get("state", {})
    ver = state.get("version") or state.get("revision", "")[:12]
    components.append({
        "type": "library",
        "name": ident,
        "version": ver,
        "purl": f"pkg:swift/{loc.replace('https://', '').removesuffix('.git')}@{ver}",
        "externalReferences": [{"type": "vcs", "url": loc}],
        "properties": [{"name": "swiftpm:revision", "value": state.get("revision", "")}],
    })

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tools": [{"vendor": "Azbouki", "name": "roomy-sbom", "version": "1"}],
        "component": {"type": "application", "name": "roomy", "version": version, "supplier": {"name": "Azbouki"}},
    },
    "components": components,
}
json.dump(bom, sys.stdout, indent=2)
print()
