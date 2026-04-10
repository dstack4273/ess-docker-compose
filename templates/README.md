# templates/

These are **reference files only**. Do not edit them directly.

All configs are generated automatically by `deploy.sh` (or `quickstart.sh`), which prompts for your domains, generates secrets, and writes the real config files to their service directories (`mas/config/`, `synapse/data/`, `element/`, etc.).

To set up the stack:

```bash
./quickstart.sh   # simple production setup
./deploy.sh       # advanced: local testing, Authelia, multi-machine
```
