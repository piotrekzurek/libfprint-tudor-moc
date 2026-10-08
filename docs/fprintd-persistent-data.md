# fprintd: persistent-data support

`libfprint`'s `fpi-persistent-data` property exists so that a driver can hand
back an opaque blob that the daemon persists between sessions. The `syna_tudor_moc`
driver needs it: it holds the host certificate and private key that let it
re-establish the sensor's TLS session without re-pairing.

Stock fprintd does not implement save or load for that property. The driver's
`fetch_pairing_data()` reads it and `store_pairing_data()` sets it, but the value
never survives a daemon restart. On this device that is not merely an
inefficiency: re-pairing resets the sensor's template partition, so templates
disappear and fprintd deletes its own record of them.

libfprint upstream notes the requirement with a companion patch,
`fprintd-load-store-persistent-data-from-device.patch`. This note describes the
same change, so it can be reviewed on its own merits rather than as a patch
against a tree most reviewers do not have.

Repository: <https://gitlab.freedesktop.org/libfprint/fprintd>

## The change

### 1. Load on construction

In `fprint_device_constructed()`, read the property from the device and hand it
to the driver before the device is opened:

```c
static void
fprint_device_constructed (GObject *object)
{
  FprintDevice *self = FP_DEVICE (object);

  /* Hand the driver whatever we persisted for it last time. */
  g_autoptr (GVariant) persistent_data = NULL;
  if (self->storage != NULL)
    persistent_data = fprint_storage_get_persistent_data (self->storage);

  if (persistent_data != NULL)
    g_object_set (self->dev, "fpi-persistent-data", persistent_data, NULL);

  G_OBJECT_CLASS (fprint_device_parent_class)->constructed (object);
}
```

### 2. Save on dispose

In `fprint_device_dispose()`, read the property back and push it into storage
before the device goes away:

```c
static void
fprint_device_dispose (GObject *object)
{
  FprintDevice *self = FP_DEVICE (object);
  g_autoptr (GError) error = NULL;
  g_autoptr (GVariant) persistent_data = NULL;

  g_hash_table_remove_all (self->clients);

  /* The driver may have refreshed its pairing data during the session. */
  g_object_get (self->dev, "fpi-persistent-data", &persistent_data, NULL);
  if (persistent_data != NULL && self->storage != NULL)
    if (!fprint_storage_set_persistent_data (self->storage,
                                             persistent_data, &error))
      g_warning ("Failed to save persistent data: %s", error->message);

  G_OBJECT_CLASS (fprint_device_parent_class)->dispose (object);
}
```

The device-specific file storage already keys its files by device id, so the
blob lands in the same place as the rest of that device's state.

## What this buys

- The driver reuses its pairing data instead of re-pairing
- Templates in the sensor's partition are left alone
- Enrollments survive daemon restarts and reboots

With it in place, the file-based cache in the Fedora packaging of
`syna_tudor_moc` can be deleted, and the driver can rely on the property alone,
which is the arrangement upstream expects.

## Testing

```bash
fprintd-enroll
systemctl restart fprintd
fprintd-verify      # enrolled finger must still verify
journalctl -u fprintd | grep -i "pair sensor"   # must be absent
```

The absence of a re-pair attempt in the journal is the signal that persistence
is working.
