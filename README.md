<h1 align=center>Foundry project for Rate-Limit Nullifier contract</h1>

<p align="center">
    <img src="https://github.com/Rate-Limiting-Nullifier/rln-contracts/workflows/Tests/badge.svg" width="140">
</p>

## How to use

Install Foundry framework:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Build:
```bash
forge build
```

Test:
```bash
forge test
```

To use the automated proof and verifier contract generation:
- add the following to foundry.toml ```fs_permissions = [{ access = "read-write", path = "./"}]```
- You need to have python3 installed.
- You need to copy the artefacts (zkey files and .wasm files to a local directory)
- You need to set the path to that directory in the test code.
- Use the command ```forge test --ffi``` to enable the ffi cheatcode.
