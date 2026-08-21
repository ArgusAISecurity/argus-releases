# Argus customer releases

This public repository contains signed customer deployment artifacts for Argus.
The Argus platform source remains private.

Customer container images:

- `ghcr.io/argusaisecurity/argus-node`
- `ghcr.io/argusaisecurity/argus-vulnerability-worker`

Installers consume immutable digest references from the signed `release.env`
asset attached to each GitHub Release.
