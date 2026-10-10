# MIDIShare

Stream MIDI from one Mac to another over your local network.

MIDIShare captures MIDI input (notes, CCs, pitch bend, etc.) from hardware controllers connected to one Mac and forwards it over TCP to another Mac, where it appears as a virtual MIDI port. Use it to play a controller plugged into one machine while recording in a DAW (Ableton, Logic, etc.) on another.

## How it works

The project builds two small native macOS apps:

- **MIDIShare Server** — runs on the Mac with the MIDI controller attached. It lists available MIDI sources, lets you pick which ones to broadcast, and streams their messages to connected clients over TCP (port `17249`). It advertises itself on the local network via Bonjour (`_midishare._tcp`).
- **MIDIShare Client** — runs on the Mac with your DAW. It creates a virtual MIDI port (name of your choosing), discovers the server automatically via Bonjour (or connects to a manually entered IP), and replays received MIDI messages into the virtual port.

Both apps show a live log of every MIDI message sent or received.

```
[MIDI controller] → Mac A (Server) ──TCP/LAN──→ Mac B (Client) → virtual MIDI port → DAW
```

### Wire protocol

Messages are sent as length-prefixed TCP frames: a 4-byte big-endian length, then a payload of `"MSHR"` magic, a 32-bit sequence number, a message count, and 3-byte MIDI messages. TCP_NODELAY is enabled on both ends to keep latency low.

## Building

Requires Xcode command line tools (macOS 10.14+ target).

```sh
./build.sh
```

This compiles both apps into `build/MIDIShare Server.app` and `build/MIDIShare Client.app`.

## Usage

1. Copy **MIDIShare Server.app** to the Mac with the MIDI controller and launch it.
2. Check the MIDI sources you want to share and click **Start**.
3. Copy **MIDIShare Client.app** to the Mac running your DAW and launch it.
4. Enter a virtual port name (default `MIDIShare`) and click **Start**. The client finds the server via Bonjour automatically, or you can type the server's IP and click **Connect**.
5. In your DAW, enable the virtual port as a MIDI input (e.g. in Ableton: Preferences → MIDI → enable "MIDIShare" as Track/Remote input).

## Notes

- Supports channel voice messages (note on/off, CC, pitch bend, program change, channel/poly aftertouch). SysEx and realtime messages are not forwarded.
- Both Macs must be on the same local network; macOS will prompt for local network permission on first launch.
- The server accepts multiple clients at once.
