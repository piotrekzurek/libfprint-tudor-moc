# Post drafts

Three lengths: a short hook, a LinkedIn post, and a longer blog version.

---

## 1. Short — for X / LinkedIn headline

I gave an AI a laptop nobody else wanted and a fingerprint reader nobody could
use. It shipped a working native driver.

No vendor blobs. No paid tokens. ~26M in, ~500K out.

Details on how 👇

---

## 2. LinkedIn post

I was handed a laptop for testing. It had a fingerprint reader that no Linux
driver could enroll — the kind of device where you spend an evening convinced
the hardware is broken, then discover the driver is lying to you.

So I asked an AI to fix it.

What came back was not a workaround. It was a native C driver, written from
scratch, that speaks the sensor's actual protocol — TLS pairing, certificate
exchange, on-sensor matching. No vendor binaries running at fingerprint time.
The kind of thing you'd upstream.

The hard part wasn't the cryptography. It was that the device *almost* worked,
and every wrong answer looked plausible:

- an early build appeared to enroll perfectly, then silently lost the
  fingerprint. It had been shipping a hard-coded certificate captured from a
  different unit, and was quietly failing every session
- the sensor's own metadata said one thing, its certificate said another. We
  proved which to believe by verifying a captured certificate against both
  candidate keys with a from-scratch ECDSA implementation
- several bugs were bugs *I* introduced while chasing the first bug

It ran about 26 million input tokens and half a million output tokens. It was
sponsored by the Kilo Code extension for VS Code, using their free shared models
— no account, no card. My direct cost: roughly zero.

The only real prerequisite was hands-on access to the machine. Because it was a
test device rather than my own, I could install unsigned builds, reboot fifty
times, and read kernel logs without worrying about anything that mattered.

That is the whole lesson, and I keep coming back to it: the scarce resource was
never compute. It was a device I was allowed to break.

---

## 3. Blog version

### I gave an AI a broken fingerprint reader. It shipped a driver.

A few months ago I was given a laptop — an HP Spectre x360 — to use as a test
machine. Not a production device. A machine I could install unsigned packages
on, reboot forty times, and put into a state I would never have to explain to
anyone.

It had a fingerprint reader that did not work under Linux.

Not "sometimes." Not "flaky." It simply could not enroll a finger. The failure
looked like hardware, and for a while it genuinely was ambiguous.

## The lie in the logs

The reader is a Synaptics match-on-chip sensor on USB `06cb:00c9`. Linux's
`libfprint` ships a driver for Synaptics fingerprint sensors, and if you add this
product ID to its list, the driver claims the device. Probe succeeds. The
device enumerates. Everything looks like it is going to work.

Then enrollment dies six milliseconds after the command is sent — before you
have put a finger anywhere near it.

That six-millisecond detail turned out to be the whole story.

The device belongs to a different family than the driver expects. It speaks a
protocol with TLS pairing, certificates, and 400-byte structures that the
existing driver does not parse. The existing driver was not buggy so much as
addressing a different device, and it did not know it.

## What AI actually did

I pointed a coding agent at it and worked alongside it. Not "write me a driver
in one shot" — a long iterative loop, mostly me interpreting evidence and
steering, mostly it doing the reading, the instrumenting, the building, the
rebuilding, and the ten-thousand-line debugging.

The output is a native driver in C. It performs real TLS pairing, verifies the
sensor's certificate against a factory key, runs enrollment and verification
over an encrypted channel, and persists pairing data across reboots. Matching
happens on the sensor, so no fingerprint images ever leave the device.

No vendor binaries are loaded. At fingerprint time, the code running is code
anyone can read.

Verified on Fedora: enroll several fingers, verify them, reject other fingers,
unlock the screen. It survived reboots, which turned out to be its own subtle
bug.

## The part I keep telling people

The cryptography was not the hard part. The hard part was that the device
*falsely appeared to work*, and every wrong answer was internally consistent.

Here are three moments where I was confident and wrong:

**One.** An early build enrolled a finger successfully. Listed it. Then
verification failed and the fingerprint vanished. The explanation: the driver
was never talking to the sensor at all. It had a hard-coded certificate
captured from a *different unit* compiled in, and was failing every session in
a way that looked like success at first. The tell was twelve bytes of hex in the
log matching a sample file byte for byte.

**Two.** The sensor reports which factory key signed its certificate, in a
status field. The field said one thing. The certificate said another. We settled
it by taking a certificate off the device and checking it against both
candidate keys with an ECDSA implementation written from scratch — including
negative controls, because a verifier that always says yes is worse than no
verifier.

**Three.** My own hand-written code converting a DER signature to raw form was
subtly wrong in exactly the way that looks correct. I introduced that bug while
fixing an earlier one. Deleting the code and letting the crypto library decode
it was the fix.

That third one is why I think about this differently now. The task was not
"write a driver." It was "keep discarding explanations that survive contact with
evidence." That is a discipline, and it happens to be one a machine is very
good at and a tired human at hour three is not.

## The numbers, and the honest caveat

About 26 million input tokens, about 500 thousand output tokens. Large, and I
will not pretend otherwise.

It was sponsored by the Kilo Code extension for VS Code, using their free
shared models. No subscription, no account, no card. My out-of-pocket cost:
approximately zero dollars.

The input number is inflated by my own iterative style — long log dumps, full
file contents, repeated build cycles. A person who batched more aggressively
would spend less and probably finish slower.

## What actually mattered

Not the tokens. Not the model.

A machine I was allowed to break.

I did not have to ask permission before installing an unsigned RPM, before
rebooting for the fortieth time, before wiping a partition that held someone's
Windows Hello enrollment. Every experiment that would have been irresponsible
on a personal machine was obvious here.

If you want to try this: find a device you can ruin, point an agent at it, and
be prepared to do the part it cannot — deciding which explanation to discard.

That is the whole thing. The rest is tooling.
