# 6soz-lr35902

An LR35902 CPU implementation in Zig. This package serves as the CPU core for the `6soz-gameboy` emulator.

## Features

The package implements the complete base and CB-prefixed instruction sets, flags, cycle accounting, interrupts, delayed IME behavior, HALT/STOP states, the HALT bug, and stack operations.

- Cycle-accurate step results.
- Type-erased 16-bit bus interface.
- Support for GBC-specific features (Double Speed mode).

## Usage

The CPU requires a `Bus` implementation that provides `read` and `write` methods.

```zig
const lr35902 = @import("lr35902");

var cpu = lr35902.Cpu.init();
var bus = MyBus.init();

const result = try cpu.step(&bus, interrupt_enable, &interrupt_flags);
// result.cycles contains the number of cycles consumed by the instruction
```

## Build & Test

```sh
zig build
zig build test
```

