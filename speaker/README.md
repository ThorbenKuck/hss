# Speaker Setup

This is the speaker setup for an upwards facing, room speaker.
It uses a Dayton ND65-8 for full range audio, and a Raspberry Pi Zero 2 WH for the audio processing.
Because of the upwards facing Dayton, the speaker is designed to stay in the corner of a room and fill it with uniform sound.
It brings not too much bass, but enough range to fill the room.

## Hardware Requirements

- RaspberryPi Zero 2 WH
  - Remember the MicroSD card (8GB or larger)
- WM8960 Audio Hat
- Dayton Audio ND65-8

## Steps

1. install Raspberry Pi OS lite on the MicroSD card
2. SSH into the speaker
3. Run `wget https://github.com/ThorbenKuck/hss/releases/latest/download/speaker_setup.sh -O setup.sh && chmod +x setup.sh && sudo ./setup.sh`
   - Run the script and select your preferences, or run it with `./setup.sh -y` to follow the default settings.
