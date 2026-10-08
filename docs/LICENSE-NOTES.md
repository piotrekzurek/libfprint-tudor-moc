# Attribution and licensing

## Driver origin

`syna_tudor_moc` was published as a research prototype by Vojtěch Pluskal
(<https://github.com/vojtapl/synaTudorMiS>), licensed LGPL-2.1-or-later, and
describes itself as based on work by Popax21
(<https://github.com/Popax21/synaTudor>). Both are credited in the file
headers.

This repository carries that driver with corrections, not as new code. The
changes are listed in `docs/HARDWARE.md` under "What the change does".

## Factory keys

`sensor_keys.h` contains two ECDSA public keys, taken from the `.tsk` files in
the same research repository:

- `10.1.tsk` — keyflag = FALSE
- `10.1-kf.tsk` — keyflag = TRUE

These are public keys, used solely to verify certificates the sensor presents.
Publishing them is unavoidable for any independent implementation; the Windows
driver uses the same keys.

## What this repository does not contain

No vendor binary, blob, or disassembled code executes at fingerprint time. The
vendor research repository was used as a protocol reference and as the source
for the two public keys. The `synatlsmoc` and `close` drivers from that
repository are not included, and neither is the Windows-driver-linking approach
of `Popax21/synaTudor`.

## Our changes

The fixes listed in `docs/HARDWARE.md` were derived by reading the sensor's
behaviour and its USB traffic. Two of them were found by checking the work
independently rather than by reading it:

- the factory key selection, resolved by verifying a captured certificate
  against both candidate keys with a from-scratch ECDSA implementation, with
  negative controls
- the DER signature handling, resolved by dumping the raw `r||s` and comparing
  it byte for byte against the expected value

## License

The driver is LGPL-2.1-or-later, matching libfprint. The build script and
workflow in this repository are MIT-licensed, so they can be reused freely.
