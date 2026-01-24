# PiModemBuilder

A shell build script to configure a Raspberry Pi as a serially-connected modem emulator with Telnet and PPP functionality. Automates (with modifications) the [PiModem Project tutorial by podsix.org](http://podsix.org/articles/pimodem/).

## What It Does

PiModemBuilder turns your Raspberry Pi into a Hayes-compatible modem emulator that connects vintage computers to modern networks. Using a USB-to-serial adapter, your retro machine can "dial" into Telnet-accessible BBSes, establish PPP connections, and access the internet just like it's 1995.

![20260124_133018](https://github.com/user-attachments/assets/3a3f01a6-12bc-4e70-adea-98a231b9716d)


## Hardware Requirements

- **Raspberry Pi Zero W or Zero 2 W** (tested) or similar model
- **USB-to-serial adapter** (connects to vintage computer's serial port)
- **Null-modem adapter or cable** (required - connects DTE to DTE)
- **Power supply** for the Raspberry Pi
- **WiFi connection** (for internet access)

## What Gets Installed

- **tcpser** - Hayes modem emulator that translates AT commands to TCP connections
- **pppd** - PPP daemon for dial-up internet connections
- **xinetd** - Service manager for the PPP login service
- **NAT/IP forwarding** - Routes traffic from PPP clients through WiFi
- **Telnet** - For local and outbound Telnet connections

## Installation

1. Flash a fresh Raspberry Pi OS Lite image to your SD card
2. Configure WiFi and enable SSH
3. Download and run the `pimodem.sh` script:
```bash
wget https://github.com/Cloudschatze/PiModemBuilder/raw/refs/heads/main/pimodem.sh && chmod +x pimodem.sh && ./pimodem.sh
```

The script will automatically install and configure everything needed.

## Default Configuration

- **Serial device**: `/dev/ttyUSB0` (USB-to-serial adapter)
- **Baud rate**: 9600 (good for most retro systems)
- **PPP IP range**: 192.192.1.1/192.192.1.2 (outside typical LAN ranges)

### Pre-configured "Phone Numbers"

The script creates a phonebook at `/home/pi/phonebook.txt` with these defaults:

- `5551000` - bbs.fozztexx.com
- `5551001` - particlesbbs.dyndns.org:6400
- `5559000` - localhost:2323 (PPP connection)

## Usage

### From Your Vintage Computer

Connect via terminal software at 9600 baud (or your configured rate):

```
AT                           (test modem)
ATZ                          (reset modem)
ATDT#######                  (dial phonebook entry - e.g., 5551000, 5551001)
ATDT5559000                  (dial PPP phonebook entry - use any username/password)
ATDTexample.com              (dial any Telnet host directly)
ATDTexample.com:2323         (dial any Telnet host with custom port)
```

**Note:** The `5559000` number connects to the PPP service and requires a PPP/dial-up networking client (like Windows Dial-Up Networking, MacPPP, or trumpet winsock).

**You can dial in three ways:**
1. **Phonebook entries** - Use the configured numbers (e.g., `ATDT5551000`)
2. **Direct hostnames** - Type any Telnet-accessible hostname (e.g., `ATDTlord.stabs.org`)
3. **Hostname with port** - Specify a custom port (e.g., `ATDTexample.com:2323`)

### Changing Baud Rate

The script installs a helper utility:

```bash
pimodem-baud              # Show current setting
pimodem-baud 2400         # Change to 2400 baud
pimodem-baud 19200        # Change to 19200 baud
```

Common rates: 300, 1200, 2400, 9600, 19200, 38400

### Adding Phone Numbers

Edit `/home/pi/phonebook.txt`:

```
5551234=example.com:23
5555678=bbs.example.org
```

Then restart the service:
```bash
sudo systemctl restart tcpser
```

### Checking Status

```bash
sudo systemctl status tcpser
sudo systemctl status xinetd
```

## Customization

### Change Serial Device

Edit `/usr/local/bin/start_tcpser.sh` and modify:
```bash
dev='/dev/ttyUSB0'    # Change to your device
```

### PPP IP Addresses

Edit `/etc/ppp/options` to change:
```
192.192.1.1:192.192.1.2
```

### Enable PPP Debug Logging

Uncomment the `debug` line in `/etc/ppp/options` to troubleshoot connection issues.

### Configure Read-Only Filesystem (Recommended)

For headless operation and protection against SD card corruption from unexpected power loss, you can configure the Pi to run in read-only mode using overlayfs.

**Enable read-only mode:**

Raspberry Pi OS includes a built-in overlay filesystem option. Enable it with:
```bash
sudo raspi-config
```

Navigate to: **Performance Options** → **Overlay File System** → Enable overlay and set boot partition to read-only when prompted.

**Important notes:**
- Run the build script and complete all customization **before** enabling overlay mode
- The phonebook file (`/home/pi/phonebook.txt`) won't be editable in read-only mode
- To make changes later, temporarily disable overlay mode, make changes, then re-enable

## Troubleshooting

**Modem not responding:**
- Check that your USB-to-serial adapter appears as `/dev/ttyUSB0` (run `ls /dev/ttyUSB*`)
- Verify baud rate matches your terminal software
- Check service status: `sudo systemctl status tcpser`

**Can't connect to PPP:**
- Verify xinetd is running: `sudo systemctl status xinetd`
- Check system logs: `sudo journalctl -u xinetd -f`

**No internet after PPP connection:**
- Verify NAT is configured: `sudo iptables -t nat -L`
- Check IP forwarding: `cat /proc/sys/net/ipv4/ip_forward` (should show 1)

## Technical Details

- Uses FozzTexx' fork of [tcpser](https://github.com/FozzTexx/tcpser) for modem emulation
- PPP authentication accepts any username/password (configured for retro compatibility)
- NAT shares the WiFi connection with PPP clients
- Services start automatically on boot

## License

This script is provided as-is for hobbyist and educational use.

## Credits

- [The PiModem Project](http://podsix.org/articles/pimodem/) by Matt Whitted
- tcpser by Jim Brain & FozzTexx
