#!/usr/bin/env python3
"""Local manifest/build consistency checks; the network's full schema is authoritative."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "launch.json").read_text())
assert manifest["kind"] == "univ4_hook"
assert manifest["chainId"] == 1
assert isinstance(manifest["notes"], str) and manifest["notes"].strip()
for node, name in (("hook", "SIMDTESTHook"), ("token", "SIMDTEST")):
    assert manifest[node]["contract"] == name
    assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", manifest[node]["contract"])
    assert (root / manifest[node]["source"]).is_file()
    artifact = json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())
    constructor = next(entry for entry in artifact["abi"] if entry["type"] == "constructor")
    assert len(constructor["inputs"]) == len(manifest[node]["constructorArgs"])
    creation_size = len(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x")))
    runtime_size = len(bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x")))
    assert creation_size + 32 * len(constructor["inputs"]) <= 49152
    assert runtime_size <= 24576
    print(f"{name}: {creation_size} creation bytes, {runtime_size} runtime bytes")
assert manifest["hook"]["constructorArgs"] == ["$poolManager", "$token"]
assert manifest["token"]["constructorArgs"] == []
assert manifest["hook"]["permissions"] == [
    "beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta"
]
assert manifest["token"]["name"] == manifest["token"]["symbol"] == "SIMDTEST"
assert manifest["token"]["decimals"] == 18
assert int(manifest["token"]["totalSupply"]) == 10**27
assert manifest["pool"] == {
    "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
    "fee": 12500,
    "tickSpacing": 60,
    "initialPrice": "79228162514264337593543950336",
}
print("Manifest shape, launch parameters and artifact size checks passed.")
