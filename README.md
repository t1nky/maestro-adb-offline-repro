# Maestro: one not-ready `adb devices` row hides every Android device

While any row of `adb devices` is not in the `device` state, Maestro can't see **any** Android
device, including ready ones, and fails with:

```
Device emulator-5560 was requested, but it is not connected.
```

Such a row is common: every emulator is `offline` for its first seconds of boot and again while it
shuts down, and a phone waiting for its RSA prompt is `unauthorized`. Anyone running several
emulators in parallel hits this whenever one of them starts or stops.

Seen with Maestro 2.11.0 (dadb 2.0.0). Upstream issue: [mobile-dev-inc/Maestro#3706](https://github.com/mobile-dev-inc/Maestro/issues/3706)

## Reproduce

### Without a device (seconds)

Runs Maestro's own Android device listing (`AndroidDeviceConnection.listFromAdbServer`, the
variant of the CLI's listing that takes an adb server port) against a stub adb server:

```bash
./no-device/run.sh
```

Maestro 2.11.0:

```
Maestro jars: ~/.maestro/lib
adb devices: emulator-5560=device emulator-5562=device → listed [emulator-5560, emulator-5562]
adb devices: emulator-5560=device emulator-5562=offline → threw java.io.IOException: Command failed (host:transport:emulator-5562): device offline
adb devices: emulator-5560=device R58N12345=unauthorized → threw java.io.IOException: Command failed (host:transport:R58N12345): device unauthorized
```

### With one ready device or emulator

Runs a trivial flow (`flows/home.yaml`, presses Home) three times: alone, while another row is
`offline`, and after that row is gone. The `offline` row is an `adb connect` to a local socket that
never answers, so the result doesn't depend on timing; the script disconnects it afterwards.

```bash
./repro.sh --device emulator-5554       # a device that is already `device` in adb
./repro.sh --avd Pixel_8                # or boot an AVD (read-only, no window) on port 5560
```

Maestro 2.11.0:

```
Maestro 2.11.0 (maestro)
booting Pixel_8 on emulator-5560…
device under test: emulator-5560
  1. alone                           PASS
  2. while 127.0.0.1:5999 is offline FAIL: Device emulator-5560 was requested, but it is not connected.
  3. after that row is gone or ready PASS

adb devices before each step:
  1. alone                           emulator-5560=device
  2. while 127.0.0.1:5999 is offline 127.0.0.1:5999=offline, emulator-5560=device
  3. after that row is gone or ready emulator-5560=device
REPRODUCED: emulator-5560 was ready in all three steps, but Maestro could not see it in step 2.
```

### The real-world trigger: a second emulator booting

```bash
./repro.sh --avd Pixel_8 --boot-neighbour
```

Step 2 then runs while a second emulator (port 5562) is still `offline`. Its offline window is a few
seconds, so on a very fast machine step 2 can miss it; the script says so and exits 2.

## Checking a fix

Both scripts take another Maestro build:

```bash
MAESTRO_LIB=<maestro checkout>/maestro-cli/build/install/maestro/lib ./no-device/run.sh
MAESTRO=<maestro checkout>/maestro-cli/build/install/maestro/bin/maestro ./repro.sh --avd Pixel_8
```

`repro.sh` exits 1 when the bug reproduces and 0 when step 2 passes too. A fix: [mobile-dev-inc/Maestro#3707](https://github.com/mobile-dev-inc/Maestro/pull/3707)

## Why

dadb's `AdbServer.listDadbs()` creates a connection for every row of `adb devices`, whatever its
state, and each connection asks the device for its features straight away. For an `offline` or
`unauthorized` row the adb server refuses (`device offline`), so the whole listing throws.
Maestro's `DeviceService.listAndroidDevices()` catches that and returns an empty list, so the device
you asked for looks "not connected", and nothing reaches `maestro.log`. Details and links to the
code are in the issue.

## Requirements

Android SDK (`adb`, `emulator`; `ANDROID_HOME` or `ANDROID_SDK_ROOT`, default
`~/Library/Android/sdk`), Maestro, Python 3, and Java 17+ (`JAVA_HOME`, as Maestro uses).
