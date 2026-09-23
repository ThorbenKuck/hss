# HUB Setup

This hub is the center for your home sound system.
It contains a Snapcast server and distributes audi to all speakers.

## Hardware Requirements

- RaspberryPi 3 (at least, better an even newer model)
    - Remember the MicroSD card (8GB or larger)
- Potentiometer

## Steps

1. install Raspberry Pi OS lite on the MicroSD card
2. SSH into the HUB
3. Run `wget https://github.com/ThorbenKuck/hss/releases/latest/download/hub_setup.sh -O setup.sh && chmod +x setup.sh`
    - Run the script and select your preferences, or run it with `./setup.sh -y` to follow the default settings.
