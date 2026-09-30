# Security

Security fixes target the latest MacClaude preview. Earlier releases may not receive backports. Claude transfer compatibility is separate from security support; see [TESTING.md](docs/TESTING.md).

## Report a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/anderskraken/macclaude/security/advisories/new) instead of a public issue. Include the affected version, a description of the impact and reproducible steps using synthetic data.

Do not attach credentials, cookies, real Claude profiles, transcripts or private project paths. MacClaude's **Copy Diagnostics** report omits names, paths and conversation contents; review other attachments yourself.

The maintainer will review reports as time permits. This is a community project without a guaranteed response time.

## Scope

Relevant reports include unsafe session transfers, path or symlink handling, recovery errors that could lose data, diagnostic disclosure and release integrity. Claude authentication, cloud services and upstream application vulnerabilities should be reported to Anthropic through its own security process.
