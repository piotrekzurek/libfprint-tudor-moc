# Protocol notes — Synaptics Tudor Match-In-Sensor (USB 06cb:00c9)

Working notes from reverse engineering the sensor in the HP Spectre x360
Convertible 13-aw2xxx. Written for someone who wants to re-derive this, not
just copy it.

## Device identity

| Property | Value |
|---|---|
| USB ID | `06cb:00c9` |
| Serial | `XXXXXXXXXXXX` (6 bytes, read from `GET_VERSION`) | (hex value, redacted)
| Firmware | 10.1 (build 2021-04-26, build num 3399660) |
| Product id | `0x41` |
| Target | `0x01` |
| Silicon revision | 1 |
| Security | `0xa10f` |
| Provision state | 3 (provisioned) |

`security = 0xa10f` decodes as:

- bit 0x001 — sensor is paired
- bit 0x100 — "advanced security", i.e. TLS-paired sessions are supported
- bit 0x200 — advanced security key flag
- **bit 0x020 is CLEAR**

That last one matters and is wrong for this device. See "Factory keys".

## Transport

Vendor-specific control requests plus a bulk IN endpoint. The driver frames
every command as:

```
request:   bRequest = VCSFW_CMD_*   (vendor, device-to-host)
wValue    = sequence number
wIndex    = 0
wLength   = expected response length

response:  status (2 bytes) followed by the payload
```

The status word is two bytes. In the BMKT driver's parser it is skipped rather
than interpreted, but the low byte carries a VCS result code.

Note that the status is **two** bytes, not one. Reading it as a single byte
misaligns every subsequent field.

## Pairing

`PAIR` is command `0x93`.

1. Host generates an ECDSA P-256 key pair and a host certificate, and sends
   the certificate (400 bytes) with the command.
2. Sensor answers with status, host certificate (400 bytes), sensor
   certificate (400 bytes).
3. Both sides derive the TLS session from the host private key.

The sensor was already provisioned here (Windows had paired it), so step 1 is a
*re-pair*: the sensor issues fresh certificates but keeps its template store.

### Why re-pairing loses enrollments

Observed directly: enroll a finger, let fprintd restart, and the template store
reads back empty (`Database is empty`, after which fprintd deletes its own record
of the print). Pairing data that is not persisted causes a re-pair on every
daemon start, and the re-pair appears to reset the partition. This is the
reason the driver persists pairing data itself.

## Certificates

400 bytes on the wire, little-endian:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic `0x5F3F` |
| 2 | 2 | curve, `23` = secp256r1 |
| 4 | 68 | host/sensor public key X |
| 72 | 68 | public key Y |
| 140 | 1 | padding |
| 141 | 1 | certificate type |
| 142 | 2 | signature length |
| 144 | 256 | signature |

The first **142** bytes are what the sensor signs:

```
SEQUENCE-less packed form: magic || curve || X || Y || pad || cert_type
                            2      2       68   68    1      1        = 142
```

Two consequences:

- The signature starts at offset **144**, not 142. The 2-byte length field sits
  between the signed region and the signature.
- The C struct is declared `#pragma pack(push, 1)` and its field order matches
  the wire format exactly, so `&cert` truncated to 142 bytes *is* the signed
  data. Reconstructing the 142 bytes from parsed fields also works, and is what
  the Python reference does via `signbytes()`.

The 68-byte coordinate fields hold a 32-byte value. The remaining 36 bytes are
zero padding; the significant bytes are the **last** 32 of each field.

## Signatures

ECDSA P-256 over SHA-256 of the 142 signed bytes.

The sensor returns the signature **DER-encoded**, 71 bytes for this device:

```
30 45                      SEQUENCE, 69 bytes
   02 20 <32 bytes>        INTEGER r
   02 21 00 <32 bytes>      INTEGER s, 33 bytes: leading 0x00 padding
```

The leading zero on `s` is required by DER because the top bit of the first
content byte is set. Handing this to GnuTLS unchanged with
`GNUTLS_SIGN_ECDSA_SHA256` works.

If you convert to raw `r||s` yourself, the padding is the trap: stripping
leading zeros with a `while (len > 32 && *p == 0)` loop and then copying from the
*start* of the integer leaves the result off by one byte. Verified by dumping
the raw value and comparing against an independent implementation.

## Factory keys

Two public keys ship in the vendor research repository, as `.tsk` files holding
68-byte little-endian coordinates per field:

| File | Meaning |
|---|---|
| `10.1.tsk` | keyflag = FALSE |
| `10.1-kf.tsk` | keyflag = TRUE |

`.tsk` layout: X at bytes 0..67, Y at bytes 68..135, each a 32-byte value in
little-endian order with 36 zero bytes of padding. A naive
`memcpy(field, k + offset, 32)` copies the zero padding and yields the point at
infinity; the significant bytes are the **last** 32 of each field.

### This device contradicts its key flag

The obvious mapping — choose the key from bit `0x20` of `security` — selects
`10.1.tsk`. That key does not verify this device's certificate. `10.1-kf.tsk`
does.

Confirmed independently: a certificate captured from the device was verified
against both keys with a from-scratch ECDSA implementation, with negative
controls to confirm the implementation rejects corrupt input.

```
10.1.tsk     -> no match
10.1-kf.tsk  -> VERIFIED
```

So for `product_id == 0x41` the keyflag=TRUE key is the correct one, and the
compatibility check has to agree.

## TLS session

After pairing, `TLS_DATA` (`0x44`) carries the session. The handshake is a
Tudor-specific exchange over an ECDSA-sealed channel: certificate exchange,
key derivation, then encrypted records.

Observed states: `prepare` → several `TLS_DATA` round trips → `finished`.

During the session the driver issues:

| Command | Purpose |
|---|---|
| `0x96` | enroll / identify / verify |
| `0x15` | TLS alert |
| `0x44` | TLS data |
| `0x74` / `0x73` | DB2 info / object list |
| `0xa5` | DB2 format (storage erase) |

Matching happens **on the sensor**. Templates never leave the device, so the
driver has no raw image path and no `print-buffer-format` concerns.

## Error codes seen

| Value | Meaning in this context |
|---|---|
| `0x0401` | `VCS_RESULT_SENSOR_BAD_CMD` |
| `0x0404` | `VCS_RESULT_GEN_OPERATION_DENIED_1` |
| `0x0068` (104) | returned by BMKT `ENROLL_USER`; see note below |
| TLS alert 42 | bad certificate |

A caution about `104`: the BMKT driver's table in `bmkt.h` calls it
`BMKT_OUT_OF_MEMORY`, while the vendor's VCS error table calls `0x68`
`VCS_RESULT_GEN_OPERATION_DENIED_1`. The two tables agree on the low numbers and
diverge above that. For this family, trust the VCS table. The "out of memory"
reading sent this investigation down a wrong path for a while.

## Commands that do not work on this device

`GET_SECURITY_LEVEL` (`0x34`) and `GET_DATABASE_CAPACITY` (`0x74`) both answer
`rsp = 0xc1` (general error) with result `105`. There is no key-flag
configuration command, and no way to query capacity. `RESET_OWNERSHIP` (`0x10`)
is rejected with `0x0401`. Do not build logic around these.

## Re-deriving this yourself

```bash
FP_SYNATUDOR_DEBUG=1 G_MESSAGES_DEBUG=all FP_DEBUG_TRANSFER=1 fprintd-enroll
```

That gives key dumps, certificate hex, and a hex dump of every USB transfer.
The pairing exchange is the interesting part:

```
---> 0x93 = VCSFW_CMD_PAIR
<--- 0x93 = VCSFW_CMD_PAIR
	Sensor certificate:
	Host certificate:
CERTDATA <142 bytes hex>
CERTSIG <71 bytes hex>
```

`CERTDATA` and `CERTSIG` are exactly what you need to re-check the key
selection offline, without a device in the loop.
