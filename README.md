# mello-agent

Outbound AI voice agent for Indian SMBs.

## Branching rule
- Track A (Mac)     commits ONLY inside `agent/`
- Track B (Windows) commits ONLY inside `platform/`
- `contracts/` changes require agreement from BOTH before committing.
- Neither track imports from the other. Both import from `contracts/`.
- If you are editing the other track's directory, stop and talk.

## Setup
Python 3.11. Windows runs everything inside WSL2 Ubuntu.
```bash
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```
