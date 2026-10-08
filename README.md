# libfprint-tudor-moc — fingerprint support for HP Spectre x360 Convertible 13-aw2xxx

Native `libfprint` support for the Synaptics Match-In-Sensor fingerprint reader
found in the **HP Spectre x360 Convertible 13-aw2xxx** (USB ID `06cb:00c9`).

The in-tree `libfprint` `synaptics` driver claims this device but cannot
complete an enrollment: the sensor belongs to the *Tudor* family, which
requires a TLS-paired session and a slightly different certificate layout. This
repository adds a driver (`syna_tudor_moc`) that implements that protocol
natively in C, so no vendor binaries are loaded at runtime.

Everything here runs against your ordinary Fedora installation. There is no
vendor code executing at fingerprint time.

---

## What works

Verified on Fedora Silverblue 44, kernel 7.2, `libfprint` 1.94.100:

- Enrollment of multiple fingers through GNOME Settings and `fprintd-enroll`
- `fprintd-verify` accepts enrolled fingers and rejects other fingers
- Screen unlock with an enrolled finger
- Pairing data survives reboots and fprintd restarts

---

## Install using code/fork

### 1. Get an RPM

Download the RPM matching your Fedora release from the
[Releases](../../releases) page, or build it yourself:

```bash
git clone https://github.com/piotrekzurek/libfprint-tudor-moc
cd libfprint-tudor-moc
sudo dnf install -y rpmrebuild rpm-build meson ninja-build \
    gcc glib2-devel libgudev-devel gnutls-devel \
    openssl-devel gobject-introspection-devel systemd-devel
./scripts/build-rpm.sh
```

The script detects your Fedora version automatically, so it keeps working when
a new release ships.

### 2. Layer it onto your system (if on Silverblue (rpm-ostree))

```bash
sudo rpm-ostree override replace dist/libfprint-*.fc44.x86_64.rpm
sudo systemctl reboot
```

`rpm-ostree override` is used because Fedora Silverblue mounts `/usr` read-only.
This is the supported way to replace a system library; it creates a new
deployment and therefore needs a reboot.

### 3. Enroll a finger

```bash
fprintd-enroll
```

or use **Settings → Users → Fingerprint Login**.

---

## Revert

```bash
sudo rpm-ostree override reset libfprint
sudo systemctl reboot
```

Note that the sensor keeps the templates enrolled in its own storage, so after
reverting, the in-tree `synaptics` driver will still claim the device and still
fail to enroll. Clearing the sensor's storage from the driver before reverting
avoids that:

```bash
# with this driver still installed
flatpak-spawn --host /usr/libexec/fprintd   # then, from GNOME, remove fingerprints
```

---

## How it works

```
USB 06cb:00c9   vendor control / bulk endpoints
      |
      |  VCSFW command framing over vendor control + bulk IN
      v
  sensor firmware  (Synaptics "Tudor", firmware 10.1, product 0x41)
```

The device is a match-on-chip sensor: fingerprint matching happens inside the
sensor, and it is paired with the host over a TLS-like session. The driver:

1. Reads the sensor certificate and verifies its ECDSA signature against a
   factory signing key (`10.1-kf.tsk`, shipped in the driver)
2. Exchanges a host certificate and derives a shared session
3. Runs enrollment / verification commands over the encrypted channel
4. Stores templates in the sensor's internal DB2 partition

Pairing data (host certificate, host private key) is persisted to
`/var/lib/fprint/syna_tudor_moc-<serial>.pdata`, because stock fprintd does not
carry the `fpi-persistent-data` property across restarts.

Full protocol notes, including every deviation from upstream, are in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md).

---

## Debugging

The driver keeps its reverse-engineering traces behind an environment variable.
They are off by default:

```bash
FP_SYNATUDOR_DEBUG=1 G_MESSAGES_DEBUG=all journalctl -u fprintd -f
```

That re-enables key dumps, certificate hex, and pairing internals.

For raw USB traffic, `FP_DEBUG_TRANSFER=1` gives a hex dump of every transfer:

```bash
FP_DEBUG_TRANSFER=1 G_MESSAGES_DEBUG=all fprintd-enroll
```

---

## Layout

```
patches/     the driver patch, ready to send upstream
scripts/     RPM build script
docs/        protocol notes and the hardware write-up
```

The patch applies to upstream `libfprint` and is self-contained: it adds the
driver, registers it in the build, and fixes the certificate handling that
upstream's copy of the driver gets wrong.

---

## License

The driver is LGPL-2.1-or-later, matching `libfprint`. See
`docs/LICENSE-NOTES.md` for attribution of the parts derived from other work.
