#!/usr/bin/env bash
#
# build-rpm.sh - build a patched libfprint RPM for the running Fedora release.
#
# The package replaces the distribution libfprint with one that adds the
# syna_tudor_moc driver, which enables the Synaptics Match-In-Sensor fingerprint
# reader found in the HP Spectre x360 Convertible 13-aw2xxx (USB 06cb:00c9).
#
# Why a rebuilt RPM rather than a file drop-in: Fedora Silverblue mounts /usr
# read-only (ostree), so the only supported way to change a system library is to
# layer a package with rpm-ostree.
#
# The Fedora version is detected from the host, so this keeps working when a
# new Fedora release ships.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HERE/out}"
JOBS="${JOBS:-$(nproc)}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- host probe

FEDORA_VER="$(rpm -E %fedora || true)"
[[ -n $FEDORA_VER ]] || die "cannot detect Fedora version (rpm -E %fedora)"

LIBFPRINT_VER="$(rpm -q --qf '%{version}-%{release}' libfprint)"
log "host: Fedora $FEDORA_VER, libfprint $LIBFPRINT_VER"

command -v dnf >/dev/null || die "dnf not found"
command -v rpmrebuild >/dev/null || die "rpmrebuild not found (dnf install rpmrebuild)"

BUILDROOT="$OUT/build-$FEDORA_VER"
SRC="$OUT/src-$FEDORA_VER"
mkdir -p "$OUT"

# ------------------------------------------------------------- fetch sources

log "fetching libfprint-$LIBFPRINT_VER source and binary RPM"
dnf -y download --source --destdir "$OUT" "libfprint-$LIBFPRINT_VER" \
  || die "source RPM not available for libfprint-$LIBFPRINT_VER"
dnf -y download --destdir "$OUT" "libfprint-$LIBFPRINT_VER" \
  || die "binary RPM not available"

SRPM="$(ls -1 "$OUT"/libfprint-"$LIBFPRINT_VER"*.src.rpm 2>/dev/null | head -1 || true)"
BINRPM="$(ls -1 "$OUT"/libfprint-"$LIBFPRINT_VER"*.x86_64.rpm 2>/dev/null | head -1 || true)"
[[ -n $SRPM ]] || die "source RPM did not download"
[[ -n $BINRPM ]] || die "binary RPM did not download"

log "extracting sources into $SRC"
rm -rf "$SRC" "$BUILDROOT"
mkdir -p "$SRC" "$BUILDROOT"
rpm2cpio "$SRPM" | (cd "$SRC" && cpio -idm --quiet)

PKGVER="$(sed -n 's/^Version:[[:space:]]*//p' "$SRC"/*.spec | head -1)"
PKGREL="$(sed -n 's/^Release:[[:space:]]*//p' "$SRC"/*.spec | head -1)"
[[ -n $PKGVER ]] || die "cannot read Version from spec"

# New release string: keep Fedora's, append our marker so the NEVRA differs
# from the base package. rpm-ostree refuses to layer a package with the same
# NEVRA as the one already in the image.
NEWREL="$PKGREL.tudormoc1"
log "new package release: $PKGREL -> $NEWREL"

# ------------------------------------------------------------ apply patches

DRIVERDIR="$SRC/libfprint-drivers-$PKGVER/libfprint/drivers/syna_tudor_moc"
if [[ ! -d $DRIVERDIR ]]; then
  DRIVERDIR="$(dirname "$(find "$SRC" -type d -name syna_tudor_moc -print -quit)")"
fi
[[ -d $DRIVERDIR ]] || die "syna_tudor_moc driver not found in the source tree"

log "applying driver patch"
( cd "$SRC" && patch -p1 --forward --batch < "$HERE/patches/0001-syna_tudor_moc-add-HP-Spectre-x360-13-aw2xxx-support.patch" ) \
  || die "patch application failed"

# ------------------------------------------------------- register the driver

log "registering the driver in the build"
for f in libfprint/meson.build meson.build; do
  [[ -f $SRC/$f ]] && { echo "would edit $f"; }
done

# The driver needs GnuTLS. Wire the helper dependency in the same way the
# upstream driver list expects, and drop the sources into driver_sources.
python3 - "$SRC" <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1])

# --- libfprint/meson.build: add sources + gnutls helper entry
p = src / "libfprint" / "meson.build"
s = p.read_text()
if "syna_tudor_moc" not in s:
    s = s.replace(
        "    'goodixmoc' : files(",
        "    'syna_tudor_moc' : files(\n"
        "        'drivers/syna_tudor_moc/syna_tudor_moc.c',\n"
        "        'drivers/syna_tudor_moc/container.c',\n"
        "        'drivers/syna_tudor_moc/pairing_data.c',\n"
        "        'drivers/syna_tudor_moc/utils.c',\n"
        "        'drivers/syna_tudor_moc/communication.c',\n"
        "        'drivers/syna_tudor_moc/tls.c',\n"
        "    ),\n"
        "    'goodixmoc' : files(",
        1)
    s = s.replace(
        "    'openssl': files(),",
        "    'openssl': files(),\n    'gnutls': files(),",
        1)
    p.write_text(s)
    print("  libfprint/meson.build: registered driver")

# --- top meson.build: declare gnutls helper + dependency
p = src / "meson.build"
s = p.read_text()
if "'gnutls'" not in s:
    s = s.replace(
        "    'synaptics': {},",
        "    'synaptics': {},\n    'syna_tudor_moc': { 'helper': ['gnutls'] },",
        1)
    s = s.replace(
        "        optional_deps += openssl_dep",
        "        optional_deps += openssl_dep\n"
        "    elif i == 'gnutls'\n"
        "        gnutls_dep = dependency('gnutls', version: '>= 3.6', required: false)\n"
        "        if not gnutls_dep.found()\n"
        "            error('GnuTLS is required for @0@'.format(driver))\n"
        "        endif\n"
        "        libfprint_conf.set10('HAVE_GNUTLS', true)\n"
        "        optional_deps += gnutls_dep",
        1)
    p.write_text(s)
    print("  meson.build: gnutls helper declared")
PY

# --------------------------------------------------------------- bump release

log "bumping spec Release to $NEWREL"
sed -i "0,/^Release:/s/^Release:.*/Release: $NEWREL/" "$SRC"/*.spec

# ------------------------------------------------------------------- build

log "building (this takes a few minutes)"
rpmbuild --define "_topdir $BUILDROOT" \
         --define "_sourcedir $OUT" \
         --define "dist .fc$FEDORA_VER" \
         --define "_build_id_links no" \
         --define "vendor tuna.tsinghua.edu.cn" \
         --target=x86_64 \
         -ba "$SRC"/*.spec \
  || rpmbuild --define "_topdir $BUILDROOT" \
              --define "_sourcedir $OUT" \
              --define "dist .fc$FEDORA_VER" \
              --target=x86_64 \
              -ba "$SRC"/*.spec \
  || die "rpmbuild failed"

RPM="$(find "$BUILDROOT" -name 'libfprint-*.x86_64.rpm' -print -quit)"
[[ -n $RPM ]] || die "no RPM produced"

mkdir -p "$HERE/dist"
cp "$RPM" "$HERE/dist/"
log "built $HERE/dist/$(basename "$RPM")"

cat <<EOF

Install with:

    sudo rpm-ostree override replace dist/$(basename "$RPM")
    sudo systemctl reboot

Revert with:

    sudo rpm-ostree override reset libfprint
EOF
