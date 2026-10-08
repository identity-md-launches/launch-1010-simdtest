#!/usr/bin/env python3
"""Local manifest/build consistency checks; the network's full schema is authoritative."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / "launch.json").read_text())
# These are project constants, not fields of the network's launch manifest.
# Foundry's token and fork tests verify the fixed supply and chain respectively.
SOURCES = {"hook": "src/SIMDTESTHook.sol", "token": "src/SIMDTEST.sol"}
assert set(manifest) == {"kind", "hook", "token", "pool", "notes"}
assert set(manifest["hook"]) == {"contract", "constructorArgs", "permissions"}
assert set(manifest["token"]) == {"contract", "name", "symbol", "decimals"}
assert manifest["kind"] == "univ4_hook"
assert isinstance(manifest["notes"], str) and manifest["notes"].strip()
for node, name in (("hook", "SIMDTESTHook"), ("token", "SIMDTEST")):
    assert manifest[node]["contract"] == name
    assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", manifest[node]["contract"])
    assert (root / SOURCES[node]).is_file()
    artifact = json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())
    constructor = next(entry for entry in artifact["abi"] if entry["type"] == "constructor")
    constructor_args = manifest["hook"]["constructorArgs"] if node == "hook" else []
    assert len(constructor["inputs"]) == len(constructor_args)
    creation_size = len(bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x")))
    runtime_size = len(bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x")))
    assert creation_size + 32 * len(constructor["inputs"]) <= 49152
    assert runtime_size <= 24576
    print(f"{name}: {creation_size} creation bytes, {runtime_size} runtime bytes")
assert manifest["hook"]["constructorArgs"] == ["$poolManager", "$token"]
assert manifest["hook"]["permissions"] == [
    "beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta"
]
assert manifest["token"]["name"] == manifest["token"]["symbol"] == "SIMDTEST"
assert manifest["token"]["decimals"] == 18
assert manifest["pool"] == {
    "pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
    "fee": 12500,
    "tickSpacing": 60,
    "initialPrice": "79228162514264337593543950336",
}
print("Manifest shape, launch parameters and artifact size checks passed.")
