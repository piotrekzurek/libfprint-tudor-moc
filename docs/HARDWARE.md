# The fingerprint reader in this HP Spectre x360 Convertible 13-aw2xxx

## Hardware

| | |
|---|---|
| Model | HP Spectre x360 Convertible 13-aw2xxx |
| Sensor | Synaptics "Tudor" match-on-chip |
| USB ID | `06cb:00c9` |
| Bus | 003, port 9, device 3 (via an internal USB hub) |
| Serial | `XXXXXXXXXXXX` | (redacted hex value)            
| Firmware | 10.1, released 2021-04-26 |

Check what is actually attached:

```bash
lsusb | grep -i synaptics
lsusb -t | grep -A3 'Synaptics'
```

In `/sys/class/leds` you may see the sensor's LED node, which is a convenient
confirmation that the device enumerates.

## The problem, in one paragraph

`libfprint` ships a `synaptics` driver that matches on the USB vendor and a list
of product IDs. `06cb:00c9` is not on that list, but it is close enough to the
supported ones that adding it makes the driver claim the device. That is where
the trouble starts: the device does not speak the BMKT protocol that driver
implements, so everything looks fine until enrollment, and then fails within
milliseconds. Upstream is aware of the general problem — the device is commonly
described as "mis-claimed by `synaptics`, without working enroll or verify".

## How the failure presents

```
$ fprintd-enroll
Enroll result: enroll-stage-passed
...
Enroll result: enroll-disconnected
ReleaseDevice failed: fpi_byte_reader reading error
```

`enroll-disconnected` is the visible symptom. The interesting line is in the
journal:

```
Device responded with status: 0x0401 aka VCS_RESULT_SENSOR_BAD_CMD
```

and, when the pairing path is involved:

```
TLS alert: description: 42 aka bad certificate
```

## Why "it half works" is misleading

An early build appeared to enroll successfully: `enroll-completed`, and
`fprintd-list` showed the finger. Then verification failed and the finger
vanished from the list.

That was not a working enrollment. The driver was shipping with
`USE_SAMPLE_PAIRING_DATA` defined, so it never issued a `PAIR` command at all.
It loaded a **hard-coded certificate captured from a different sensor**, and
that certificate does not verify against this device's factory key. The sensor
accepted the enroll command, stored a template, and the driver then failed on
every subsequent session because it could not establish a valid TLS session.

The giveaway was in the log: the certificate bytes began
`3f 5f 17 00 32 29 44 49 1e 0e 65 4d`, which is precisely the first twelve bytes
of `sample_sensor_cert` in the vendor research repository.

Worth stating plainly, because it cost real time: apparent partial success in
a driver like this is usually stale or synthetic data, not a partial success.

## What the change does

A new driver, `syna_tudor_moc`, implements the Tudor protocol in C. No vendor
binary runs at fingerprint time.

### Fixes that were required

Five separate defects had to be corrected before enrollment worked. Each was
found from evidence, and each is documented in `PROTOCOL.md`.

1. **Sample pairing data was compiled in.** `USE_SAMPLE_PAIRING_DATA` was
   defined in the driver, so pairing never happened. Now opt-in.

2. **Pairing is asynchronous; `open()` did not wait for it.**
   `fetch_pairing_data()` issued `PAIR`, then tried to store pairing data that
   had not arrived, aborting the daemon. It also advanced to certificate
   verification immediately, which then ran against a zero-length signature
   (`sign_size=0`). A `pairing_pending` flag holds the open state machine until
   `recv_pair()` resumes it, and the store happens where the certificates land.

3. **Wrong factory key for product `0x41`.** The device reports key flag clear,
   which selects `10.1.tsk`, but its certificate is signed with `10.1-kf.tsk`.
   Product `0x41` now selects the key that actually verifies, verified offline
   against both.

4. **A hand-written DER-to-raw signature conversion was wrong.** The sensor
   returns a 71-byte DER signature whose `s` is a 33-byte integer with leading
   zero padding. Converting it by hand dropped a byte and verification always
   failed. GnuTLS decodes DER natively, so the conversion was deleted.

5. **The persistent-data property used the wrong accessors.** The property is
   declared with `g_param_spec_variant()`, but the setter and getter called
   `g_value_dup_boxed()` / `g_value_set_boxed()`, which do not work for a
   variant-typed property. Every stored value was lost, which is what forced a
   re-pair on every daemon start, which is what lost the enrollments.

6. **Enrollment completed twice.** `enroll_ssm_done()` called
   `fpi_device_enroll_complete()` on the success path and then fell through to
   its `error:` label and called it again. The first call returned the result to
   fprintd, so enrollment *looked* correct; the second returned an
   already-consumed `GTask`, tripping GLib's assertion:

   ```
   g_task_return_pointer: assertion 'G_IS_TASK (task)' failed
   ```

   The first call also took an extra `FpPrint` reference that the second call
   never released. Completion is now issued exactly once.

   This one is worth remembering for a different reason: it had no functional
   symptom at all. Only the assertion in the journal gave it away, and only
   because the log happened to be read. The same shape — code that succeeds and
   then misreports having succeeded — accounted for most of the wasted effort on
   this driver.

### Pairing persistence

Stock fprintd has no support for the `fpi-persistent-data` property: it never
saves it and never loads it. Upstream libfprint ships a patch for fprintd
(`fprintd-load-store-persistent-data-from-device.patch`) that adds it, but stock
Fedora does not carry that patch.

So the driver persists pairing data itself, to
`/var/lib/fprint/syna_tudor_moc-<serial>.pdata`, in an explicit fixed layout
(magic `STM1`, both certificates, curve, and the three ECC key components). The
format is deliberately explicit rather than a serialised `GVariant`: a tuple
whose children are themselves variants does not round-trip reliably through
`g_variant_new_from_data()`, which returns NULL for the indefinite tuple type.

Writing into another daemon's directory is not ideal, and the honest fix is the
small fprintd patch. See `docs/fprintd-persistent-data.md`.

## Debugging

Off by default:

```bash
FP_SYNATUDOR_DEBUG=1 G_MESSAGES_DEBUG=all journalctl -u fprintd -f
```

Raw USB transfers:

```bash
FP_DEBUG_TRANSFER=1 G_MESSAGES_DEBUG=all fprintd-enroll
```

## Files that matter

| Path | What is in it |
|---|---|
| `libfprint/drivers/syna_tudor_moc/tls.c` | TLS, certificate verification, pairing |
| `libfprint/drivers/syna_tudor_moc/syna_tudor_moc.c` | open/enroll/verify state machines, persistence |
| `libfprint/drivers/syna_tudor_moc/communication.c` | USB framing, `recv_pair`, DB2 storage |
| `libfprint/drivers/syna_tudor_moc/sensor_keys.h` | factory keys |
| `libfprint/drivers/syna_tudor_moc/device.h` | on-device structures |

## Known limitations

- Tested only on this model, firmware 10.1, product `0x41`
- The unpair path is untested
- Pairing with Linux invalidates the Windows Hello pairing and vice versa; the
  templates live in one partition and the pairing is exclusive
- The pairing cache is written by the driver, which a maintainer may reasonably
  object to; a companion fprintd patch is the proper fix
