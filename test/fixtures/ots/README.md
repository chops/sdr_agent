`hello-world.txt.ots.base64` is the unmodified detached proof from
https://github.com/opentimestamps/opentimestamps-client/blob/master/examples/hello-world.txt.ots
(Git blob `d8357eb50f9f26136a367bcc7e8365b2ddd7e0f5`, LGPL-3.0-or-later;
upstream license reproduced in `LICENSE`).
Stored as base64 so fixture bytes remain exact in text patches.

The hermetic test checks the real proof header/digest and the production CLI
argument boundary with a fake Bitcoin response. It does not claim to verify
Bitcoin offline. The `:external` test invokes the real `ots` binary to prove
that a mismatched digest is rejected before contacting a Bitcoin node.
