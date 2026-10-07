# Audit verification trust

`trusted-keys.json` is an operator-reviewed, out-of-band trust set. Obtain it
and its public key files from a trusted checkout, never from an export bundle.
The verifier resolves every historical anchor's key id separately.

When rotating, preserve the old PEM under a historical filename, update its
`# status: rotated` and `# retired_at: ISO8601` comments, and list it alongside
the replacement PEM in the manifest. Each file carries `# key_id`,
`# created_utc` (activation), `# status`, and, when applicable, `# retired_at`
and `# revoked_at`. Preserve the retirement instant on subsequent revocation.
The lifecycle metadata is pinned by the operator, not trusted from the bundle.

Run `mix sdr.audit.verify --key-set docs/audit/trusted-keys.json BUNDLE`.
The single-key `--public-key PATH --key-id ID` option remains available, but
cannot verify a chain signed with multiple keys. Missing historical keys fail.

The CLI verifies signed chains and can verify OTS proofs when `ots` and a
Bitcoin node are configured. It does not fetch Git commits: its Git-only
assurance ceiling is `signed`. Programmatic `git_verifier` callbacks must
fetch the trusted repository and check the named commit/blob against the
anchor statement's exact SHA-256 digest. Receipt status alone is not proof.

Revoked-key history needs verified OTS time evidence for every affected anchor.
Without it the report is `valid?: false`, `chain_verified`, with
`revocation_time_unproven`, and the CLI exits with an error. Anchor row times
and Git commit times can be backdated. Verified historical signatures retain
reduced assurance. `ots` displays a UTC day; the verifier uses the following
midnight as a conservative existence-time upper bound. A same-day revocation
cannot be resolved from that display precision.
