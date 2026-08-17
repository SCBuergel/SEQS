# Design plan for conditional 3-of-3 QR transfer

This document specifies a possible future extension of the secure QR transfer
procedure. It is an implementation plan, not a description of functionality
that SEQS currently provides. The existing conditional 2-of-2 procedure in
[secure-qr-transfer.md](secure-qr-transfer.md) remains the supported design
until this plan is implemented, reviewed, and tested on Qubes OS hardware.

## Intended security property

This section defines the claim that determines every later implementation
decision. The proposed procedure separates three values across three peripheral
phases:

1. the webcam/QR phase transfers only the encrypted `key.asc`;
2. the keyboard phase enters independently generated passphrase component A;
3. the mouse phase enters independently generated passphrase component B.

GnuPG receives the concatenation `A || B` only inside the trusted target key
qube. An attacker that compromises no more than two independently isolated
peripheral channels lacks either the ciphertext or one passphrase component.
This remains a conditional protocol property, not a general cryptographic
threshold scheme.

The claim depends on all of these assumptions:

- a complete power removal clears malicious transient state in the shared PCI
  USB controller and other powered hardware between phases;
- persistent controller, platform-firmware, dom0, hypervisor, Qubes input-path,
  and trusted-key-qube compromise are out of scope;
- the physical webcam, keyboard, and mouse are never connected together;
- each phase uses a fresh device-handling qube with only the service required
  for that device;
- the mouse-facing backend cannot observe the target display or randomized
  symbol layout; and
- the operator follows the complete ceremony without copying, photographing,
  displaying, or entering both components through one channel.

The documentation must call this **conditional three-channel confidentiality**,
not unconditional 3-of-3 security. A shared controller separated only in time
does not provide the same assurance as three permanently separate controllers.

## Security gained and not gained

This section bounds the value of the extension before its additional complexity
is accepted. The extension can protect the plaintext from compromise of the QR
channel plus only one input device, from a keyboard keylogger that learns only
A, and from a mouse or mouse backend that records only the events used for B.
It can also limit the consequence of exposing only one of two separately kept
paper components.

The extension does not protect against compromise of dom0, the hypervisor, the
trusted target, the trusted entry program, or the source. It also does not
protect against persistent malicious state that survives complete power
removal, a camera that sees either component, an observer who watches both
input phases, or a common controller/backend active across two phases. Deleting
A, B, ciphertext, or temporary output does not promise forensic erasure from
Qubes volumes, snapshots, copy-on-write storage, swap, backups, or SSD media.

The implementation should be rejected if it weakens the current QR containment
to obtain better ergonomics. In particular, it must not enable camera-originated
input, broaden file-copy policy, bypass strict PCI reset, or put secrets or
executable helper code in dom0.

## System architecture

This section assigns each responsibility to the security domain that needs it.
One physical controller is reused only across cold-power boundaries:

```text
Phase 1: webcam  -> fresh camera USB backend   -> scanner -> offline staging
                         complete power removal
Phase 2: keyboard -> fresh keyboard USB backend -> trusted target stores A
                         complete power removal
Phase 3: mouse   -> fresh mouse USB backend    -> trusted target entry UI -> GnuPG
```

The mouse-entry application must run in the trusted target key qube. It creates
and displays the randomized layout, translates pointer clicks into B, combines
A and B, and supplies the result directly to GnuPG. It must not run in the
mouse USB backend: a backend that knows both click coordinates and their symbol
mapping can reconstruct B.

The proposed mouse backend, provisionally named `sys-usb-mouse`, owns the shared
PCI USB controller only during the final phase. A fresh disposable derived from
a minimal offline template is preferable to a persistent backend. It processes
raw USB mouse traffic and exposes only the Qubes mouse-input service. It has no
NetVM and no reason to receive files, clipboard data, keyboard input, tablet
input, audio, or display contents.

The keyboard phase likewise needs a fresh, minimal backend rather than the
operator's general-purpose persistent `sys-usb`. That backend exposes only the
keyboard-input service and must be destroyed before shutdown. If Qubes cannot
route input directly to the target without granting a backend broader control
of dom0, implementation must stop until the actual boundary and policy can be
made narrow and reviewable.

## Passphrase construction

This section specifies how the two input components become one GnuPG
passphrase. The source generates A and B independently, each from 16 bytes of
kernel randomness encoded as 26 Base32 characters, and encrypts with the
52-character concatenation `A || B`. Each missing component therefore retains
approximately 128 bits of entropy.

The implementation must not split the existing 26-character passphrase into
two 13-character halves. Compromise of one half would leave only about 65 bits
unknown. It also should not introduce XOR reconstruction unless a later review
finds a concrete advantage worth the extra secret-handling code; concatenation
can be delivered directly to GnuPG and is easier to audit.

The source prints A and B separately with unmistakable labels. The operator
records them on separate pieces of paper and keeps both outside the webcam's
field of view. The source must unset both values and close the secret-bearing
terminal before displaying ciphertext, following the existing procedure's
scrollback precautions.

## Persistent state between input phases

This section defines the unavoidable state crossing between the keyboard and
mouse boots. After the keyboard phase, the trusted target must retain A across
a complete power removal so that the final mouse phase can combine it with B.
No untrusted staging qube may hold A.

The entry helper should store A in a root- or user-private file in the trusted
target with mode `0600`, using an atomic create that refuses an existing file.
The file must contain only A, never B or `A || B`. The helper removes it after
successful decryption and on an explicit abort, while the documentation states
that deletion is logical cleanup rather than guaranteed physical erasure.

Persisting A is acceptable only because the target key qube is already trusted.
It does mean that a later compromise of that target can recover A; the 3-of-3
claim never covers target compromise. Snapshot and backup behavior must be
reviewed before the implementation chooses the exact location.

## Randomized mouse-entry application

This section specifies the trusted application that enters B without generating
desktop keyboard events. The application should be a small, auditable program
with no network feature, plugin system, web renderer, clipboard integration,
accessibility export, predictive input, configuration file, or input history.
It should use only distribution-packaged runtime and GUI dependencies.

The application must:

- generate layout randomness inside the trusted target using the operating
  system CSPRNG (cryptographically secure pseudorandom number generator);
- display all 32 Base32 symbols in a large randomized grid;
- accept only primary-button release events within a currently displayed key;
- append the selected symbol internally without emitting a synthetic key event;
- redraw a freshly randomized layout after every accepted symbol;
- debounce double clicks and ignore press/release pairs that cross key bounds;
- display only progress such as `7 / 26`, never entered symbols;
- provide randomized-position Undo and Cancel controls that cannot be confused
  with symbols;
- require exactly 26 accepted symbols and an explicit final confirmation;
- use a fixed full-screen presentation or otherwise account safely for window
  movement, scaling, and display geometry;
- read A from the trusted private state, construct `A || B` only in memory, and
  write it to GnuPG through a private pipe or inherited file descriptor;
- avoid command-line arguments, environment variables, temporary passphrase
  files, clipboard contents, synthetic keyboard events, and shell interpolation;
- clear ordinary application buffers on completion where practical without
  claiming compiler-proof or forensic erasure; and
- fail closed on malformed state, unexpected input length, GnuPG failure,
  cancellation, signal, or loss of its active trusted window.

Per-click reshuffling prevents a mouse/backend recording from correlating one
stable coordinate with one symbol or recognizing repeated characters. A later
usability study may compare this with one random layout per transfer, but the
first implementation should choose the stronger behavior and test whether the
operator error rate remains acceptable.

The application must invoke the same authenticated-ciphertext and safe-output
sequence as the existing guide. Fingerprint comparison occurs before either
input component is entered. Decryption writes into a private temporary
directory, installs `master.key` only after GnuPG succeeds, and preserves the
existing refusal to overwrite a destination.

## Provisioning the trusted application

This section resolves where the new executable belongs without silently
changing the trust model. SEQS currently does not create the operator-specific
source and target key qubes. The application therefore cannot simply be added
to an untrusted transfer qube and still satisfy this design.

The preferred implementation is a new `qr-mouse-entry` component that installs
the reviewed application and only distribution-packaged dependencies into a
TemplateVM used by the operator's trusted target key qube. The catalogue and
configuration documentation must explain how an operator incorporates that
component into a SEQS-managed target definition without committing its name,
secrets, or private data. If the existing catalogue cannot express an
operator-defined trusted target safely, that configuration capability must be
designed first.

An alternative manual installation into an externally managed target is
acceptable only with a commit-bound, independently reviewed transfer procedure.
It must not copy a live working-tree program through dom0 or ask dom0 to execute
it. A separate trusted helper qube that sends B to the target is not an
equivalent design: it adds another trusted secret-bearing domain and another
cross-qube secret channel.

## Cold-power ceremony

This section defines the operator sequence that the future orchestration must
enforce. Every phase begins with only its named physical device connected and
ends with that device unplugged before complete power removal.

### Prepare ciphertext and components

This subsection prepares the source material before untrusted hardware is
active. In the trusted source, generate A and B, encrypt with `A || B`, record
the components separately, close all secret-bearing displays, and display only
the encrypted QR code through the existing display disposable.

### Receive the QR ciphertext

This subsection reuses the current sequential scanner with no passphrase paper
visible. Run the fail-closed camera ceremony, accept exactly one bounded QR
payload into offline staging, physically unplug the webcam, and let the entire
machine power off on success or failure. Remove AC and standby power where
practical before reconnecting another device.

### Authenticate the ciphertext

This subsection prevents GnuPG from parsing substituted camera bytes. Boot
without the webcam, move `key.asc` through the existing restricted path, and
perform the independent source/target 80-bit fingerprint comparison exactly as
the supported procedure requires. Stop permanently on a mismatch until a clean
receive is repeated.

### Enter component A with the keyboard

This subsection records only A in the trusted target. Boot with only the
keyboard connected and only the fresh keyboard backend running. Start the
trusted helper in its `record-A` mode, type A once, and have the helper validate
the Base32 alphabet and exact 26-character length before atomically storing it.
The terminal and helper must not echo A or retain it in history.

After confirmation, physically unplug the keyboard, destroy the keyboard
backend, shut the computer down, and remove standby power. B must remain folded
and unseen throughout this phase.

### Enter component B with the mouse and decrypt

This subsection completes decryption without reconnecting the keyboard. Boot
with only the mouse connected and only the fresh mouse backend running. Start
the randomized application in the trusted target, enter B by mouse, and confirm
the operation. The application combines B with stored A and invokes GnuPG
without exposing the combined passphrase through a general desktop input
channel.

On success, verify the destination mode, remove the target ciphertext and A
state, destroy the mouse backend, and power off before reconnecting ordinary
USB input. On any failure, install no plaintext and retain or remove A according
to an explicit, documented retry decision; never silently reuse ambiguous
partial state.

## Qubes and Salt implementation

This section lists the repository work needed to support the ceremony. Exact
names may change during implementation, but the boundaries may not.

1. Extend `salt/pillar/seqs/config.sls` with an explicit disabled-by-default
   3-of-3 mode and validated names for the camera, keyboard, mouse, scanner,
   staging, and target roles. Keep the catalogue independent of runtime
   selection.
2. Extend `salt/seqs/dom0.sls` to create minimal offline disposable backends and
   phase-specific qrexec policies. Validate the shared controller BDF and reject
   `no-strict-reset` exactly as sequential camera mode does.
3. Add the `qr-mouse-entry` component under
   `install-scripts/components/qr-mouse-entry/`, with the trusted application,
   a narrowly scoped launcher, and distribution-pinned dependencies recorded in
   `TRUST.md`.
4. Add a root-owned dom0 ceremony script that validates the expected controller
   and qube identities, ensures mutually exclusive device/backend state, and
   always powers off on success or failure. It may orchestrate qubes and display
   fixed sanitized status, but it must never receive A, B, `A || B`, ciphertext
   contents, target output, or executable code from a qube.
5. Add managed qrexec policy files through the existing no-clobber/takeover
   mechanism. Camera backends must retain the current input and general
   file-copy denies. Keyboard and mouse backends must receive only the exact
   input service and destination required for their phase, with explicit denies
   for the other input classes and file transfer.
6. Update `setup-qubes.sh` policy ownership metadata if new managed policy files
   are introduced. Preserve confirmation before taking over an unmarked file.
7. Update `docs/secure-qr-transfer.md` only after implementation so its user
   instructions describe real behavior. Update `TRUST.md` and
   `VERIFY-HUMAN.md` in the same change with the new trust assumptions,
   provisioning review, policy checks, and hardware rehearsal.

The orchestration design must first confirm how Qubes routes
`qubes.InputKeyboard` and `qubes.InputMouse` to a specific target while keeping
dom0 safe. The implementation must be based on tested Qubes behavior rather
than assumptions inferred from the local mock harness.

## Validation and tests

This section defines what must pass before documentation can call the mode
available. Start at the narrowest applicable layer, then run the complete
Qubes-free suite.

Add render assertions in `test/test_render.py` for valid disabled and 3-of-3
configurations, invalid names and BDFs, shared-role rejection, strict-reset
requirements, offline properties, backend disposition, and every generated
qrexec allow and deny. Verify that removal of the feature deletes only
SEQS-marked policy files.

Add unit tests for every ceremony helper: exact phase confirmation, device-count
bounds, backend exclusivity, cleanup traps, sanitized output, and unconditional
power-off after controller exposure. Add integration cases for policy takeover,
interrupted phases, wrong devices, failed attach/reset, scanner failure, and
failure to start the target helper. Mocks must never be reported as Qubes
hardware validation.

Test the randomized application independently with generated disposable data:

- all layouts contain every Base32 symbol exactly once;
- accepted clicks append the symbol from the displayed layout;
- the layout changes after each accepted click;
- boundary, drag, double-click, undo, cancel, and premature-confirmation events
  fail safely;
- no symbol is emitted as a desktop key event or copied to the clipboard;
- malformed or existing A state is rejected;
- GnuPG receives exactly `A || B` through the intended descriptor;
- failure installs no output and cleans ordinary temporary state; and
- logs, process arguments, environment, files, and UI text never contain test
  passphrases outside deliberately isolated fixtures.

Before completion, run `./test/run-tests.sh` and inspect the full diff. Then
perform a Qubes-only hardware rehearsal using disposable fake input, verifying
physical controller ownership, strict reset, qrexec routing, no NetVMs, device
exclusivity, forced shutdown on every failure path, randomized entry, successful
decryption, and absence of unexpected cross-qube services. Only that rehearsal
can validate actual Qubes device behavior.

## Acceptance criteria

This section states when the future work is complete. The feature is ready only
when all of the following are true:

- its documented security claim matches the implemented boundaries and
  residual risks;
- the camera, keyboard, and mouse phases are mutually exclusive and separated
  by complete power removal;
- strict reset cannot be disabled in this mode;
- each backend is fresh, offline, minimal, and denied unrelated qrexec
  services;
- the randomized mapping and both passphrase components exist only in trusted
  domains;
- dom0 never handles secret contents or target-produced data;
- the target helper does not synthesize keyboard input or use the clipboard;
- failure cannot install plaintext or return ordinary input without power-off;
- existing 2-of-2 dedicated and sequential modes remain unchanged; and
- the Qubes-free suite passes and the exact hardware-dependent checks performed
  on Qubes are reported without overstating their coverage.

